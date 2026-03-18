#!/bin/bash
################################################################################
# Intel GPU SR-IOV Provisioning Script
#
# Description:
#   Configures SR-IOV Virtual Functions (VFs) for Intel GPUs with resource
#   allocation for GGTT, contexts, doorbells, and scheduler parameters.
#   Configuration is read from Bmg.xml profile file.
#
# Usage:
#   ./provision-sriov.sh -n <num_vfs> [-s <scheduler>]
#
# Version: 2.3
################################################################################

set -e

################################################################################
# CONSTANTS AND CONFIGURATION
################################################################################

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE_DEFAULT="${SCRIPT_DIR}/../config/vgpu-profile/bmg-idv-profile.xml"
GPU_BASE_PATH_DEFAULT="/sys/kernel/debug/dri"

# Configurable paths (can be overridden via command line)
CONFIG_FILE="${CONFIG_FILE_DEFAULT}"
GPU_BASE_PATH="${GPU_BASE_PATH_DEFAULT}"
GT_NAME="gt0"  # Common: gt0, gt, tile0/gt0
PF_SUBPATH="pf"  # Common: pf, iov/pf
VF_SUBPATH="vf"  # Common: vf, iov/vf

# Device variables
PCI_DEVICE=""
PCI_SYSFS=""
DRI_CARD=""
GT_PATH=""
GT1_PATH=""  # Optional secondary GT (gt1)

# Configuration variables (populated from XML or command line)
VF_PROFILE=""
GGTT_BYTES=0
LMEM_BYTES=0
CONTEXTS=0
DOORBELLS=0
EXEC_QUANTUM=0
PREEMPT_TIMEOUT=0
PF_GGTT_SPARE_BYTES=0
PF_LMEM_SPARE=0
PF_CONTEXTS_SPARE=0
PF_DOORBELLS_SPARE=0
PF_EXEC_QUANTUM=0
PF_PREEMPT_TIMEOUT=0
SCHEDULER_PROFILE=""
ECC_MODE="off"

################################################################################
# OUTPUT FUNCTIONS
################################################################################

# Print formatted header banner
print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  GPU SR-IOV Provisioning${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

# Print success message with checkmark
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Print error message with X mark
print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Print info message with info icon
print_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

# Get scheduler profile names from XML config for help text
get_scheduler_options() {
    local scheduler_options=""

    if [ ! -f "${CONFIG_FILE}" ] || ! command -v xmllint &> /dev/null; then
        echo "from XML vGPUScheduler/Profile"
        return 0
    fi

    local count
    count=$(xmllint --xpath "count(//vGPUScheduler/Profile/*)" "${CONFIG_FILE}" 2>/dev/null | cut -d'.' -f1)

    if [ -z "${count}" ] || [ "${count}" -eq 0 ] 2>/dev/null; then
        echo "from XML vGPUScheduler/Profile"
        return 0
    fi

    local i
    for ((i=1; i<=count; i++)); do
        local scheduler_name
        scheduler_name=$(xmllint --xpath "name((//vGPUScheduler/Profile/*)[${i}])" "${CONFIG_FILE}" 2>/dev/null)
        [ -z "${scheduler_name}" ] && continue

        if [ -z "${scheduler_options}" ]; then
            scheduler_options="${scheduler_name}"
        else
            scheduler_options="${scheduler_options}, ${scheduler_name}"
        fi
    done

    [ -n "${scheduler_options}" ] && echo "${scheduler_options}" || echo "from XML vGPUScheduler/Profile"
}

################################################################################
# USAGE AND HELP
################################################################################

usage() {
    local scheduler_options
    scheduler_options=$(get_scheduler_options)

    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -n, --num-vfs NUM           Number of VFs to enable (1, 2, 3, or 4)
    -s, --scheduler NAME        Scheduler profile (default: from XML vGPUScheduler/Default)
                                Options: ${scheduler_options}
    -e, --ecc MODE              ECC mode: on or off (default: off)
    -c, --config FILE           XML configuration file (default: ${CONFIG_FILE_DEFAULT})
    --pci-device DEVICE         PCI device address (e.g., 0000:00:02.0, auto-detected if not specified)
    --disable                   Disable SR-IOV and remove all VFs
    -h, --help                  Show this help message

Examples:
    # Enable 6 VFs
    $0 -n 6

    # Disable SR-IOV
    $0 --disable

Note: VF count maps automatically to profile:
    - Bmg_24: 1 VF    - Bmg_12: 2 VFs   - Bmg_8: 3 VFs
    - Bmg_6: 4 VFs

EOF
    exit 0
}

################################################################################
# SYSTEM VALIDATION FUNCTIONS
################################################################################

# --- Privilege and Filesystem Checks ---

# Check if script is running with root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

check_debugfs() {
    if [ ! -d "/sys/kernel/debug" ]; then
        print_error "debugfs not mounted"
        print_info "Mount it with: mount -t debugfs none /sys/kernel/debug"
        exit 1
    fi
}

# --- Configuration File Validation ---

# Verify XML configuration file exists and xmllint is available
check_xml_config() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        print_error "Configuration file not found: ${CONFIG_FILE}"
        exit 1
    fi
    
    if ! command -v xmllint &> /dev/null; then
        print_error "xmllint is not installed. Please install libxml2-utils"
        print_info "Run: sudo apt-get install libxml2-utils"
        exit 1
    fi
}

