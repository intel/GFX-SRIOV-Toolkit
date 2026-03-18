#!/bin/bash

################################################################################
# Create Ubuntu VM Script
#
# Description:
#   Creates an Ubuntu VM with SR-IOV support. Supports downloading Ubuntu ISO
# Usage:
#   ./create-vm-ubuntu.sh [--download_url <url>] [-o <dir>] [options]
#   ./create-vm-ubuntu.sh -i <path> [options]
#   --download_url <url>      URL to download Ubuntu ISO from
#                            (default: Ubuntu 24.04.4 Desktop ISO)
#   -o, --output-dir DIR      VM output directory (default: /data/vm-images)
#   -i, --iso-path <path>      Direct path to existing ISO file
#   -n, --vm-name NAME        VM name and image prefix (default: ubuntu24_1)
#   --vm-username <name>      Guest VM username (default: user)
#   --vm-password <pass>      Guest VM password for SSH login (default: user1234)
#   -s, --vm-size SIZE        VM disk size (default: 50G)
#   -m, --memory MB           VM memory allocation in MB (default: 8192)
#                           Hugepages auto-calculated: memory_mb / 2
#                           (Example: 8192 MB / 2MB per page = 4096 hugepages)
#   -c, --vcpus NUM           Number of vCPUs (default: 4)
#   --ovmf-code <path>        OVMF code file path (default: /usr/share/OVMF/OVMF_CODE_4M.fd)
#   --ovmf-vars <path>        OVMF vars file path
#   -h, --help                Show this help message
#
# Author: Intel Graphics SRIOV Team
# Version: 1.0
################################################################################

set -e

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color
RUN_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
readonly RUN_TIMESTAMP
readonly LOG_DIR="/var/log/sriov"
readonly LOG_FILE="${LOG_DIR}/sriov_create_vm_${RUN_TIMESTAMP}.log"

# Resolve the real user's home directory when invoked via sudo.
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    # Fallback defensively if passwd lookup fails.
    if [[ -z "$REAL_HOME" ]]; then
        REAL_HOME="$HOME"
    fi
else
    REAL_HOME="$HOME"
fi
readonly REAL_HOME

