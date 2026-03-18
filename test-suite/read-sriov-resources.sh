#!/bin/bash
################################################################################
# Intel GPU SR-IOV Resource Reader
#
# Description:
#   Reads and displays SR-IOV resource allocations from debugfs for Intel GPUs.
#   Shows GGTT, contexts, doorbells, and scheduler parameters for PF and VFs.
#
# Usage:
#   sudo ./read-sriov-resources.sh
#
# Version: 2.1
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
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default paths
GPU_BASE_PATH="/sys/kernel/debug/dri"
GT_NAME="gt0"  # Common: gt0, gt, tile0/gt0
PF_SUBPATH="pf"  # Common: pf, iov/pf
VF_SUBPATH="vf"  # Common: vf, iov/vf

# Device variables
PCI_DEVICE=""
PCI_SYSFS=""
DRI_CARD=""
GT_PATH=""

################################################################################
# OUTPUT FUNCTIONS
################################################################################

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  GPU SR-IOV Resource Information${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_section() {
    echo -e "${CYAN}━━━ $1 ━━━${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

################################################################################
# GPU DEVICE DETECTION
################################################################################

################################################################################
# GPU DEVICE DETECTION
################################################################################

# Find DRI card number from PCI device
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

# Auto-detect GT path with common variations
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
    
    # If nothing found, return default
    echo "${base_path}/${GT_NAME}"
    return 1
}

# Auto-detect PF path with common variations
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

# Auto-detect VF path with common variations
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

# Auto-detect Intel GPU device
detect_intel_gpu() {
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
    
    [ ${#gpu_devices[@]} -eq 0 ] && { echo -e "${RED}Error: No Intel GPU device found${NC}"; exit 1; }
    
    PCI_DEVICE="${gpu_devices[0]}"
    
    DRI_CARD=$(find_dri_card "$PCI_DEVICE")
    if [ -z "$DRI_CARD" ]; then
        echo -e "${RED}Error: Could not find DRI card for ${PCI_DEVICE}${NC}"
        exit 1
    fi
    
    PCI_SYSFS="/sys/bus/pci/devices/${PCI_DEVICE}"
    
    # Auto-detect GT path
    GT_PATH=$(detect_gt_path "$DRI_CARD")
    
    # Auto-detect PF and VF paths
    PF_SUBPATH=$(detect_pf_path "$GT_PATH")
    VF_SUBPATH=$(detect_vf_path "$GT_PATH")
}

################################################################################
# SYSTEM VALIDATION
################################################################################

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run with sudo"
        echo "  sudo $0"
        exit 1
    fi
}

# Check if debugfs is mounted
check_debugfs() {
    if [ ! -d "/sys/kernel/debug" ]; then
        print_error "debugfs not mounted"
        print_info "Mount it with: sudo mount -t debugfs none /sys/kernel/debug"
        exit 1
    fi
}

# Validate GPU device and paths
check_gpu_device() {
    if [ ! -d "${GPU_BASE_PATH}/${DRI_CARD}" ]; then
        print_error "GPU DRI card ${DRI_CARD} not found"
        echo "Available devices:"
        ls -1 ${GPU_BASE_PATH}/ 2>/dev/null || echo "  None found"
        exit 1
    fi
    
    if [ ! -d "${GT_PATH}" ]; then
        print_error "GT path ${GT_PATH} not found"
        exit 1
    fi
    
    if [ ! -f "${PCI_SYSFS}/sriov_totalvfs" ]; then
        print_error "SR-IOV not supported on device ${PCI_DEVICE}"
        exit 1
    fi
}

# Check SR-IOV status
check_sriov_enabled() {
    local num_vfs
    num_vfs=$(cat "${PCI_SYSFS}/sriov_numvfs" 2>/dev/null || echo "0")
    if [ "$num_vfs" -eq 0 ]; then
        print_error "SR-IOV is not enabled (no VFs active)"
        print_info "Enable with: ./provision-sriov.sh -n <num_vfs>"
        exit 1
    fi
    return 0
}

################################################################################
# RESOURCE READING FUNCTIONS
################################################################################

# Read and display PF resources
read_pf_resources() {
    local pf_dir="${GT_PATH}/${PF_SUBPATH}"
    
    if [ ! -d "$pf_dir" ]; then
        print_info "PF resources not available"
        return 0
    fi
    
    # GGTT information
    if [ -f "${pf_dir}/ggtt_available" ]; then
        local ggtt_info
        local ggtt_total
        local ggtt_avail
        local ggtt_spare
        ggtt_info=$(cat "${pf_dir}/ggtt_available" 2>/dev/null)
        ggtt_total=$(echo "$ggtt_info" | grep "^total:" | awk '{print $2}')
        ggtt_avail=$(echo "$ggtt_info" | grep "^avail:" | awk '{print $2}')
        ggtt_spare=$(echo "$ggtt_info" | grep "^spare:" | awk '{print $2}')
        
        if [ -n "$ggtt_total" ]; then
            local total_mib=$((ggtt_total / 1024 / 1024))
            echo -e "  ${GREEN}GGTT Total:${NC}     ${YELLOW}${total_mib} MiB${NC} (${ggtt_total} bytes)"
        fi
        if [ -n "$ggtt_avail" ]; then
            local avail_mib=$((ggtt_avail / 1024 / 1024))
            echo -e "  ${GREEN}GGTT Available:${NC} ${YELLOW}${avail_mib} MiB${NC} (${ggtt_avail} bytes)"
        fi
        if [ -n "$ggtt_spare" ]; then
            local spare_mib=$((ggtt_spare / 1024 / 1024))
            echo -e "  ${GREEN}GGTT Spare:${NC}     ${YELLOW}${spare_mib} MiB${NC} (${ggtt_spare} bytes)"
        fi
        echo ""
    fi
    
    # LMEM spare (if available)
    local lmem_spare
    lmem_spare=$(cat "${pf_dir}/lmem_spare" 2>/dev/null)
    if [ -n "$lmem_spare" ]; then
        local lmem_spare_mib=$((lmem_spare / 1024 / 1024))
        echo -e "  ${GREEN}LMEM Spare:${NC}         ${YELLOW}${lmem_spare_mib} MiB${NC} (${lmem_spare} bytes)"
        echo ""
    fi
    
    # Other PF resources
    local ctx_spare
    local db_spare
    local exec_q
    local preempt
    ctx_spare=$(cat "${pf_dir}/contexts_spare" 2>/dev/null)
    db_spare=$(cat "${pf_dir}/doorbells_spare" 2>/dev/null)
    exec_q=$(cat "${pf_dir}/exec_quantum_ms" 2>/dev/null)
    preempt=$(cat "${pf_dir}/preempt_timeout_us" 2>/dev/null)
    
    echo -e "  ${GREEN}Contexts Spare:${NC}      ${YELLOW}${ctx_spare:-N/A}${NC}"
    echo -e "  ${GREEN}Doorbells Spare:${NC}     ${YELLOW}${db_spare:-N/A}${NC}"
    echo -e "  ${GREEN}Exec Quantum:${NC}        ${YELLOW}${exec_q:-0} ms${NC}"
    echo -e "  ${GREEN}Preemption Timeout:${NC}  ${YELLOW}${preempt:-0} us${NC}"
}

# Read and display single VF resources
read_vf_resources() {
    local vf_num=$1
    local vf_dir="${GT_PATH}/${VF_SUBPATH}${vf_num}"
    
    if [ ! -d "$vf_dir" ]; then
        print_error "VF${vf_num} path not found"
        return 1
    fi
    
    echo -e "${BLUE}┌─ VF${vf_num} ─────────────────────────────${NC}"
    
    # GGTT quota
    local ggtt_quota
    ggtt_quota=$(cat "${vf_dir}/ggtt_quota" 2>/dev/null || echo "0")
    if [ "$ggtt_quota" != "0" ]; then
        local quota_mib=$((ggtt_quota / 1024 / 1024))
        echo -e "${BLUE}│${NC}  ${GREEN}GGTT Quota:${NC}          ${YELLOW}${quota_mib} MiB${NC} (${ggtt_quota} bytes)"
    else
        echo -e "${BLUE}│${NC}  ${GREEN}GGTT Quota:${NC}          ${YELLOW}0 MiB${NC}"
    fi
    
    # LMEM quota (if available)
    local lmem_quota
    lmem_quota=$(cat "${vf_dir}/lmem_quota" 2>/dev/null)
    if [ -n "$lmem_quota" ]; then
        local lmem_mib=$((lmem_quota / 1024 / 1024))
        echo -e "${BLUE}│${NC}  ${GREEN}LMEM Quota:${NC}          ${YELLOW}${lmem_mib} MiB${NC} (${lmem_quota} bytes)"
    fi
    
    # Other quotas
    local ctx_quota
    local db_quota
    local exec_q
    local preempt
    ctx_quota=$(cat "${vf_dir}/contexts_quota" 2>/dev/null)
    db_quota=$(cat "${vf_dir}/doorbells_quota" 2>/dev/null)
    exec_q=$(cat "${vf_dir}/exec_quantum_ms" 2>/dev/null)
    preempt=$(cat "${vf_dir}/preempt_timeout_us" 2>/dev/null)
    
    echo -e "${BLUE}│${NC}  ${GREEN}Contexts Quota:${NC}      ${YELLOW}${ctx_quota:-N/A}${NC}"
    echo -e "${BLUE}│${NC}  ${GREEN}Doorbells Quota:${NC}     ${YELLOW}${db_quota:-N/A}${NC}"
    echo -e "${BLUE}│${NC}  ${GREEN}Exec Quantum:${NC}        ${YELLOW}${exec_q:-0} ms${NC}"
    echo -e "${BLUE}│${NC}  ${GREEN}Preemption Timeout:${NC}  ${YELLOW}${preempt:-0} us${NC}"
    
    # Scheduler priority (if available)
    local sched_prio
    sched_prio=$(cat "${vf_dir}/sched_priority" 2>/dev/null)
    if [ -n "$sched_prio" ]; then
        echo -e "${BLUE}│${NC}  ${GREEN}Scheduler Priority:${NC}  ${YELLOW}${sched_prio}${NC}"
    fi
    
    echo -e "${BLUE}└────────────────────────────────────${NC}"
    echo ""
}

################################################################################
# MAIN EXECUTION
################################################################################

# Initialize and validate
detect_intel_gpu
check_root
check_debugfs
check_gpu_device
check_sriov_enabled

# Display header
print_header

# Device information
echo -e "${GREEN}Device Information:${NC}"
echo -e "  PCI Device:  ${YELLOW}${PCI_DEVICE}${NC}"
echo -e "  DRI Card:    ${YELLOW}card${DRI_CARD}${NC}"
echo -e "  GT Path:     ${YELLOW}${GT_PATH}${NC}"
echo ""

# SR-IOV status
vf_total=$(cat "${PCI_SYSFS}/sriov_totalvfs" 2>/dev/null || echo "0")
vf_enabled=$(cat "${PCI_SYSFS}/sriov_numvfs" 2>/dev/null || echo "0")
echo -e "${GREEN}SR-IOV Status:${NC}"
echo -e "  Total VFs:   ${YELLOW}${vf_total}${NC}"
echo -e "  Enabled VFs: ${YELLOW}${vf_enabled}${NC}"
echo ""

# PF Resources
print_section "Physical Function (PF) Resources"
echo ""
read_pf_resources
echo ""

# VF Resources
print_section "Virtual Function (VF) Resources"
echo ""
for i in $(seq 1 "$vf_enabled"); do
    read_vf_resources "$i"
done

echo -e "${BLUE}========================================${NC}"
print_success "Resource information retrieved successfully"