################################################################################
# GPU DEVICE DETECTION
################################################################################

# --- DRI Card Detection ---

find_dri_card() {
    local pci_dev=$1
    local pci_real
    pci_real=$(readlink -f "/sys/bus/pci/devices/${pci_dev}" 2>/dev/null)
    
    for card_path in /sys/class/drm/card*; do
        if [ -L "${card_path}/device" ]; then
            local card_dev
            card_dev=$(readlink -f "${card_path}/device" 2>/dev/null)
            if [ "$card_dev" = "$pci_real" ]; then
                echo "${card_path##*/card}"
                return 0
            fi
        fi
    done
    return 1
}

# --- Path Detection Helpers ---

detect_gt_path() {
    local dri_card=$1
    local base_path="${GPU_BASE_PATH}/${dri_card}"
    
    # Try common GT path variations
    local gt_variations=("$GT_NAME" "gt0" "gt" "tile0/gt0" "tile0/gt")
    
    for gt_var in "${gt_variations[@]}"; do
        if [ -d "${base_path}/${gt_var}" ]; then
            echo "${base_path}/${gt_var}"
            return 0
        fi
    done
    
    # If nothing found, return default and let validation handle it
    echo "${base_path}/${GT_NAME}"
    return 1
}

detect_pf_path() {
    local gt_path=$1
    
    # Try common PF path variations
    local pf_variations=("$PF_SUBPATH" "pf" "iov/pf" "sriov/pf")
    
    for pf_var in "${pf_variations[@]}"; do
        if [ -d "${gt_path}/${pf_var}" ]; then
            echo "${pf_var}"
            return 0
        fi
    done
    
    echo "$PF_SUBPATH"
    return 1
}

detect_vf_path() {
    local gt_path=$1
    
    # Try common VF path variations (check for vf1 as indicator)
    local vf_variations=("${VF_SUBPATH}1" "vf1" "iov/vf1" "sriov/vf1")
    
    for vf_var in "${vf_variations[@]}"; do
        if [ -d "${gt_path}/${vf_var}" ]; then
            # Extract the base path (remove the '1')
            echo "${vf_var%1}"
            return 0
        fi
    done
    
    echo "$VF_SUBPATH"
    return 1
}

# --- Main GPU Detection ---