# Initialize logging to file while preserving console output
initialize_logging() {
    if [[ "$EUID" -eq 0 ]]; then
        mkdir -p "$LOG_DIR"
        : > "$LOG_FILE"
        chmod 0644 "$LOG_FILE" || true
        # Keep colorized output in terminal, but write clean text to log file.
        exec > >(tee >(sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' > "$LOG_FILE")) 2>&1
    else
        if ! sudo mkdir -p "$LOG_DIR" >/dev/null 2>&1; then
            echo "✗ Error: Unable to create log directory at $LOG_DIR" >&2
            echo "Please ensure sudo access is available" >&2
            exit 1
        fi
        if ! sudo sh -c ": > '$LOG_FILE'" >/dev/null 2>&1; then
            echo "✗ Error: Unable to create log file at $LOG_FILE" >&2
            echo "Please ensure sudo access is available" >&2
            exit 1
        fi
        # Keep colorized output in terminal, but write clean text to log file.
        exec > >(tee >(sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' | sudo tee "$LOG_FILE" >/dev/null)) 2>&1
    fi
}

################################################################################
# DEFAULT CONFIGURATION
################################################################################

readonly DEFAULT_UBUNTU_ISO_URL="https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-desktop-amd64.iso"
readonly MIN_UBUNTU_DESKTOP_ISO_BYTES=2000000000
readonly DEFAULT_DOWNLOAD_DIR="/data/vm-images"
DOWNLOAD_URL="$DEFAULT_UBUNTU_ISO_URL"
DOWNLOAD_DIR=""
ISO_PATH=""
VM_IMAGE=""
VM_NAME="ubuntu24_1"
VM_SIZE="50G"
VM_MEMORY="8192"
VCPUS="4"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS=""
VM_USERNAME="user"
VM_PASSWORD="user1234"
PROXY_URL=""
FORCE_INSTALL=false
REBOOT_VM=false
SHOW_HELP=false
OUTPUT_VM_IMAGE=""
ISO_DOWNLOAD_MODE=false
TRACKED_ISO_PATH=""
INSTALL_TMP_DIR=""
SCRIPT_COMPLETED_SUCCESSFULLY=false

################################################################################
# HELPER FUNCTIONS
################################################################################

# Print usage help
show_help() {
    echo -e "${BLUE}=== Ubuntu VM Creator Help ===${NC}\n"
    echo "Usage: $0 [OPTIONS]"
    echo
    echo -e "Options (${BOLD}${CYAN}shared${NC}):"
    echo "  -h, --help               Show this help message"
    echo "  --proxy <url>            HTTP/HTTPS proxy for apt/downloads inside the VM"
    echo
    echo -e "Options (${BOLD}${CYAN}first boot${NC}): Use for fresh ubuntu vm creation"
    echo "  -i, --iso-path FILE      Path to Ubuntu installer ISO (optional)"
    echo "                           Downloads from --download_url or --output-dir if not provided"
    echo "  -n, --vm-name NAME       VM name and disk image prefix (default: ubuntu24_1)"
    echo "  -s, --vm-size SIZE       VM disk size (default: 50G)"
    echo "  -o, --output-dir DIR     VM output directory (default: ${DEFAULT_DOWNLOAD_DIR})"
    echo "  -m, --memory MB          VM memory in MB (default: 4096)"
    echo "  -c, --vcpus NUM          Number of vCPUs (default: 4)"
    echo "  --download_url <url>     URL to download Ubuntu ISO (saved to --output-dir)"
    echo "                           Default: $DEFAULT_UBUNTU_ISO_URL"
    echo "  --vm-username <name>     Username to create in the guest OS (default: user)"
    echo "  --vm-password <pass>     Password for the guest OS user (default: user1234)"
    echo "  --ovmf-code <path>       OVMF firmware code file (default: /usr/share/OVMF/OVMF_CODE_4M.fd)"
    echo "  --ovmf-vars <path>       OVMF firmware vars file"
    echo "  --vm-image <path>        Explicit output disk image path"
    echo "  --force-install          Overwrite existing VM disk and re-run the installer"
    echo "  --vm-reboot              Reboot the VM after automatic setup completes"
    echo "                           (default without this flag: shutdown after setup)"
    echo "  --proxy <url>            HTTP/HTTPS proxy URL (e.g., http://proxy.example.com:911)"
    echo
    echo -e "${BOLD}Examples:${NC}"
    echo
    echo -e "  ${BOLD}${CYAN}Simplest (all defaults, auto-downloads ISO):${NC}"
    echo "    ./create-vm-ubuntu.sh"
    echo
    echo -e "  ${BOLD}${CYAN}Minimal (uses defaults: user/user1234):${NC}"
    echo "    ./create-vm-ubuntu.sh -i ./ubuntu-24.04.4-desktop-amd64.iso"
    echo
    echo -e "  ${BOLD}${CYAN}Custom credentials and setup + reboot:${NC}"
    echo "    ./create-vm-ubuntu.sh -i /path/to/ubuntu-24.04.4-desktop-amd64.iso \\"
    echo "               --vm-username myuser --vm-password MyPass123 \\"
    echo "               --vm-reboot"
    echo
    echo -e "  ${BOLD}${CYAN}Auto-download with larger disk and memory:${NC}"
    echo "    ./create-vm-ubuntu.sh --download_url https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-desktop-amd64.iso \\"
    echo "               --vm-username myuser --vm-password MyPass123 \\"
    echo "               -s 100G -m 16384 -c 8 --vm-reboot"
    echo
    echo -e "  ${BOLD}${CYAN}Force-reinstall an existing image:${NC}"
    echo "    ./create-vm-ubuntu.sh --vm-image /path/to/ubuntu.img \\"
    echo "               -i /path/to/ubuntu-24.04.4-desktop-amd64.iso \\"
    echo "               --force-install"
    echo
}

# Print header with border
print_header() {
    local header="$1"
    local border
    border=$(printf '+%0.s-' {1..66})
    border="${border:0:66}"
    echo -e "${BOLD}${BLUE}${border}${NC}" >&2
    echo -e "${BOLD}${BLUE}| ${header}$(printf '%*s' $((64 - ${#header})) '')${BLUE}|${NC}" >&2
    echo -e "${BOLD}${BLUE}${border}${NC}" >&2
}

# Print message with border
print_message() {
    local header="$1"
    shift
    local messages=("$@")

    local border
    border=$(printf '+%0.s-' {1..66})
    border="${border:0:66}"
    echo -e "${BOLD}${BLUE}${border}${NC}" >&2
    echo -e "${BOLD}${BLUE}| ${header}$(printf '%*s' $((64 - ${#header})) '')${BLUE}|${NC}" >&2
    echo -e "${BOLD}${BLUE}${border}${NC}" >&2

    for msg in "${messages[@]}"; do
        echo -e "${BLUE}| ${msg}$(printf '%*s' $((62 - ${#msg})) '')${BLUE}|${NC}" >&2
    done

    echo -e "${BOLD}${BLUE}${border}${NC}" >&2
}

# Print error message and exit
print_error() {
    local msg="$1"
    echo -e "${RED}✗ Error: ${msg}${NC}" >&2
}

# Print success message
print_success() {
    echo -e "${GREEN}✓ ${1}${NC}" >&2
}

# Print warn message
print_warn() {
    echo -e "${YELLOW}⚠ ${1}${NC}" >&2
}

# Print info message
print_info() {
    echo -e "${BLUE}ℹ ${1}${NC}" >&2
}

cleanup_on_exit() {
    if [[ "$SCRIPT_COMPLETED_SUCCESSFULLY" == true ]]; then
        return 0
    fi

    if [[ -n "$TRACKED_ISO_PATH" && -f "$TRACKED_ISO_PATH" ]]; then
        print_warn "Download was interrupted; removing incomplete ISO to force fresh download next run: $TRACKED_ISO_PATH"
        rm -f "$TRACKED_ISO_PATH" || true
    fi

    if [[ -n "$INSTALL_TMP_DIR" && -d "$INSTALL_TMP_DIR" ]]; then
        rm -rf "$INSTALL_TMP_DIR" || true
        INSTALL_TMP_DIR=""
    fi
}

# Download file from URL
download_file() {
    local url="$1"
    local output_file="$2"
    local messages=()

    if [[ -f "$output_file" ]]; then
        messages+=("File ${output_file} already exists. Skipping download.")
    else
        messages+=("Downloading ${url}...")
        messages+=("Please wait, this may take several minutes...")
        print_message "Download ISO" "${messages[@]}"
        echo

        if ! sudo wget -q --show-progress --progress=bar:force:noscroll "$url" -O "$output_file" 2>&1; then
            echo
            messages=("Failed to download ${url}")
            print_message "Download ISO" "${messages[@]}"
            exit 1
        fi

        echo
        messages=("Successfully downloaded: $(basename "$url")")
        messages+=("File size: $(du -h "$output_file" | cut -f1)")
        print_message "Download ISO" "${messages[@]}"
        return 0
    fi

    print_message "Download ISO" "${messages[@]}"
}

# Best-effort remote content-length lookup.
get_remote_content_length() {
    local url="$1"

    if [[ -z "$url" ]]; then
        return 0
    fi

    if command -v curl &> /dev/null; then
        curl -fsIL "$url" 2>/dev/null | tr -d '\r' | awk '
            tolower($1) == "content-length:" { size=$2 }
            END { if (size ~ /^[0-9]+$/) print size }
        '
        return 0
    fi

    if command -v wget &> /dev/null; then
        wget --server-response --spider "$url" 2>&1 | tr -d '\r' | awk '
            tolower($1) == "content-length:" { size=$2 }
            END { if (size ~ /^[0-9]+$/) print size }
        '
    fi
}

# Validate Ubuntu installer ISO by mountability and casper payload presence.
is_valid_ubuntu_iso() {
    local iso_file="$1"
    local mount_point="/tmp/verify_ubuntu_iso_$$"

    mkdir -p "$mount_point"

    if ! sudo mount -o loop,ro "$iso_file" "$mount_point" 2>/dev/null; then
        rmdir "$mount_point" 2>/dev/null || true
        return 1
    fi

    local is_valid=false
    if [[ -f "$mount_point/casper/vmlinuz" && -f "$mount_point/casper/initrd" ]]; then
        is_valid=true
    fi

    sudo umount "$mount_point" >/dev/null 2>&1 || true
    rmdir "$mount_point" 2>/dev/null || true

    [[ "$is_valid" == true ]]
}

# Verify ISO file
verify_iso_file() {
    local iso_file="$1"
    local source_url="${2:-}"
    local messages=()

    if [[ ! -f "$iso_file" ]]; then
        messages+=("ISO file not found: ${iso_file}")
        print_message "Verify ISO" "${messages[@]}"
        return 1
    fi

    local file_size_bytes
    local file_size_human
    file_size_bytes=$(stat -c '%s' "$iso_file" 2>/dev/null || echo 0)
    file_size_human=$(du -h "$iso_file" | cut -f1)

    messages+=("ISO file found: $(basename "$iso_file")")
    messages+=("File size: ${file_size_human}")

    if (( file_size_bytes < MIN_UBUNTU_DESKTOP_ISO_BYTES )); then
        messages+=("ISO appears incomplete: size below minimum threshold (${MIN_UBUNTU_DESKTOP_ISO_BYTES} bytes)")
        print_message "Verify ISO" "${messages[@]}"
        return 1
    fi

    local remote_size
    remote_size=$(get_remote_content_length "$source_url")
    if [[ -n "$remote_size" && "$remote_size" =~ ^[0-9]+$ ]]; then
        messages+=("Remote size: $(numfmt --to=iec --suffix=B "$remote_size" 2>/dev/null || echo "$remote_size bytes")")
        if [[ "$file_size_bytes" != "$remote_size" ]]; then
            messages+=("ISO size mismatch against remote source")
            print_message "Verify ISO" "${messages[@]}"
            return 1
        fi
    else
        messages+=("Remote size check: unavailable (continuing with local validation)")
    fi

    if ! is_valid_ubuntu_iso "$iso_file"; then
        messages+=("ISO content validation failed (missing casper/vmlinuz or casper/initrd)")
        print_message "Verify ISO" "${messages[@]}"
        return 1
    fi

    messages+=("ISO payload validation passed")
    print_message "Verify ISO" "${messages[@]}"
    return 0
}

# Check whether a VM image looks bootable by inspecting its partition table.
# Uses fdisk -l directly on the image file — no loop device required, no udev races.
# Falls back to partprobe/blkid via losetup only when fdisk is unavailable.
is_bootable_vm_image() {
    local vm_img="$1"

    [[ -f "$vm_img" ]] || return 1

    # Minimum size sanity check: a freshly installed Ubuntu is well over 2 GB.
    local img_size
    img_size=$(stat -c '%s' "$vm_img" 2>/dev/null || echo 0)
    if (( img_size < 1073741824 )); then
        print_warn "VM image is smaller than 1 GB (${img_size} bytes); treating as incomplete"
        return 1
    fi

    # Primary method: fdisk reads the partition table directly from the image file.
    # This requires no loop device and has no udev timing dependency.
    if command -v fdisk &> /dev/null; then
        local fdisk_out
        fdisk_out=$(sudo fdisk -l "$vm_img" 2>/dev/null || true)

        if [[ -z "$fdisk_out" ]]; then
            print_warn "fdisk returned no output for $vm_img; skipping strict bootability validation"
            return 0
        fi

        # A valid installed image will have at least one partition entry listed by fdisk.
        # Partition lines start with the image path followed by a digit.
        if echo "$fdisk_out" | grep -qE "^${vm_img}[0-9]"; then
            return 0
        fi

        print_warn "No partitions found in $vm_img via fdisk; image appears empty or corrupt"
        return 1
    fi

    # Fallback: fdisk not available — use parted if present.
    if command -v parted &> /dev/null; then
        local parted_out
        parted_out=$(sudo parted -s "$vm_img" print 2>/dev/null || true)

        if echo "$parted_out" | grep -q "^ *[0-9]"; then
            return 0
        fi

        if [[ -n "$parted_out" ]]; then
            print_warn "No partitions found in $vm_img via parted; image appears empty or corrupt"
            return 1
        fi

        print_warn "parted returned no output for $vm_img; skipping strict bootability validation"
        return 0
    fi

    # No partition inspection tools available — skip validation.
    print_warn "fdisk/parted not available; skipping bootability validation for $vm_img"
    return 0
}

# Create VM disk image
create_vm_disk() {
    local vm_img="$1"
    local vm_size="$2"
    local messages=()

    if [[ -f "$vm_img" ]]; then
        local file_size
        file_size=$(du -h "$vm_img" | cut -f1)
        messages+=("VM image already exists: ${vm_img}")
        messages+=("Current size: ${file_size}")
    else
        messages+=("Creating VM disk image: ${vm_img}")
        messages+=("Size: ${vm_size}")

        if ! qemu-img create -f raw -o size="${vm_size}" "$vm_img"; then
            messages+=("Failed to create VM disk image")
            print_message "Create VM Disk" "${messages[@]}"
            return 1
        fi
        messages+=("VM disk image created successfully")
    fi

    print_message "Create VM Disk" "${messages[@]}"
    return 0
}

# Verify OVMF files
verify_ovmf() {
    local ovmf_code="$1"
    local ovmf_vars="$2"
    local messages=()

    if [[ ! -f "$ovmf_code" ]]; then
        print_info "OVMF code file not found. Attempting to install OVMF package..."
        echo

        # Try to install OVMF
        if sudo apt-get update > /dev/null 2>&1 && sudo apt-get install -y ovmf > /dev/null 2>&1; then
            print_success "OVMF package installed successfully"
            echo

            # Check again if file exists
            if [[ ! -f "$ovmf_code" ]]; then
                messages+=("OVMF package installed, but expected file not found: ${ovmf_code}")
                messages+=("")
                messages+=("Available OVMF files:")
                # List available OVMF files
                if [[ -d "/usr/share/OVMF/" ]]; then
                    local ovmf_files
                    ovmf_files=$(find /usr/share/OVMF/ -maxdepth 1 -mindepth 1 -printf '%f ' 2>/dev/null)
                    messages+=("  $ovmf_files")
                    messages+=("")
                    messages+=("Specify a valid OVMF file with: --ovmf-code /usr/share/OVMF/OVMF_CODE.fd")
                fi
                print_message "Verify OVMF" "${messages[@]}"
                return 1
            fi
        else
            print_error "Failed to install OVMF package"
            print_info "Please install manually: sudo apt-get install ovmf"
            return 1
        fi
    fi

    messages+=("OVMF code file found: $(basename "$ovmf_code")")

    if [[ -n "$ovmf_vars" ]] && [[ ! -f "$ovmf_vars" ]]; then
        messages+=("OVMF vars file not found: ${ovmf_vars}")
        messages+=("Will use code file only")
    elif [[ -n "$ovmf_vars" ]]; then
        messages+=("OVMF vars file found: $(basename "$ovmf_vars")")
    fi

    print_message "Verify OVMF" "${messages[@]}"
    return 0
}

# Detect if running via SSH
is_ssh_session() {
    [[ -n "$SSH_CONNECTION" ]] || [[ -n "$SSH_CLIENT" ]] || [[ -n "$SSH_TTY" ]]
}

# Set hugepages for VM memory
# Hugepages are 2MB each by default on most Linux systems
# Formula: hugepages_needed = memory_mb / 2
# Example: 8192 MB / 2 = 4096 hugepages (4096 × 2MB = 8192 MB)
set_hugepages() {
    local memory_mb="$1"
    local messages=()

    # Calculate hugepages needed (assuming 2MB hugepages)
    # Each hugepage = 2MB, so: hugepages_needed = memory_mb / 2
    local hugepages_needed=$((memory_mb / 2))

    messages+=("Configuring hugepages for VM...")
    messages+=("Memory requested: ${memory_mb} MB")
    messages+=("Hugepage size: 2 MB (standard)")
    messages+=("Hugepages needed: ${hugepages_needed} (${memory_mb}MB ÷ 2MB/page)")
    messages+=("Total memory: ${hugepages_needed} pages × 2MB = ${memory_mb}MB")

    print_message "Configure Hugepages" "${messages[@]}"
    echo

    print_info "Setting hugepages to ${hugepages_needed}..."

    if echo "$hugepages_needed" | sudo tee /proc/sys/vm/nr_hugepages > /dev/null 2>&1; then
        # Verify the setting
        local actual_hugepages
        actual_hugepages=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo "0")
        if [[ "$actual_hugepages" == "$hugepages_needed" ]]; then
            print_success "Hugepages set successfully to ${actual_hugepages}"
        else
            print_info "Requested ${hugepages_needed} hugepages, but system has ${actual_hugepages}"
        fi
    else
        print_error "Failed to set hugepages"
        return 1
    fi

    echo
}

# Detect VFIO PCI host device from available VGA controllers
# Prefers non-primary functions (e.g. .1, .2) and falls back to first VGA device.
get_vfio_pci_host() {
    if ! command -v lspci &> /dev/null; then
        return 1
    fi

    local selected_slot=""
    local line slot

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        slot="${line%% *}"

        # Prefer VF-like functions (non-.0)
        if [[ "$slot" =~ \.[1-9]$ ]]; then
            selected_slot="$slot"
            break
        fi

        # Keep first VGA as fallback
        if [[ -z "$selected_slot" ]]; then
            selected_slot="$slot"
        fi
    done < <(lspci | grep -i "VGA compatible controller")

    [[ -n "$selected_slot" ]] || return 1

    # Normalize to full domain form expected by vfio (0000:BB:DD.F)
    if [[ "$selected_slot" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$ ]]; then
        echo "$selected_slot"
    else
        echo "0000:$selected_slot"
    fi
}

# Wait for SSH to be available on VM
ensure_sshpass() {
    if command -v sshpass &> /dev/null; then
        return 0
    fi

    print_info "Installing sshpass for automated SSH provisioning..."
    if sudo apt-get update > /dev/null 2>&1 && sudo apt-get install -y sshpass > /dev/null 2>&1; then
        print_success "sshpass installed successfully"
        return 0
    fi

    print_error "Failed to install sshpass"
    return 1
}

wait_for_ssh() {
    local timeout=300  # seconds to wait for SSH (5 minutes for VM to be fully ready)
    local start_time
    start_time=$(date +%s)
    local elapsed=0

    ensure_sshpass || return 1

    print_info "Waiting for VM to be SSH-accessible..."

    while true; do
        # Actually attempt SSH connection to verify it's ready
        if SSHPASS="$VM_PASSWORD" sshpass -e ssh \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=2 \
            -p 3333 "${VM_USERNAME}@localhost" "echo SSH_READY" 2>/dev/null | grep -q "SSH_READY"; then
            print_success "SSH is now accessible"
            return 0
        fi

        local current_time
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))

        # Print progress every 10 seconds
        if (( elapsed % 10 == 0 )) && (( elapsed > 0 )); then
            print_info "Still waiting for SSH... (${elapsed}s elapsed)"
        fi

        if (( elapsed >= timeout )); then
            print_warn "Timeout waiting for SSH after ${timeout} seconds"
            return 1
        fi

        sleep 1
    done
}

# Run post-boot provisioning (copy and execute setup script)
run_post_boot_provisioning() {
    # Resolve repository root from this script location:
    # <repo>/sriov-toolkit/scripts/create-vm.sh -> <repo>
    # install-host.sh must come from <repo>/installer/install-host.sh
    local toolkit_dir=""
    local toolkit_name=""
    local setup_script=""
    local repo_root=""

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    repo_root="$(cd "$script_dir/../.." && pwd)"
    toolkit_dir="$repo_root"
    toolkit_name="$(basename "$toolkit_dir")"
    setup_script="${repo_root}/installer/install-host.sh"

    if [[ ! -f "$setup_script" ]]; then
        print_error "Setup script not found: $setup_script"
        print_info "Expected host setup script at: ${repo_root}/installer/install-host.sh"
        return 1
    fi

    ensure_sshpass || return 1

    echo
    print_info "Copying toolkit directory to VM..."
    print_info "  Source: $toolkit_dir"
    print_info "  Destination: ${VM_USERNAME}@localhost:/tmp/$toolkit_name"

    local dir_size
    dir_size=$(du -sh "$toolkit_dir" | cut -f1)
    print_info "  Directory size: $dir_size"

    # Copy entire toolkit directory to guest (recursive)
    if SSHPASS="$VM_PASSWORD" sshpass -e scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 3333 "$toolkit_dir" "${VM_USERNAME}@localhost:/tmp/" 2>/dev/null; then
        print_success "Toolkit directory copied successfully to /tmp/$toolkit_name"
    else
        print_error "Failed to copy toolkit directory"
        return 1
    fi

    echo
    print_info "Executing setup script in VM..."
    print_info "  Working directory: /tmp/$toolkit_name"

    # Build command with optional proxy parameter
    local vm_password_b64
    vm_password_b64=$(printf '%s' "$VM_PASSWORD" | base64 | tr -d '\n')
    local install_cmd="cd /tmp/$toolkit_name && printf '%s' '$vm_password_b64' | base64 -d | sudo -S -p '' bash installer/install-host.sh virtualization --automated"
    local display_cmd="cd /tmp/$toolkit_name && sudo bash installer/install-host.sh virtualization --automated"
    if [[ -n "$PROXY_URL" ]]; then
        install_cmd="${install_cmd} --proxy $PROXY_URL"
        display_cmd="${display_cmd} --proxy $PROXY_URL"
        print_info "  Proxy: $PROXY_URL"
    fi
    print_info "  Command: $display_cmd"
    echo

    # Execute setup script via SSH from the toolkit directory
    if SSHPASS="$VM_PASSWORD" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 3333 "${VM_USERNAME}@localhost" "$install_cmd"; then
        echo
        print_success "Setup script executed successfully"
        return 0
    else
        echo
        print_error "Setup script execution failed"
        print_info "Log file available at: $LOG_FILE"
        return 1
    fi
}

# Reboot VM after provisioning (requires SSH availability)
reboot_vm_guest() {
    print_info "Rebooting VM as requested (--vm-reboot)..."

    local vm_password_b64
    vm_password_b64=$(printf '%s' "$VM_PASSWORD" | base64 | tr -d '\n')
    local reboot_cmd="printf '%s' '$vm_password_b64' | base64 -d | sudo -S -p '' reboot"
    local ssh_output

    ssh_output=$(SSHPASS="$VM_PASSWORD" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p 3333 "${VM_USERNAME}@localhost" "$reboot_cmd" 2>&1)
    local ssh_status=$?

    if [[ $ssh_status -eq 0 ]]; then
        print_success "Reboot command sent to VM"
        return 0
    fi

    # During a successful reboot, SSH may disconnect before command exit is reported.
    # Treat common disconnect signatures as success.
    if echo "$ssh_output" | grep -Eiq "connection (to .* )?closed|broken pipe|connection reset|connection refused"; then
        print_success "Reboot initiated (SSH disconnected as expected)"
        return 0
    else
        [[ -n "$ssh_output" ]] && print_error "$ssh_output"
        print_error "Failed to reboot VM"
        return 1
    fi
}

# Shutdown VM after provisioning (requires SSH availability)
shutdown_vm_guest() {
    print_info "Shutting down VM after setup completion..."

    local vm_password_b64
    vm_password_b64=$(printf '%s' "$VM_PASSWORD" | base64 | tr -d '\n')
    local shutdown_cmd="printf '%s' '$vm_password_b64' | base64 -d | sudo -S -p '' shutdown -h now"
    local ssh_output

    ssh_output=$(SSHPASS="$VM_PASSWORD" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p 3333 "${VM_USERNAME}@localhost" "$shutdown_cmd" 2>&1)
    local ssh_status=$?

    if [[ $ssh_status -eq 0 ]]; then
        print_success "Shutdown command sent to VM"
        return 0
    fi

    # During a successful shutdown, SSH may disconnect before command exit is reported.
    # Treat common disconnect signatures as success.
    if echo "$ssh_output" | grep -Eiq "connection (to .* )?closed|broken pipe|connection reset|connection refused"; then
        print_success "Shutdown initiated (SSH disconnected as expected)"
        return 0
    else
        [[ -n "$ssh_output" ]] && print_error "$ssh_output"
        print_error "Failed to shut down VM"
        return 1
    fi
}

# Print VM access information after successful boot/reboot
print_vm_access_info() {
    echo
    echo -e "${GREEN}✓ VM reboot completed${NC}"
    echo
    echo -e "${BLUE}Access your VM:${NC}"
    echo -e "  ${BOLD}SSH:${NC} ssh -p 3333 ${VM_USERNAME}@localhost"
    echo -e "  ${BOLD}Password:${NC} (as specified with --vm-password)"
    echo
    echo -e "  ${BOLD}Display:${NC} GTK window should be visible"
    echo
    echo -e "${BLUE}To stop the VM:${NC}"
    echo -e "  sudo pkill -f 'qemu-system-x86_64.*vm_images'"
    echo -e "  or press Ctrl+C in the VM display window"
    echo
}

# Boot VM with QEMU
boot_vm() {
    local iso_file="$1"
    local vm_img="$2"
    local vm_memory="$3"
    local ovmf_code="$4"
    local ovmf_vars="$5"
    local kernel_file="$6"
    local initrd_file="$7"
    local seed_iso="${8:-}"
    local boot_phase="${9:-normal}"
    local run_background="${10:-false}"
    local vfio_host=""

    vfio_host=$(get_vfio_pci_host 2>/dev/null || true)

    local messages=()
    messages+=("Booting VM with QEMU...")
    if [[ -n "$iso_file" ]]; then
        messages+=("ISO: $(basename "$iso_file")")
    else
        messages+=("ISO: (none)")
    fi
    messages+=("VM Disk: $(basename "$vm_img")")
    messages+=("Memory: ${vm_memory} MB")
    messages+=("Display Mode: gtk")
    messages+=("Boot Mode: ${boot_phase}")
    if [[ -n "$vfio_host" ]]; then
        messages+=("VFIO Host: ${vfio_host}")
    fi

    if [[ -n "$kernel_file" ]]; then
        messages+=("Kernel: $(basename "$kernel_file")")
        messages+=("Initrd: $(basename "$initrd_file")")
        messages+=("Boot Method: Kernel boot with autoinstall")
    fi

    if [[ -n "$seed_iso" ]]; then
        messages+=("Cloud-Init Seed ISO: $(basename "$seed_iso")")
    fi

    print_message "Boot VM" "${messages[@]}"
    echo >&2

    # Build QEMU command
    local qemu_cmd=(
        "sudo" "qemu-system-x86_64"
        "-m" "$vm_memory"
        "-cpu" "host,host-phys-bits=on,host-phys-bits-limit=39"
        "-enable-kvm"
        "-smp" "cores=${VCPUS},threads=2,sockets=1"
        "-drive" "file=${ovmf_code},format=raw,if=pflash,unit=0,readonly=on"
    )

    # Add OVMF vars if specified
    if [[ -n "$ovmf_vars" ]]; then
        qemu_cmd+=("-drive" "file=${ovmf_vars},format=raw,if=pflash,unit=1")
    fi

    # Add drives and network
    qemu_cmd+=(
        "-drive" "file=${vm_img},format=raw,cache=none,if=virtio"
        "-net" "nic,netdev=net0"
        "-netdev" "user,id=net0,hostfwd=tcp::3333-:22"
        "-device" "virtio-vga"
        "-object" "memory-backend-memfd,hugetlb=on,id=mem1,size=${vm_memory}M"
        "-machine" "memory-backend=mem1"
    )

    if [[ -n "$vfio_host" ]]; then
        qemu_cmd+=("-device" "vfio-pci,host=${vfio_host}")
    else
        print_warn "No VGA compatible controller found for vfio-pci passthrough; continuing without vfio device"
    fi

    # Boot method: kernel+initrd with autoinstall, or CDROM fallback
    if [[ -n "$kernel_file" && -f "$kernel_file" && -n "$initrd_file" && -f "$initrd_file" ]]; then
        # Kernel boot with autoinstall
        qemu_cmd+=(
            "-kernel" "$kernel_file"
            "-initrd" "$initrd_file"
            "-append" "autoinstall ds=nocloud console=ttyS0 ---"
            "-no-reboot"
        )

        # Mount seed ISO as primary CDROM (cloud-init reads from here)
        qemu_cmd+=("-drive" "file=${seed_iso},media=cdrom,format=raw")

        # Mount Ubuntu ISO as secondary CDROM (installer reads packages from here)
        if [[ -n "$iso_file" ]]; then
            qemu_cmd+=("-drive" "file=${iso_file},media=cdrom,format=raw")
        fi
    else
        # Fallback to CDROM boot (manual installation)
        if [[ -n "$iso_file" ]]; then
            qemu_cmd+=("-cdrom" "$iso_file")
        fi
        if [[ "$boot_phase" == "installer" ]]; then
            qemu_cmd+=("-no-reboot")
        fi
    fi

    # For second-stage boot, force boot from installed disk
    if [[ "$boot_phase" == "Normal" ]]; then
        qemu_cmd+=("-boot" "order=c")
    fi

    # GTK-only display mode
    export DISPLAY=:0
    qemu_cmd+=("-display" "gtk")

    # Print QEMU command for debugging
    print_info "Executing QEMU command:"
    echo "${qemu_cmd[@]}" >&2
    echo >&2

    # Execute QEMU
    if [[ "$run_background" == true ]]; then
        # Run in background
        "${qemu_cmd[@]}" > /dev/null 2>&1 &
        local qemu_pid=$!

        echo
        print_success "VM started in background (PID: $qemu_pid)"
        echo
        echo -e "${BLUE}Access your VM:${NC}"
        echo -e "  ${BOLD}SSH:${NC} ssh -p 3333 ${VM_USERNAME}@localhost"
        echo -e "  ${BOLD}Password:${NC} (as specified with --vm-password)"
        echo
        echo -e "  ${BOLD}Display:${NC} GTK window should be visible"
        echo
        echo -e "${BLUE}To stop the VM:${NC}"
        echo -e "  sudo kill $qemu_pid"
        echo -e "  or press Ctrl+C in the VM display window"
        echo
        return 0
    else
        # Run blocking
        if "${qemu_cmd[@]}"; then
            print_success "QEMU VM completed successfully"
            return 0
        else
            print_error "QEMU VM failed with exit code $?"
            return 1
        fi
    fi
}


################################################################################
# KERNEL/INITRD EXTRACTION FUNCTIONS
################################################################################

# Extract kernel and initrd from Ubuntu ISO
extract_kernel_initrd() {
    local iso_file="$1"
    local output_dir="$2"

    print_message "Extract Kernel and Initrd" \
        "Mounting ISO: $(basename "$iso_file")" \
        "Output directory: $output_dir"
    echo >&2

    # Create temporary mount point
    local temp_mount="/tmp/ubuntu_iso_mount_$$"
    mkdir -p "$temp_mount" "$output_dir"

    # Mount ISO
    if ! sudo mount -o loop "$iso_file" "$temp_mount" 2>/dev/null; then
        print_error "Failed to mount ISO"
        rmdir "$temp_mount"
        return 1
    fi

    # Copy kernel and initrd
    local kernel_src="$temp_mount/casper/vmlinuz"
    local initrd_src="$temp_mount/casper/initrd"
    local kernel_dst="$output_dir/vmlinuz"
    local initrd_dst="$output_dir/initrd"

    if [[ ! -f "$kernel_src" ]]; then
        print_error "Kernel not found at $kernel_src"
        sudo umount "$temp_mount"
        rmdir "$temp_mount"
        return 1
    fi

    if [[ ! -f "$initrd_src" ]]; then
        print_error "Initrd not found at $initrd_src"
        sudo umount "$temp_mount"
        rmdir "$temp_mount"
        return 1
    fi

    print_info "Copying kernel..."
    sudo cp "$kernel_src" "$kernel_dst"
    sudo chown "$USER:$USER" "$kernel_dst"

    print_info "Copying initrd..."
    sudo cp "$initrd_src" "$initrd_dst"
    sudo chown "$USER:$USER" "$initrd_dst"

    # Unmount ISO
    sudo umount "$temp_mount"
    rmdir "$temp_mount"

    local kernel_size
    local initrd_size
    kernel_size=$(du -h "$kernel_dst" | cut -f1)
    initrd_size=$(du -h "$initrd_dst" | cut -f1)

    print_success "Kernel extracted: $kernel_dst ($kernel_size)"
    print_success "Initrd extracted: $initrd_dst ($initrd_size)"

    echo "$kernel_dst"
}

# Generate cloud-init seed ISO for autoinstall
generate_seed_iso() {
    local download_dir="$1"
    local seed_iso="${download_dir}/seed.iso"
    local temp_dir="${download_dir}/.seed_iso_tmp"
    local vm_password_hash
    local vm_password_b64

    # Generate password hash for cloud-init identity (SHA-512)
    vm_password_hash=$(openssl passwd -6 "$VM_PASSWORD")
    vm_password_b64=$(printf '%s' "$VM_PASSWORD" | base64 | tr -d '\n')

    print_message "Generate Cloud-Init Seed ISO" \
        "Creating seed ISO for autoinstall"
    echo >&2

    # Create temporary directory
    mkdir -p "$temp_dir"

    # Create user-data file (minimal config)
    {
        cat << EOF
#cloud-config
autoinstall:
    version: 1
    locale: en_US.UTF-8
    keyboard:
        layout: us
    network:
        version: 2
        ethernets:
            any:
                match:
                    name: en*
                dhcp4: true
    identity:
        hostname: ubuntu-vm
        username: $VM_USERNAME
        password: '$vm_password_hash'
    ssh:
        install-server: false
        allow-pw: true
    storage:
        layout:
            name: direct
    packages: []
    late-commands:
EOF
        # Add proxy configuration to late-commands only if PROXY_URL is set
        if [[ -n "$PROXY_URL" ]]; then
            cat << EOF
        - curtin in-target --target=/target -- bash -c 'echo "Acquire::http::Proxy \\"$PROXY_URL\\";" > /etc/apt/apt.conf.d/00proxy'
        - curtin in-target --target=/target -- bash -c 'echo "Acquire::https::Proxy \\"$PROXY_URL\\";" >> /etc/apt/apt.conf.d/00proxy'
EOF
        fi
        cat << 'EOF'
        - curtin in-target --target=/target -- apt-get update
        - curtin in-target --target=/target -- apt-get install -y openssh-server
        - curtin in-target --target=/target -- apt-get install -y qemu-guest-agent
EOF
        cat << EOF
        - curtin in-target --target=/target -- bash -c "pw=\\\$(echo '$vm_password_b64' | base64 -d); echo $VM_USERNAME:\\\$pw | chpasswd"
EOF
        cat << 'EOF'
        - curtin in-target --target=/target -- bash -c "if grep -q '^#\?PasswordAuthentication' /etc/ssh/sshd_config; then sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config; else echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config; fi"
        - curtin in-target --target=/target -- bash -c "if grep -q '^#\?KbdInteractiveAuthentication' /etc/ssh/sshd_config; then sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config; else echo 'KbdInteractiveAuthentication yes' >> /etc/ssh/sshd_config; fi"
        - curtin in-target --target=/target -- systemctl enable ssh
EOF
    } > "$temp_dir/user-data"

    # Create meta-data file
    cat > "$temp_dir/meta-data" << 'EOF'
{
  "local-hostname": "ubuntu-vm",
  "instance-id": "iid-local01"
}
EOF

    # Ensure mkisofs is available (provided by genisoimage on Ubuntu/Debian).
    if ! command -v mkisofs &> /dev/null; then
        print_info "mkisofs not found. Installing genisoimage..."
        if sudo apt-get update > /dev/null 2>&1 && sudo apt-get install -y genisoimage > /dev/null 2>&1; then
            print_success "genisoimage installed successfully"
        else
            print_error "Failed to install genisoimage (mkisofs)"
            rm -rf "$temp_dir"
            return 1
        fi
    fi

    # Create seed ISO using mkisofs
    print_info "Creating seed ISO with mkisofs..."
    if mkisofs -output "$seed_iso" \
            -volid cidata \
            -joliet \
            -rock \
            "$temp_dir" > /dev/null 2>&1; then
        local iso_size
        iso_size=$(du -h "$seed_iso" | cut -f1)
        print_success "Seed ISO created: $seed_iso ($iso_size)"
        rm -rf "$temp_dir"
        echo "$seed_iso"
        return 0
    fi

    print_error "Failed to create seed ISO with mkisofs"
    rm -rf "$temp_dir"
    return 1
}

################################################################################
# ARGUMENT PARSING
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --download_url)
                DOWNLOAD_URL="$2"
                shift 2
                ;;
            -o|--output-dir|--download_dir)
                DOWNLOAD_DIR="$2"
                shift 2
                ;;
            -i|--iso-path)
                ISO_PATH="$2"
                shift 2
                ;;
            --vm-image)
                VM_IMAGE="$2"
                shift 2
                ;;
            -n|--vm-name)
                VM_NAME="$2"
                shift 2
                ;;
            -s|--vm-size)
                VM_SIZE="$2"
                shift 2
                ;;
            -m|--memory|--vm-memory)
                VM_MEMORY="$2"
                shift 2
                ;;
            -c|--vcpus)
                VCPUS="$2"
                shift 2
                ;;
            --ovmf-code)
                OVMF_CODE="$2"
                shift 2
                ;;
            --ovmf-vars)
                OVMF_VARS="$2"
                shift 2
                ;;
            --force-install)
                FORCE_INSTALL=true
                shift
                ;;
            --vm-reboot)
                REBOOT_VM=true
                shift
                ;;
            --proxy)
                PROXY_URL="$2"
                shift 2
                ;;
            --vm-username)
                VM_USERNAME="$2"
                shift 2
                ;;
            --vm-password)
                VM_PASSWORD="$2"
                shift 2
                ;;
            -h|--help)
                SHOW_HELP=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

