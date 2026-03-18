#!/bin/bash

# Create Windows VM Script
# Builds a VM disk image and boots Windows installer with QEMU/KVM.

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    echo -e "${BLUE}=== Windows VM Creator Help ===${NC}\n"
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help                 Show this help message"
    echo "  -i, --iso-path FILE        Windows installer ISO path (required)"
    echo "  -s, --vm-size SIZE         VM image size (default: 100G)"
    echo "  -n, --vm-name NAME         VM name (default: win11_1)"
    echo "  -o, --output-dir DIR       VM output directory (default: /data/vm-images)"
    echo "  -m, --memory MB            VM memory in MB (default: 4096)"
    echo "  -c, --vcpus NUM            Number of vCPUs (default: 4)"
    echo "      --auto-press-boot-key  Send keypresses automatically at boot via QMP"
    echo "      --os-variant NAME      Windows variant label (default: win11)"
    echo
    echo "Examples:"
    echo "  $0 -i <windows_iso_path>"
    echo "  $0 -i <windows_iso_path> -m 8192 -c 8"
    echo
}

print_error() { echo -e "${RED}Error: $*${NC}" >&2; }
print_info() { echo -e "${BLUE}[INFO ]${NC} $*"; }
print_success() { echo -e "${GREEN}[OK   ]${NC} $*"; }