detect_intel_gpu() {
    print_info "Detecting Intel GPU device..."
    
    local gpu_devices=()
    for device in /sys/bus/pci/devices/*; do
        [ -f "${device}/vendor" ] || continue
        local vendor
        vendor=$(cat "${device}/vendor" 2>/dev/null)
        [ "$vendor" = "0x8086" ] || continue
        [ -f "${device}/class" ] || continue
        local class
        class=$(cat "${device}/class" 2>/dev/null)
        [[ "$class" == 0x03* ]] && gpu_devices+=("$(basename "$device")")
    done
    
    [ ${#gpu_devices[@]} -eq 0 ] && { print_error "No Intel GPU device found"; exit 1; }
    
    if [ ${#gpu_devices[@]} -gt 1 ]; then
        print_info "Multiple Intel GPUs found: ${gpu_devices[*]}"
        print_info "Using first device (use --pci-device to select different one)"
    fi
    
    PCI_DEVICE="${gpu_devices[0]}"
    PCI_SYSFS="/sys/bus/pci/devices/${PCI_DEVICE}"
    print_success "Found Intel GPU: ${PCI_DEVICE}"
    
    DRI_CARD=$(find_dri_card "$PCI_DEVICE") || { print_dri_card_not_found "$PCI_DEVICE"; exit 1; }
    
    print_success "Found DRI card: ${DRI_CARD}"
    GT_PATH=$(detect_gt_path "$DRI_CARD")
    print_info "Using GT path: ${GT_PATH}"
    
    # Check for secondary GT (gt1)
    local base_path="${GPU_BASE_PATH}/${DRI_CARD}"
    if [ -d "${base_path}/gt1" ]; then
        GT1_PATH="${base_path}/gt1"
        print_info "Found secondary GT: ${GT1_PATH}"
    fi
}

# --- GPU Device Validation ---

check_gpu_device() {
    if [ ! -d "${PCI_SYSFS}" ]; then
        print_error "GPU device ${PCI_DEVICE} not found in sysfs"
        exit 1
    fi
    
    if [ ! -d "${GPU_BASE_PATH}/${DRI_CARD}" ]; then
        print_error "GPU device DRI card ${DRI_CARD} not found in debugfs"
        exit 1
    fi
    
    if [ ! -d "${GT_PATH}" ]; then
        print_error "GT path ${GT_PATH} not found in debugfs"
        exit 1
    fi
    
    # Check if SR-IOV is supported
    if [ ! -f "${PCI_SYSFS}/sriov_totalvfs" ]; then
        print_error "SR-IOV not supported on device ${PCI_DEVICE}"
        exit 1
    fi
    
    local max_vfs
    max_vfs=$(cat "${PCI_SYSFS}/sriov_totalvfs" 2>/dev/null || echo "0")
    print_success "SR-IOV supported with maximum ${max_vfs} VFs"
}

################################################################################
# XML CONFIGURATION PARSING
################################################################################

# --- Configuration Parsing ---

parse_config_from_xml() {
    local num_vfs=$1 scheduler=$2
    num_vfs=$(echo "$num_vfs" | tr -d '[:space:]')
    
    # Parse PF resources
    PF_GGTT_SPARE_BYTES=$(xmllint --xpath "string(//PFResources/Profile/MinimumPFResources/GGTTSize)" "${CONFIG_FILE}" 2>/dev/null)
    PF_CONTEXTS_SPARE=$(xmllint --xpath "string(//PFResources/Profile/MinimumPFResources/Contexts)" "${CONFIG_FILE}" 2>/dev/null)
    PF_DOORBELLS_SPARE=$(xmllint --xpath "string(//PFResources/Profile/MinimumPFResources/Doorbells)" "${CONFIG_FILE}" 2>/dev/null)
    
    # Parse PF LMEM spare based on ECC mode
    if [ "$ECC_MODE" = "on" ]; then
        PF_LMEM_SPARE=$(xmllint --xpath "string(//PFResources/Profile/MinimumPFResources/LocalMemoryEccOn)" "${CONFIG_FILE}" 2>/dev/null)
    else
        PF_LMEM_SPARE=$(xmllint --xpath "string(//PFResources/Profile/MinimumPFResources/LocalMemoryEccOff)" "${CONFIG_FILE}" 2>/dev/null)
    fi
    
    # Default to 0 if not specified in XML
    [ -z "$PF_LMEM_SPARE" ] && PF_LMEM_SPARE=0
    [ -z "$PF_CONTEXTS_SPARE" ] && PF_CONTEXTS_SPARE=0
    [ -z "$PF_DOORBELLS_SPARE" ] && PF_DOORBELLS_SPARE=0
    
    # Resolve profile by VFCount
    local profile
    profile=$(xmllint --xpath "name(//vGPUResources/Profile/*[normalize-space(VFCount)='${num_vfs}'][1])" "${CONFIG_FILE}" 2>/dev/null)
    [ -z "$profile" ] && { print_error "No vGPU profile found for VFCount=${num_vfs}"; return 1; }
    VF_PROFILE="$profile"
    
    GGTT_BYTES=$(xmllint --xpath "string(//vGPUResources/Profile/${profile}/GGTTSize)" "${CONFIG_FILE}" 2>/dev/null)
    CONTEXTS=$(xmllint --xpath "string(//vGPUResources/Profile/${profile}/Contexts)" "${CONFIG_FILE}" 2>/dev/null)
    DOORBELLS=$(xmllint --xpath "string(//vGPUResources/Profile/${profile}/Doorbells)" "${CONFIG_FILE}" 2>/dev/null)
    
    # Parse LocalMemory based on ECC mode
    if [ "$ECC_MODE" = "on" ]; then
        LMEM_BYTES=$(xmllint --xpath "string(//vGPUResources/Profile/${profile}/LocalMemoryEccOn)" "${CONFIG_FILE}" 2>/dev/null)
    else
        LMEM_BYTES=$(xmllint --xpath "string(//vGPUResources/Profile/${profile}/LocalMemoryEccOff)" "${CONFIG_FILE}" 2>/dev/null)
    fi
    
    # Default LMEM to 0 if not specified
    [ -z "$LMEM_BYTES" ] && LMEM_BYTES=0
    
    [ -z "$GGTT_BYTES" ] || [ -z "$CONTEXTS" ] || [ -z "$DOORBELLS" ] && { print_error "Failed to parse profile ${profile}"; return 1; }
    
    # Parse scheduler
    PF_EXEC_QUANTUM=$(xmllint --xpath "string(//vGPUScheduler/Profile/${scheduler}/GPUTimeSlicing/PFExecutionQuantum)" "${CONFIG_FILE}" 2>/dev/null)
    PF_PREEMPT_TIMEOUT=$(xmllint --xpath "string(//vGPUScheduler/Profile/${scheduler}/GPUTimeSlicing/PFPreemptionTimeout)" "${CONFIG_FILE}" 2>/dev/null)
    EXEC_QUANTUM=$(xmllint --xpath "string(//vGPUScheduler/Profile/${scheduler}/GPUTimeSlicing/VFAttributes/VF[@VFCount='${num_vfs}']/ExecutionQuantum)" "${CONFIG_FILE}" 2>/dev/null)
    PREEMPT_TIMEOUT=$(xmllint --xpath "string(//vGPUScheduler/Profile/${scheduler}/GPUTimeSlicing/VFAttributes/VF[@VFCount='${num_vfs}']/PreemptionTimeout)" "${CONFIG_FILE}" 2>/dev/null)
    
    # Default PF scheduler if not specified
    [ -z "$PF_EXEC_QUANTUM" ] && PF_EXEC_QUANTUM=0
    [ -z "$PF_PREEMPT_TIMEOUT" ] && PF_PREEMPT_TIMEOUT=0
    
    [ -z "$EXEC_QUANTUM" ] || [ -z "$PREEMPT_TIMEOUT" ] && { print_error "Failed to parse scheduler ${scheduler}"; return 1; }
    
    print_success "Configuration loaded: Profile=${profile}, Scheduler=${scheduler}"
}

################################################################################
# SR-IOV ENABLE/DISABLE OPERATIONS
################################################################################

# Disable SR-IOV and remove all VFs
disable_sriov() {
    print_info "Disabling SR-IOV..."
    
    [ ! -f "${PCI_SYSFS}/sriov_numvfs" ] && { print_error "SR-IOV not supported on this device"; exit 1; }
    
    # Clear VF resource quotas before disabling SR-IOV
    clear_all_vf_quotas
    
    # Disable SR-IOV
    echo 0 > "${PCI_SYSFS}/sriov_numvfs"
    print_success "SR-IOV disabled"
    
    # Cleanup vfio-pci driver binding
    if [ -f "${PCI_SYSFS}/device" ]; then
        local device_id
        device_id=$(sed 's/0x//' < "${PCI_SYSFS}/device")
        [ -f "/sys/bus/pci/drivers/vfio-pci/remove_id" ] && \
            echo "8086 ${device_id}" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null
    fi
    
    # Unload vfio-pci module
    lsmod | grep -q vfio_pci && rmmod vfio-pci 2>/dev/null
    
    # Clear PF spare allocations
    local pf_path
    pf_path="${GT_PATH}/$(detect_pf_path "$GT_PATH")"
    [ -d "${pf_path}" ] && clear_pf_spare "$pf_path"
    
    # Also clear secondary GT if present
    if [ -n "$GT1_PATH" ]; then
        local pf1_path
        pf1_path="${GT1_PATH}/$(detect_pf_path "$GT1_PATH")"
        [ -d "${pf1_path}" ] && clear_pf_spare "$pf1_path"
    fi
}

# Enable specified number of VFs and wait for debugfs paths
enable_vfs() {
    local num_vfs=$1
    
    print_info "Enabling ${num_vfs} Virtual Functions..."
    
    # Disable driver autoprobe to prevent xe driver from binding to VFs (avoids register access warnings)
    if [ -f "${PCI_SYSFS}/sriov_drivers_autoprobe" ]; then
        echo 0 > "${PCI_SYSFS}/sriov_drivers_autoprobe" 2>/dev/null || true
        print_info "Disabled driver autoprobe for VFs"
    fi
    
    # Enable VFs
    echo "${num_vfs}" > "${PCI_SYSFS}/sriov_numvfs"
    sleep 2
    
    # Re-enable autoprobe (VFs will be bound to vfio-pci later)
    if [ -f "${PCI_SYSFS}/sriov_drivers_autoprobe" ]; then
        echo 1 > "${PCI_SYSFS}/sriov_drivers_autoprobe" 2>/dev/null || true
    fi
    
    print_success "Enabled ${num_vfs} VFs in sysfs"
    
    # Auto-detect VF path structure
    print_info "Detecting SR-IOV debugfs structure..."
    local detected_vf_path
    detected_vf_path=$(detect_vf_path "$GT_PATH")
    if [ "$detected_vf_path" != "$VF_SUBPATH" ]; then
        print_info "Detected VF path: ${detected_vf_path}"
        VF_SUBPATH="$detected_vf_path"
    fi
    
    local retries=10
    while [ $retries -gt 0 ]; do
        if [ -d "${GT_PATH}/${VF_SUBPATH}1" ]; then
            print_success "SR-IOV debugfs paths ready: ${GT_PATH}/${VF_SUBPATH}#"
            
            # Bind VF devices to vfio-pci for VM passthrough
            print_info "Binding VF devices to vfio-pci driver..."
            
            # Load vfio-pci module
            modprobe vfio-pci 2>/dev/null || print_info "vfio-pci already loaded"
            
            # Get device ID from first VF
            if [ -f "${PCI_SYSFS}/device" ]; then
                local device_id
                device_id=$(sed 's/0x//' < "${PCI_SYSFS}/device")
                
                # Add device ID to vfio-pci driver if not already bound
                if [ -d "/sys/bus/pci/drivers/vfio-pci" ]; then
                    echo "8086 ${device_id}" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || print_info "Device ID already registered with vfio-pci"
                    print_success "VF devices bound to vfio-pci driver (Device ID: ${device_id})"
                fi
            fi
            
            return 0
        fi
        sleep 1
        ((retries--))
    done
    
    # Check if at least the GT debugfs path exists
    if [ ! -d "${GT_PATH}" ]; then
        print_error "GT debugfs path not found: ${GT_PATH}"
        print_info "Please ensure i915 driver is loaded with SR-IOV support"
        exit 1
    fi
    
    # VF paths not found
    print_error "SR-IOV VF paths not created under: ${GT_PATH}"
    print_info "Possible causes:"
    print_info "  - Driver doesn't support SR-IOV debugfs interface"
    print_info "  - Wrong PCI device selected"
    print_info "  - SR-IOV not enabled in kernel/BIOS"
    print_info ""
    print_info "Available debugfs paths under ${GT_PATH}:"
    ls -la "${GT_PATH}/" 2>/dev/null || echo "  (unable to list)"
    exit 1
}

################################################################################
# RESOURCE PROVISIONING FUNCTIONS
################################################################################

# --- Helper Functions ---

# Helper to write VF quota value if different from current
write_vf_quota() {
    local vf_path=$1 file=$2 value=$3
    
    [ ! -f "${vf_path}/${file}" ] && return 0
    
    local current
    current=$(cat "${vf_path}/${file}" 2>/dev/null || echo "0")
    [ "$current" = "$value" ] && return 0
    
    echo "$value" > "${vf_path}/${file}" 2>/dev/null || {
        print_error "Failed to write ${value} to ${vf_path}/${file}"
        return 1
    }
}

# Helper to write PF spare value if non-zero
write_pf_spare() {
    local pf_path=$1 resource=$2 value=$3 display_value=$4
    
    [ ! -f "${pf_path}/${resource}_spare" ] && return 0
    [ "$value" -eq 0 ] && return 0
    
    echo "$value" > "${pf_path}/${resource}_spare" 2>/dev/null && echo "$display_value"
}

# --- PF Resource Management ---

# Clear/reset PF spare allocations to 0 (GGTT, contexts, doorbells)
clear_pf_spare() {
    local pf_path=$1
    
    local cleared_resources=()
    
    # Reset GGTT spare to 0
    if [ -f "${pf_path}/ggtt_spare" ]; then
        echo "67108864" > "${pf_path}/ggtt_spare" 2>/dev/null && cleared_resources+=("ggtt=67108864")
    fi
    
    # Reset LMEM spare to 0
    if [ -f "${pf_path}/lmem_spare" ]; then
        echo "0" > "${pf_path}/lmem_spare" 2>/dev/null && cleared_resources+=("lmem=0")
    fi
    
    # Reset contexts spare to 0
    if [ -f "${pf_path}/contexts_spare" ]; then
        echo "256" > "${pf_path}/contexts_spare" 2>/dev/null && cleared_resources+=("contexts=256")
    fi
    
    # Reset doorbells spare to 0
    if [ -f "${pf_path}/doorbells_spare" ]; then
        echo "0" > "${pf_path}/doorbells_spare" 2>/dev/null && cleared_resources+=("doorbells=0")
    fi
    
    if [ ${#cleared_resources[@]} -gt 0 ]; then
        print_success "Cleared PF spare: ${cleared_resources[*]}"
    fi
}

# --- VF Resource Management ---

# Clear all VF resource quotas
clear_all_vf_quotas() {
    local current_vfs
    current_vfs=$(cat "${PCI_SYSFS}/sriov_numvfs" 2>/dev/null || echo "0")
    [ "$current_vfs" -eq 0 ] && return 0
    
    print_info "Clearing VF resource quotas for ${current_vfs} VFs..."
    
    # Clear quotas for both GT0 and GT1 (if present) in one loop
    for ((vf=1; vf<=current_vfs; vf++)); do
        for gt_path in "$GT_PATH" ${GT1_PATH:+"$GT1_PATH"}; do
            local vf_path="${gt_path}/${VF_SUBPATH}${vf}"
            [ ! -d "$vf_path" ] && continue
            
            if [ -f "$vf_path/ggtt_quota" ]; then echo "0" > "$vf_path/ggtt_quota" 2>/dev/null; fi
            if [ -f "$vf_path/lmem_quota" ]; then echo "0" > "$vf_path/lmem_quota" 2>/dev/null; fi
            if [ -f "$vf_path/contexts_quota" ]; then echo "0" > "$vf_path/contexts_quota" 2>/dev/null; fi
            if [ -f "$vf_path/doorbells_quota" ]; then echo "0" > "$vf_path/doorbells_quota" 2>/dev/null; fi
        done
    done
    
    print_success "Cleared resource quotas for ${current_vfs} VFs"
}

# Configure PF resources with specified spare allocations
provision_pf_resources() {
    local pf_path
    pf_path="${GT_PATH}/$(detect_pf_path "$GT_PATH")"
    
    if [ ! -d "${pf_path}" ]; then
        print_info "PF path not found (${pf_path}), skipping PF spare configuration"
        return 0
    fi
    
    # Set configured spare values (only if > 0)
    local configured=()
    configured+=("$(write_pf_spare "$pf_path" "ggtt" "$PF_GGTT_SPARE_BYTES" "ggtt=$((PF_GGTT_SPARE_BYTES / 1024 / 1024))MiB")")
    configured+=("$(write_pf_spare "$pf_path" "lmem" "$PF_LMEM_SPARE" "lmem=$((PF_LMEM_SPARE / 1024 / 1024))MiB")")
    configured+=("$(write_pf_spare "$pf_path" "contexts" "$PF_CONTEXTS_SPARE" "contexts=${PF_CONTEXTS_SPARE}")")
    configured+=("$(write_pf_spare "$pf_path" "doorbells" "$PF_DOORBELLS_SPARE" "doorbells=${PF_DOORBELLS_SPARE}")")
    
    # Set PF scheduler parameters
    if [ -f "${pf_path}/exec_quantum_ms" ] && [ "$PF_EXEC_QUANTUM" -gt 0 ]; then
        echo "$PF_EXEC_QUANTUM" > "${pf_path}/exec_quantum_ms" 2>/dev/null && \
            configured+=("exec_quantum=${PF_EXEC_QUANTUM}ms")
    fi
    
    if [ -f "${pf_path}/preempt_timeout_us" ] && [ "$PF_PREEMPT_TIMEOUT" -gt 0 ]; then
        echo "$PF_PREEMPT_TIMEOUT" > "${pf_path}/preempt_timeout_us" 2>/dev/null && \
            configured+=("preempt_timeout=${PF_PREEMPT_TIMEOUT}us")
    fi
    
    if [ ${#configured[@]} -gt 0 ]; then
        print_success "Configured PF spare: ${configured[*]}"
    fi
}

# --- VF Resource Provisioning ---

# Provision resources for a single VF
provision_single_vf() {
    local vf_num=$1
    local vf_path="${GT_PATH}/${VF_SUBPATH}${vf_num}"
    
    [ -d "${vf_path}" ] || { print_error "VF${vf_num} path not found: ${vf_path}"; return 1; }
    
    write_vf_quota "$vf_path" "ggtt_quota" "$GGTT_BYTES"
    write_vf_quota "$vf_path" "lmem_quota" "$LMEM_BYTES"
    write_vf_quota "$vf_path" "contexts_quota" "$CONTEXTS"
    write_vf_quota "$vf_path" "doorbells_quota" "$DOORBELLS"
    write_vf_quota "$vf_path" "exec_quantum_ms" "$EXEC_QUANTUM"
    write_vf_quota "$vf_path" "preempt_timeout_us" "$PREEMPT_TIMEOUT"
}

################################################################################
# COMMAND LINE ARGUMENT PARSING
################################################################################

NUM_VFS=""
VF_PROFILE=""
SCHEDULER_PROFILE=""
ECC_MODE="off"
DISABLE_SRIOV=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--num-vfs)
            NUM_VFS="$2"
            shift 2
            ;;
        -s|--scheduler)
            SCHEDULER_PROFILE="$2"
            shift 2
            ;;
        -e|--ecc)
            ECC_MODE="$2"
            shift 2
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --pci-device)
            PCI_DEVICE="$2"
            shift 2
            ;;
        --disable)
            DISABLE_SRIOV=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

################################################################################
# MAIN EXECUTION
################################################################################

# Validate prerequisites
check_root
check_debugfs

# Detect or validate GPU device
if [ -z "$PCI_DEVICE" ]; then
    detect_intel_gpu
else
    print_info "Using specified PCI device: ${PCI_DEVICE}"
    PCI_SYSFS="/sys/bus/pci/devices/${PCI_DEVICE}"
    
    DRI_CARD=$(find_dri_card "$PCI_DEVICE") || { print_dri_card_not_found "$PCI_DEVICE"; exit 1; }
    
    print_success "Found DRI card: ${DRI_CARD}"
    GT_PATH=$(detect_gt_path "$DRI_CARD")
    print_info "Using GT path: ${GT_PATH}"
fi

check_gpu_device

# Handle disable request
[ "$DISABLE_SRIOV" = true ] && { disable_sriov; exit 0; }

# Validate parameters
[ -z "$NUM_VFS" ] && { print_error "Number of VFs not specified"; usage; }
[ "$ECC_MODE" != "on" ] && [ "$ECC_MODE" != "off" ] && { print_error "Invalid ECC mode: ${ECC_MODE}"; exit 1; }

check_xml_config
print_header

# Read default scheduler from XML if not specified
if [ -z "$SCHEDULER_PROFILE" ]; then
    SCHEDULER_PROFILE=$(xmllint --xpath "string(//vGPUScheduler/Default)" "${CONFIG_FILE}" 2>/dev/null)
    [ -n "$SCHEDULER_PROFILE" ] && print_info "Using default scheduler from profile: ${SCHEDULER_PROFILE}"
fi

# Load configuration
parse_config_from_xml "$NUM_VFS" "$SCHEDULER_PROFILE" || exit 1
echo ""

# Cleanup existing VFs if any by calling disable_sriov
if [ -f "${PCI_SYSFS}/sriov_numvfs" ]; then
    current_vfs=$(cat "${PCI_SYSFS}/sriov_numvfs" 2>/dev/null || echo "0")
    if [ "$current_vfs" -gt 0 ]; then
        disable_sriov
    fi
fi

# Configure PF resources BEFORE enabling VFs
provision_pf_resources
if [ -n "$GT1_PATH" ]; then
    saved_gt_path="$GT_PATH"
    GT_PATH="$GT1_PATH"
    provision_pf_resources
    GT_PATH="$saved_gt_path"
    print_success "PF resources configured for gt1"
fi
echo ""

# Enable VFs
enable_vfs "${NUM_VFS}"
echo ""

# Provision VF resources
print_info "Provisioning ${NUM_VFS} VFs with resources:"
if [ "$LMEM_BYTES" -gt 0 ]; then
    print_info "  LMEM: $((LMEM_BYTES / 1024 / 1024)) MiB | GGTT: $((GGTT_BYTES / 1024 / 1024)) MiB | Contexts: ${CONTEXTS} | Doorbells: ${DOORBELLS}"
else
    print_info "  GGTT: $((GGTT_BYTES / 1024 / 1024)) MiB | Contexts: ${CONTEXTS} | Doorbells: ${DOORBELLS}"
fi
print_info "  Exec Quantum: ${EXEC_QUANTUM} ms | Preempt Timeout: ${PREEMPT_TIMEOUT} us"
echo ""

for ((i=1; i<=NUM_VFS; i++)); do
    provision_single_vf "${i}" && print_success "VF${i} provisioned on gt0" || exit 1
    
    if [ -n "$GT1_PATH" ]; then
        saved_gt_path="$GT_PATH"
        GT_PATH="$GT1_PATH"
        provision_single_vf "${i}" && print_success "VF${i} provisioned on gt1" || exit 1
        GT_PATH="$saved_gt_path"
    fi
done

# Summary
echo ""
print_success "SR-IOV provisioning completed!"
print_info "Profile: ${VF_PROFILE} | Scheduler: ${SCHEDULER_PROFILE} | ECC: ${ECC_MODE} | VFs: ${NUM_VFS} | Device: ${PCI_DEVICE} (card${DRI_CARD})"
print_info "VF devices are ready for VM passthrough via vfio-pci"
print_info "Verify with: ./read-sriov-resources.sh"