#################################################################################
# MAIN EXECUTION
################################################################################

main() {
    if [[ "$SHOW_HELP" == true ]]; then
        show_help
        exit 0
    fi

    # Defaults exist for credentials, but reject explicitly empty values.
    if [[ -z "$VM_USERNAME" ]]; then
        print_error "Invalid value: --vm-username cannot be empty"
        show_help
        exit 1
    fi
    if [[ -z "$VM_PASSWORD" ]]; then
        print_error "Invalid value: --vm-password cannot be empty"
        show_help
        exit 1
    fi

    # For force-install, require explicit VM image path to confirm overwrite target
    if [[ "$FORCE_INSTALL" == true ]]; then
        if [[ -z "$VM_IMAGE" ]]; then
            print_error "--force-install requires --vm-image to confirm the target disk image"
            show_help
            exit 1
        fi
    fi

    # For ISO/download mode, validate iso-path or download_url
    if [[ -z "$ISO_PATH" ]] && [[ -z "$DOWNLOAD_URL" ]]; then
        print_error "Either --iso-path or --download_url (or its default) must be specified"
        show_help
        exit 1
    fi

    # Validate VM username format (Linux-compatible)
    if [[ ! "$VM_USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        print_error "Invalid --vm-username. Use lowercase letters, digits, '_' or '-' and start with a letter or '_'"
        show_help
        exit 1
    fi
    if [[ ${#VM_USERNAME} -gt 32 ]]; then
        print_error "Invalid --vm-username. Maximum length is 32 characters"
        show_help
        exit 1
    fi

    # Download ISO when --iso-path is not provided.
    # --iso-path takes precedence over default/override download URL.
    if [[ -z "$ISO_PATH" ]] && [[ -n "$DOWNLOAD_URL" ]]; then
        ISO_DOWNLOAD_MODE=true
        print_info "Using download URL: ${DOWNLOAD_URL}"

        # Set default download directory if not specified
        if [[ -z "$DOWNLOAD_DIR" ]]; then
            DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
            print_info "Using default download directory: ${DOWNLOAD_DIR}"
        fi

        # Create download directory if it doesn't exist
        if [[ ! -d "$DOWNLOAD_DIR" ]]; then
            print_info "Creating directory: ${DOWNLOAD_DIR}"
            mkdir -p "$DOWNLOAD_DIR"
        fi

        # Download ISO
        ISO_PATH="${DOWNLOAD_DIR}/$(basename "$DOWNLOAD_URL")"
        TRACKED_ISO_PATH="$ISO_PATH"
        download_file "$DOWNLOAD_URL" "$ISO_PATH"
        TRACKED_ISO_PATH=""  # download complete; don't remove on later failures
    fi

    # Verify ISO and redownload once if invalid in download mode.
    if ! verify_iso_file "$ISO_PATH" "$DOWNLOAD_URL"; then
        if [[ "$ISO_DOWNLOAD_MODE" == true ]]; then
            print_warn "ISO verification failed. Removing and re-downloading: $ISO_PATH"
            rm -f "$ISO_PATH"
            TRACKED_ISO_PATH="$ISO_PATH"  # track the fresh download only
            download_file "$DOWNLOAD_URL" "$ISO_PATH"
            TRACKED_ISO_PATH=""  # download complete
            verify_iso_file "$ISO_PATH" "$DOWNLOAD_URL" || exit 1
        else
            exit 1
        fi
    fi

    # Verify OVMF files
    verify_ovmf "$OVMF_CODE" "$OVMF_VARS" || exit 1

    # Set up VM paths
    local vm_dir=""
    local vm_img=""
    if [[ -n "$VM_IMAGE" ]]; then
        vm_img="$VM_IMAGE"
        vm_dir="$(dirname "$VM_IMAGE")"
    else
        vm_dir="${DOWNLOAD_DIR:-$DEFAULT_DOWNLOAD_DIR}"
        vm_img="${vm_dir}/${VM_NAME}.img"
    fi

    if [[ ! -d "$vm_dir" ]]; then
        print_info "Creating VM image directory: ${vm_dir}"
        mkdir -p "$vm_dir"
    fi

    OUTPUT_VM_IMAGE="$vm_img"
    local vm_img_exists=false
    if [[ -f "$vm_img" ]]; then
        vm_img_exists=true
        if [[ "$FORCE_INSTALL" == true ]]; then
            print_info "Force install enabled: existing VM image will be reinstalled: $vm_img"
        else
            print_error "Existing VM image detected: $vm_img"
            print_info "This script is install/setup only. Use scripts/launch-vm.sh to boot existing VMs."
            print_info "To reinstall this image, rerun with --force-install --vm-image $vm_img"
            exit 1
        fi
    fi
    print_info "Running installer/setup flow"

    # Reinstall path must use a fresh disk image.
    if [[ "$FORCE_INSTALL" == true && "$vm_img_exists" == true ]]; then
        print_info "Removing existing VM image before reinstall: $vm_img"
        rm -f "$vm_img"
    fi

    local kernel_file=""
    local initrd_file=""
    local seed_iso=""
    local boot_iso="$ISO_PATH"

    # Extract kernel and initrd from ISO for autoinstall boot
    print_info "Extracting kernel and initrd for autoinstall..."
    echo

    local install_tmp_dir="${vm_dir}/.install-tmp"
    mkdir -p "$install_tmp_dir"
    INSTALL_TMP_DIR="$install_tmp_dir"

    kernel_file=$(extract_kernel_initrd "$ISO_PATH" "$install_tmp_dir") || print_warn "Could not extract kernel/initrd"

    if [[ -n "$kernel_file" ]]; then
        # Kernel and initrd ready for automated boot
        initrd_file="${install_tmp_dir}/initrd"

        # Generate seed ISO for autoinstall
        print_info "Generating autoinstall seed ISO..."
        echo
        seed_iso=$(generate_seed_iso "$install_tmp_dir") || print_warn "Could not generate seed ISO"

        echo
    fi

    # Create VM disk
    create_vm_disk "$vm_img" "$VM_SIZE" || exit 1

    # Configure hugepages for VM memory
    set_hugepages "$VM_MEMORY" || exit 1

    # Boot VM with kernel/initrd for autoinstall (or fallback to CDROM)
    boot_vm "$boot_iso" "$vm_img" "$VM_MEMORY" "$OVMF_CODE" "$OVMF_VARS" "$kernel_file" "$initrd_file" "$seed_iso" "installer" || exit 1

    # Auto-boot installed system in same script run
    print_info "Installer phase completed; reboot requested by guest."
    echo

    # Clean up hidden temporary installation files
    if [[ -n "$install_tmp_dir" && -d "$install_tmp_dir" ]]; then
        print_info "Cleaning up temporary installation files..."
        rm -rf "$install_tmp_dir" && print_success "Removed temporary install directory"
        INSTALL_TMP_DIR=""
    fi
    echo

    print_info "Starting normal disk boot..."
    echo
    boot_vm "" "$vm_img" "$VM_MEMORY" "$OVMF_CODE" "$OVMF_VARS" "" "" "" "normal" true || exit 1

    echo
    print_header "Post-Boot Provisioning"

    # Wait for SSH to be available
    if ! wait_for_ssh; then
        print_error "Failed to establish SSH connection for provisioning"
        print_warn "VM is running, but post-boot provisioning was skipped"
        return 1
    fi
    echo

    # Run provisioning script
    run_post_boot_provisioning || return 1

    # Reboot guest VM if requested
    if [[ "$REBOOT_VM" == true ]]; then
        reboot_vm_guest || return 1
        print_vm_access_info
    else
        shutdown_vm_guest || return 1
    fi
}

# Handle --help before logging setup to avoid tee pipe requiring Enter to return to prompt
for arg in "$@"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
        show_help
        exit 0
    fi
done

# Execute main function with all arguments
initialize_logging
trap cleanup_on_exit EXIT INT TERM
parse_arguments "$@"
main
SCRIPT_COMPLETED_SUCCESSFULLY=true

LAUNCH_VM_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/launch-vm.sh"

echo "[$RUN_TIMESTAMP] create-vm-ubuntu.sh completed"
echo "[INFO] Log file available at: $LOG_FILE"
if [[ -n "$OUTPUT_VM_IMAGE" ]]; then
    echo "[INFO] VM image output directory : ${DOWNLOAD_DIR:-$DEFAULT_DOWNLOAD_DIR}"
    echo "[INFO] VM image created at       : $OUTPUT_VM_IMAGE"
fi
echo "[INFO] To launch the VM, run launch-vm.sh with the config file, for example:"
echo "[INFO] sudo $LAUNCH_VM_SCRIPT_PATH -d 3 -c config/vm-config/bmg-idv-config.xml"