install_missing_dependencies() {
    local missing_packages=()
    local pkg

    command -v swtpm >/dev/null 2>&1 || missing_packages+=("swtpm")
    command -v socat >/dev/null 2>&1 || missing_packages+=("socat")

    [[ ${#missing_packages[@]} -eq 0 ]] && return 0

    command -v apt-get >/dev/null 2>&1 || {
        print_error "Missing tools detected (${missing_packages[*]}), but apt-get is not available"
        exit 1
    }

    # De-duplicate package names in case multiple commands map to one package.
    local unique_packages=()
    for pkg in "${missing_packages[@]}"; do
        if [[ " ${unique_packages[*]} " != *" ${pkg} "* ]]; then
            unique_packages+=("$pkg")
        fi
    done

    print_info "Installing missing dependencies: ${unique_packages[*]}"

    if [[ $(id -u) -eq 0 ]]; then
        apt-get update
        apt-get install -y "${unique_packages[@]}"
    else
        command -v sudo >/dev/null 2>&1 || {
            print_error "sudo is required to install missing dependencies: ${unique_packages[*]}"
            exit 1
        }
        sudo apt-get update
        sudo apt-get install -y "${unique_packages[@]}"
    fi

    print_success "Dependencies ready"
}

validate_size_format() {
    local size="$1"
    [[ "$size" =~ ^[0-9]+[GM]$ ]]
}

cleanup_tpm_service() {
    local swtpm_pid_file="$1"
    if [[ -f "$swtpm_pid_file" ]]; then
        local swtpm_pid
        swtpm_pid=$(<"$swtpm_pid_file")
        if [[ -n "$swtpm_pid" ]] && kill -0 "$swtpm_pid" 2>/dev/null; then
            kill "$swtpm_pid" 2>/dev/null || true
        fi
        rm -f "$swtpm_pid_file"
    fi
}

start_tpm_service() {
    local vm_name="$1"
    local tpm_runtime_dir="$2"
    local tpm_socket_file="$3"
    local swtpm_pid_file="$4"
    local tpm_state_dir="${tpm_runtime_dir}/state"

    if ! command -v swtpm >/dev/null 2>&1; then
        print_error "swtpm is required for TPM 2.0 support"
        exit 1
    fi

    mkdir -p "$tpm_runtime_dir" "$tpm_state_dir"
    rm -f "$tpm_socket_file" "$swtpm_pid_file"

    swtpm socket \
        --tpm2 \
        --tpmstate dir="$tpm_state_dir" \
        --ctrl type=unixio,path="$tpm_socket_file" \
        --pid file="$swtpm_pid_file" \
        --daemon

    local i
    for i in {1..10}; do
        [[ -S "$tpm_socket_file" ]] && return 0
        sleep 1
    done

    print_error "TPM socket not created: $tpm_socket_file"
    exit 1
}

auto_press_boot_key() {
    local qmp_socket="$1"

    # Wait for QMP socket creation, then send key presses several times to
    # improve chances of catching the brief Windows DVD boot prompt.
    local i
    for i in {1..15}; do
        [[ -S "$qmp_socket" ]] && break
        sleep 1
    done

    [[ -S "$qmp_socket" ]] || return 0

    sleep 2
    for i in {1..8}; do
        printf '{"execute":"qmp_capabilities"}\n{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"spc"}]}}\n{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"ret"}]}}\n' \
            | socat - UNIX-CONNECT:"$qmp_socket" >/dev/null 2>&1 || true
        sleep 1
    done
}

main() {
    local iso_path=""
    local vm_size="100G"
    local vm_name="win11_1"
    local output_dir="/data/vm-images"
    local vm_memory="4096"
    local vcpus="4"
    local auto_press_boot_key_enabled="true"
    local os_variant="win11"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -i|--iso-path)
                [[ -n "${2:-}" && "${2}" != -* ]] || { print_error "Missing value for $1"; exit 1; }
                iso_path="$2"
                shift 2
                ;;
            -s|--vm-size)
                [[ -n "${2:-}" && "${2}" != -* ]] || { print_error "Missing value for $1"; exit 1; }
                vm_size="$2"
                shift 2
                ;;
            -n|--vm-name)
                [[ -n "${2:-}" && "${2}" != -* ]] || { print_error "Missing value for $1"; exit 1; }
                vm_name="$2"
                shift 2
                ;;
            -o|--output-dir)
                [[ -n "${2:-}" && "${2}" != -* ]] || { print_error "Missing value for $1"; exit 1; }
                output_dir="$2"
                shift 2
                ;;
            -m|--memory)
                [[ -n "${2:-}" && "${2}" =~ ^[0-9]+$ ]] || { print_error "Invalid or missing value for $1"; exit 1; }
                vm_memory="$2"
                shift 2
                ;;
            -c|--vcpus)
                [[ -n "${2:-}" && "${2}" =~ ^[0-9]+$ ]] || { print_error "Invalid or missing value for $1"; exit 1; }
                vcpus="$2"
                shift 2
                ;;
            --auto-press-boot-key)
                auto_press_boot_key_enabled="true"
                shift
                ;;
            --os-variant)
                [[ -n "${2:-}" && "${2}" != -* ]] || { print_error "Missing value for $1"; exit 1; }
                os_variant="$2"
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    [[ -n "$iso_path" ]] || { print_error "Windows ISO path is required. Use --iso-path"; exit 1; }
    [[ -f "$iso_path" ]] || { print_error "ISO file does not exist: $iso_path"; exit 1; }
    validate_size_format "$vm_size" || { print_error "Invalid --vm-size format: $vm_size"; exit 1; }

    install_missing_dependencies

    print_info "OS variant label: ${os_variant}"

    if [[ "$auto_press_boot_key_enabled" == "true" ]]; then
        command -v socat >/dev/null 2>&1 || { print_error "--auto-press-boot-key requires socat"; exit 1; }
        print_info "Auto boot keypress enabled"
    fi

    local vm_img
    local ovmf_code_local ovmf_vars_local
    local tpm_runtime_dir tpm_socket_file swtpm_pid_file
    local qmp_socket
    local ovmf_args tpm_args qemu_cmd qmp_args

    mkdir -p "$output_dir"
    vm_img="${output_dir}/${vm_name}.qcow2"
    ovmf_code_local="${output_dir}/${vm_name}_OVMF_CODE_4M.fd"
    ovmf_vars_local="${output_dir}/${vm_name}_OVMF_VARS_4M.fd"
    # Keep swtpm runtime files under /tmp to avoid AppArmor path denies under workspace directories.
    tpm_runtime_dir="/tmp/sriov-${UID}-${vm_name}_tpm"
    tpm_socket_file="${tpm_runtime_dir}/swtpm.sock"
    swtpm_pid_file="${tpm_runtime_dir}/swtpm.pid"
    qmp_socket="/tmp/sriov-${UID}-${vm_name}.qmp.sock"

    [[ -f "$vm_img" ]] && { print_error "VM image already exists: $vm_img"; exit 1; }
    [[ -f "/usr/share/OVMF/OVMF_CODE_4M.fd" ]] || { print_error "System OVMF code file not found: /usr/share/OVMF/OVMF_CODE_4M.fd"; exit 1; }
    [[ -f "/usr/share/OVMF/OVMF_VARS_4M.fd" ]] || { print_error "System OVMF vars file not found: /usr/share/OVMF/OVMF_VARS_4M.fd"; exit 1; }

    print_info "Copying system OVMF files to local output directory"
    cp -f "/usr/share/OVMF/OVMF_CODE_4M.fd" "$ovmf_code_local"
    cp -f "/usr/share/OVMF/OVMF_VARS_4M.fd" "$ovmf_vars_local"

    print_info "Creating VM image: $vm_img ($vm_size)"
    qemu-img create -f qcow2 "$vm_img" "$vm_size" >/dev/null
    print_success "VM image created"

    start_tpm_service "$vm_name" "$tpm_runtime_dir" "$tpm_socket_file" "$swtpm_pid_file"
    trap 'cleanup_tpm_service "$swtpm_pid_file"' EXIT

    ovmf_args=(
        -drive "file=${ovmf_code_local},format=raw,if=pflash,unit=0,readonly=on"
        -drive "file=${ovmf_vars_local},format=raw,if=pflash,unit=1"
    )

    tpm_args=(
        -chardev "socket,id=chrtpm,path=${tpm_socket_file}"
        -tpmdev "emulator,id=tpm0,chardev=chrtpm"
        -device "tpm-crb,tpmdev=tpm0"
    )

    qmp_args=()
    if [[ "$auto_press_boot_key_enabled" == "true" ]]; then
        rm -f "$qmp_socket"
        qmp_args=(
            -qmp "unix:${qmp_socket},server=on,wait=off"
        )
    fi

    qemu_cmd=(
        qemu-system-x86_64 -k en-us
        -enable-kvm
        -name "$vm_name"
        -m "$vm_memory"
        -smp cores="${vcpus},threads=2,sockets=1"
        -cpu host
        -machine "q35"
        "${qmp_args[@]}"
        "${ovmf_args[@]}"
        -drive "file=${vm_img},format=qcow2,if=none,id=vdisk,cache=none"
        -drive "file=${iso_path},media=cdrom,if=none,id=cd0,readonly=on"
        -device "ich9-ahci,id=sata"
        -device "ide-hd,drive=vdisk,bus=sata.1,bootindex=1"
        -device "ide-cd,drive=cd0,bus=sata.0,bootindex=2"
        -boot "order=c,once=d,menu=on"
        "${tpm_args[@]}"
        -display "gtk,gl=on"
        -device "virtio-vga"
        -netdev "user,id=net0,restrict=on"
        -device "e1000,netdev=net0"
        -rtc "base=localtime"
        -usb
        -device "usb-tablet"
    )

    echo -e "${BLUE}QEMU command:${NC}"
    echo "${qemu_cmd[*]}"

    if [[ "$auto_press_boot_key_enabled" == "true" ]]; then
        auto_press_boot_key "$qmp_socket" &
    fi

    "${qemu_cmd[@]}"

    echo
    print_success "Windows VM creation completed"
    echo -e "${BLUE}[INFO ]${NC} VM image output directory : ${output_dir}"
    echo -e "${BLUE}[INFO ]${NC} To launch the VM, run launch-vm.sh with the config file, for example:"
    echo -e "${BLUE}[INFO ]${NC}   scripts/launch-vm.sh -d 1 -c config/vm-config/bmg-idv-config.xml"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
