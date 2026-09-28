#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.
#
# Delete VM Script
#
# Description:
#   Removes a VM entry from the master XML config and deletes its disk image
#   (and any OVMF sidecar files created by launch-vm.sh alongside the disk).
#
# Usage:
#   ./delete-vm.sh -c <config.xml> -d <vm-id> [options]
#   ./delete-vm.sh -c <config.xml> -n <vm-name> [options]
#
#   -c, --config FILE     VM XML configuration file (required)
#   -d, --vm-id ID        ID of the VM to delete (as used in launch-vm.sh -d)
#   -n, --vm-name NAME    Name of the VM to delete (alternative to -d)
#       --keep-disk       Remove the XML entry only; leave disk image on disk
#       --force           Skip the confirmation prompt
#       --dry-run         Show what would be deleted without making any changes
#   -h, --help            Show this help message
#
# Author: Intel Graphics SRIOV Team

################################################################################
# Configuration
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_MANAGER="${SCRIPT_DIR}/vm-config-manager.sh"

# shellcheck disable=SC1090
source "$CONFIG_MANAGER" || { echo "Cannot source vm-config-manager.sh" >&2; exit 1; }

readonly BOLD='\033[1m'

################################################################################
# Helper Functions
################################################################################

print_error() { echo -e "${RED}✗ Error: ${1}${NC}" >&2; }
print_success() { echo -e "${GREEN}✓ ${1}${NC}" >&2; }
print_warn() { echo -e "${YELLOW}⚠ ${1}${NC}" >&2; }
print_info() { echo -e "${BLUE}ℹ ${1}${NC}" >&2; }

show_help() {
    echo -e "${BLUE}=== VM Deletion Help ===${NC}\n"
    echo "Usage: $0 -c <config.xml> -d <vm-id>   [options]"
    echo "       $0 -c <config.xml> -n <vm-name> [options]"
    echo
    echo "Options:"
    echo "  -c, --config FILE     VM XML configuration file (required)"
    echo "  -d, --vm-id ID        ID of the VM to delete (matches launch-vm.sh -d)"
    echo "  -n, --vm-name NAME    Name of the VM to delete (alternative to -d)"
    echo "      --keep-disk       Remove XML entry only; leave disk image on disk"
    echo "      --force           Skip the confirmation prompt"
    echo "      --dry-run         Show what would be deleted without making any changes"
    echo "  -h, --help            Show this help message"
    echo
    echo "Examples:"
    echo "  $0 -c config/vm-config/vm-master-config.xml -d 1"
    echo "  $0 -c config/vm-config/vm-master-config.xml  -d 3 --dry-run"
    echo "  $0 -c config/vm-config/vm-master-config.xml -n win1 --force"
    echo "  $0 -c config/vm-config/vm-master-config.xml -d 2 --keep-disk"
    echo
}

################################################################################
# Script-specific helpers
################################################################################

# Resolve VM name from numeric ID.
resolve_vm_name_from_id() {
    local vm_id="$1"
    local config="$2"
    get_vm_field_by_id "name" "$vm_id" "$config"
}

################################################################################
# Running-VM detection
################################################################################

vm_is_running() {
    local vm_name="$1"
    local pid_file="$2"

    # Check the QEMU pidfile written by -pidfile in launch-vm.sh.
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(tr -d '[:space:]' < "$pid_file" 2>/dev/null)
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi

    # Fallback: search for a running qemu process with this VM name.
    if pgrep -f "qemu-system.*-name[[:space:]]+${vm_name}([[:space:]]|$)" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

################################################################################
# Disk cleanup
################################################################################

# Check if a file is a system OVMF file (should not be deleted)
is_system_ovmf_file() {
    local f="$1"
    [[ "$f" == /usr/share/OVMF/* ]]
}

# List all files associated with a disk path that should be removed.
# Includes the disk itself and OVMF sidecar files created by launch-vm.sh.
list_disk_files() {
    local disk_path="$1"
    local disk_base="${disk_path%.*}"
    local candidates=(
        "$disk_path"
        "${disk_base}_OVMF.fd"
        "${disk_base}_OVMF_CODE_4M.fd"
        "${disk_base}_OVMF_VARS_4M.fd"
    )

    local found=()
    local f
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && found+=("$f")
    done

    [[ ${#found[@]} -gt 0 ]] && printf '%s\n' "${found[@]}"
}

delete_disk_files() {
    local disk_path="$1"
    local dry_run="$2"
    local all_ok=0

    local files
    mapfile -t files < <(list_disk_files "$disk_path")

    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "No disk files found at or alongside: $disk_path"
        return 0
    fi

    local f size
    for f in "${files[@]}"; do
        # Skip system OVMF files (in /usr/share/OVMF) — they shouldn't be deleted
        if is_system_ovmf_file "$f"; then
            continue
        fi

        size=$(du -h "$f" 2>/dev/null | cut -f1)
        if [[ "$dry_run" == "true" ]]; then
            print_info "[dry-run] Would delete: $f ($size)"
        else
            if rm -f "$f"; then
                print_success "Deleted: $f ($size)"
            else
                print_error "Failed to delete: $f"
                all_ok=1
            fi
        fi
    done

    return $all_ok
}

################################################################################
# Argument Parsing
################################################################################

parse_arguments() {
    CONFIG_FILE=""
    VM_NAME=""
    VM_ID=""
    KEEP_DISK=false
    FORCE=false
    DRY_RUN=false
    SHOW_HELP=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="$2"; shift 2 ;;
            -d|--vm-id)
                VM_ID="$2"; shift 2 ;;
            -n|--vm-name)
                VM_NAME="$2"; shift 2 ;;
            --keep-disk)
                KEEP_DISK=true; shift ;;
            --force)
                FORCE=true; shift ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            -h|--help)
                SHOW_HELP=true; shift ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1 ;;
        esac
    done
}

################################################################################
# Main
################################################################################

main() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run with sudo"
        exit 1
    fi

    if [[ "$SHOW_HELP" == true ]]; then
        show_help; exit 0
    fi

    if [[ -z "$CONFIG_FILE" ]]; then
        print_error "--config is required"
        show_help; exit 1
    fi

    if [[ -z "$VM_ID" && -z "$VM_NAME" ]]; then
        print_error "Either --vm-id (-d) or --vm-name (-n) is required"
        show_help; exit 1
    fi

    if [[ -n "$VM_ID" && -n "$VM_NAME" ]]; then
        print_error "Specify either --vm-id or --vm-name, not both"
        show_help; exit 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    if [[ ! -f "$CONFIG_MANAGER" ]]; then
        print_error "vm-config-manager.sh not found: $CONFIG_MANAGER"
        exit 1
    fi

    # Resolve VM name from ID if -d was used
    if [[ -n "$VM_ID" ]]; then
        if [[ ! "$VM_ID" =~ ^[0-9]+$ ]]; then
            print_error "VM ID must be a positive integer, got: $VM_ID"
            exit 1
        fi
        VM_NAME=$(resolve_vm_name_from_id "$VM_ID" "$CONFIG_FILE")
        if [[ -z "$VM_NAME" ]]; then
            print_error "No VM with ID ${VM_ID} found in: $CONFIG_FILE"
            exit 1
        fi
        print_info "Resolved VM ID ${VM_ID} -> name '${VM_NAME}'"
    fi

    # Fetch VM details
    local disk_path os_type pid_file
    disk_path=$(get_vm_field_by_name "disk_path" "$VM_NAME" "$CONFIG_FILE")
    os_type=$(get_vm_field_by_name "os_type"   "$VM_NAME" "$CONFIG_FILE")
    pid_file=$(get_vm_field_by_name "vm_pid"   "$VM_NAME" "$CONFIG_FILE")

    if [[ -z "$disk_path" ]]; then
        print_error "VM '${VM_NAME}' not found in: $CONFIG_FILE"
        exit 1
    fi

    # Refuse to delete a running VM
    if vm_is_running "$VM_NAME" "$pid_file"; then
        print_error "VM '${VM_NAME}' appears to be running (pidfile: ${pid_file})"
        print_info "Stop the VM before deleting it."
        exit 1
    fi

    # Collect the files that will be removed
    local disk_files=()
    local system_ovmf_files=()
    if [[ "$KEEP_DISK" == false ]]; then
        local all_files
        mapfile -t all_files < <(list_disk_files "$disk_path")
        for f in "${all_files[@]}"; do
            if is_system_ovmf_file "$f"; then
                system_ovmf_files+=("$f")
            else
                disk_files+=("$f")
            fi
        done
    fi

    # Print deletion summary
    echo
    echo -e "${BOLD}Deletion summary for VM '${VM_NAME}'${NC}"
    echo -e "  Config file : ${CONFIG_FILE}"
    echo -e "  OS type     : ${os_type:-unknown}"
    echo -e "  Disk path   : ${disk_path}"
    echo

    if [[ "$KEEP_DISK" == false ]]; then
        if [[ ${#disk_files[@]} -gt 0 ]]; then
            echo -e "  ${BOLD}Files to delete:${NC}"
            local f size
            for f in "${disk_files[@]}"; do
                size=$(du -h "$f" 2>/dev/null | cut -f1)
                echo -e "    - $f  ($size)"
            done
        else
            echo -e "    (no disk files to remove)"
        fi
        if [[ ${#system_ovmf_files[@]} -gt 0 ]]; then
            echo -e "  ${BOLD}System OVMF files (will NOT be deleted):${NC}"
            for f in "${system_ovmf_files[@]}"; do
                echo -e "    - $f"
            done
        fi
    else
        echo -e "  Disk files  : kept (--keep-disk)"
    fi
    echo

    if [[ "$DRY_RUN" == true ]]; then
        print_info "[dry-run] XML entry for '${VM_NAME}' would be removed from: $CONFIG_FILE"
        if [[ "$KEEP_DISK" == false && ${#disk_files[@]} -gt 0 ]]; then
            delete_disk_files "$disk_path" "true"
        fi
        echo
        print_info "Dry run complete — no changes made."
        exit 0
    fi

    # Confirmation prompt
    if [[ "$FORCE" == false ]]; then
        echo -e "${YELLOW}This will permanently delete the VM and its disk image.${NC}"
        echo -n "Type the VM name to confirm deletion [${VM_NAME}]: "
        local answer
        read -r answer
        if [[ "$answer" != "$VM_NAME" ]]; then
            print_warn "Confirmation did not match. Aborting."
            exit 1
        fi
        echo
    fi

    # Delete disk files first (so the XML entry is only removed on success)
    if [[ "$KEEP_DISK" == false ]]; then
        if ! delete_disk_files "$disk_path" "false"; then
            print_error "One or more disk files could not be deleted. XML entry was NOT removed."
            exit 1
        fi
    fi

    # Delegate XML entry removal to vm-config-manager.sh.
    if remove_vm_from_config "$VM_NAME"; then
        echo
        print_success "VM '${VM_NAME}' deleted successfully."
    else
        print_error "Failed to remove VM entry from config."
        exit 1
    fi
}

for arg in "$@"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
        show_help; exit 0
    fi
done

parse_arguments "$@"
main
