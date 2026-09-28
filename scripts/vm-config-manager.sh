#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# VM Configuration Manager - utilities to manage VM config XML entries
# This script provides functions to add, update, and remove VM entries from the configuration XML

################################################################################
# Configuration
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/config/vm-config/vm-master-config.xml}"
TEMPLATE_FILE="${TEMPLATE_FILE:-$REPO_ROOT/config/vm-config/vm-master-config.xml.template}"
VM_IMAGE_DIR="${VM_IMAGE_DIR:-/data/vm-images}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get a specific field value from a VM by its numeric ID
get_vm_field_by_id() {
    local field="$1"
    local vm_id="$2"
    local config="$3"

    [[ ! -f "$config" ]] && return 1
    grep -A 100 "id=\"${vm_id}\"" "$config" | grep -m 1 "<${field}>" | grep -oP "(?<=<${field}>)[^<]+"
}

# Get a specific field value from a VM by its name
get_vm_field_by_name() {
    local field="$1"
    local vm_name="$2"
    local config="$3"

    [[ ! -f "$config" ]] && return 1
    grep -A 100 "<name>${vm_name}</name>" "$config" | grep -m 1 "<${field}>" | grep -oP "(?<=<${field}>)[^<]+"
}

################################################################################
# Helper Functions
################################################################################

print_error() {
    echo -e "${RED}✗ Error: ${1}${NC}" >&2
}

print_success() {
    echo -e "${GREEN}✓ ${1}${NC}" >&2
}

print_warn() {
    echo -e "${YELLOW}⚠ ${1}${NC}" >&2
}

print_info() {
    echo -e "${BLUE}ℹ ${1}${NC}" >&2
}

# Force every mv in this script so GNU mv's interactive overwrite prompt (e.g.
# if $CONFIG_FILE is ever owned by another user) can't hang a non-interactive run.
mv() { command mv -f "$@"; }

################################################################################
# XML Parsing and Validation
################################################################################

# Return the lowest integer >= start_value that is not present in the given
# newline-separated list of used values. Values are treated as integers.
first_free_integer() {
    local start_value="$1"
    local used_values="$2"

    local candidate=$start_value
    local sorted_used
    sorted_used=$(printf '%s\n' "$used_values" | grep -E '^[0-9]+$' | sort -n -u)

    while IFS= read -r used; do
        [[ -z "$used" ]] && continue
        if (( used < candidate )); then
            continue
        elif (( used == candidate )); then
            candidate=$((candidate + 1))
        else
            break
        fi
    done <<< "$sorted_used"

    echo "$candidate"
}

# Find the next available VM ID (reuses gaps from deleted VMs)
get_next_vm_id() {
    ensure_config_exists

    local used_ids
    used_ids=$(grep -oP 'id="\K[0-9]+(?=")' "$CONFIG_FILE")

    first_free_integer 1 "$used_ids"
}

# Find the next available SSH port (reuses gaps from deleted VMs)
get_next_ssh_port() {
    ensure_config_exists

    local used_ports
    # Check both port types to prevent ssh/monitor collisions
    used_ports=$(grep -oP '<ssh_port>\K[0-9]+(?=</ssh_port>)|<monitor_port>\K[0-9]+(?=</monitor_port>)' "$CONFIG_FILE")

    first_free_integer 1101 "$used_ports"
}

# Find the next available monitor port (reuses gaps from deleted VMs)
get_next_monitor_port() {
    ensure_config_exists

    local used_ports
    # Check both port types to prevent ssh/monitor collisions
    used_ports=$(grep -oP '<ssh_port>\K[0-9]+(?=</ssh_port>)|<monitor_port>\K[0-9]+(?=</monitor_port>)' "$CONFIG_FILE")

    # Exclude the value get_next_ssh_port would return to prevent same-VM collision
    local next_ssh
    next_ssh=$(first_free_integer 1101 "$used_ports")
    used_ports+=$'\n'"$next_ssh"

    first_free_integer 1111 "$used_ports"
}

# Generate a unique MAC address based on VM ID and host hash
generate_mac_address() {
    local vm_id="$1"
    local host_hash

    # Use hostname to generate a stable part of the MAC
    host_hash=$(echo -n "$(hostname)" | md5sum | cut -c1-2)

    printf "EE:DD:BB:%s:AA:%02X" "$host_hash" "$vm_id"
}

# Check if VM name already exists
vm_name_exists() {
    local vm_name="$1"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi

    grep -q "<name>${vm_name}</name>" "$CONFIG_FILE"
}

# Check if MAC address already exists
mac_address_exists() {
    local mac_address="$1"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi

    grep -q "<mac_address>${mac_address}</mac_address>" "$CONFIG_FILE"
}

################################################################################
# XML Entry Creation
################################################################################

# Create a VM entry XML block
create_vm_entry() {
    local vm_id="$1"
    local vm_name="$2"
    local os_type="$3"
    local memory_size="$4"
    local cpu_cores="$5"
    local cpu_threads="${6:-2}"
    local mac_address="$7"
    local disk_path="$8"
    local ssh_port="$9"
    local monitor_port="${10}"
    local description="${11:-Virtual Machine}"

    cat << EOF
        <vm id="$vm_id">
            <name>$vm_name</name>
            <os_type>$os_type</os_type>
            <memory_size>$memory_size</memory_size>
            <cpu_cores>$cpu_cores</cpu_cores>
            <cpu_threads>$cpu_threads</cpu_threads>
            <mac_address>$mac_address</mac_address>
            <disk_path>$disk_path</disk_path>
            <ssh_port>$ssh_port</ssh_port>
            <monitor_port>$monitor_port</monitor_port>
            <vm_pid>vm_pid${vm_id}</vm_pid>
            <description>$description</description>
        </vm>
EOF
}

################################################################################
# XML File Operations
################################################################################

# Write a fresh master XML skeleton — either by cloning the static sections of
# the template (metadata, display_configurations) or falling back to a built-in
# minimal skeleton. Any <vm> entries in the template are treated as SAMPLES and
# discarded so the runtime file starts empty. This is the source-of-truth
# guarantee: nothing enters <virtual_machines> unless the toolkit puts it there.
write_master_skeleton() {
    mkdir -p "$(dirname "$CONFIG_FILE")"

    if [[ -f "$TEMPLATE_FILE" ]]; then
        local temp_file
        temp_file=$(mktemp)
        # Strip all <vm ...>...</vm> blocks from the template so sample entries
        # never leak into the runtime config. Handle formatters that put line breaks
        # after opening tags.
        if awk '
            /<vm[ >]|^[ \t]*<vm[ \t]*$/ { skip=1 }
            skip == 0 { print }
            /<\/vm>/ { skip=0 }
        ' "$TEMPLATE_FILE" > "$temp_file" && [[ -s "$temp_file" ]]; then
            mv "$temp_file" "$CONFIG_FILE"
            chmod 644 "$CONFIG_FILE"
            print_info "Wrote master skeleton from template (sample VMs stripped)"
            return 0
        fi
        rm -f "$temp_file"
        print_warn "Failed to process template; falling back to built-in skeleton"
    fi

    cat > "$CONFIG_FILE" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 Intel Corporation -->
<!-- All rights reserved. -->
<vm_configuration>
    <metadata>
        <version>1.5</version>
        <description>Virtual Machine Configuration</description>
    </metadata>

    <virtual_machines>
    </virtual_machines>

    <display_configurations>
        <mode name="idv">
            <fullscreen>off</fullscreen>
            <show_fps>on</show_fps>
            <max_outputs>1</max_outputs>
            <blob>true</blob>
            <!-- render_sync: QEMU 9 and below only; ignored on QEMU 10+ -->
            <render_sync>false</render_sync>
            <!-- hw_cursor: QEMU 9 and below only; ignored on QEMU 10+ -->
            <hw_cursor>on</hw_cursor>
            <input>on</input>
        </mode>
    </display_configurations>
</vm_configuration>
EOF
    chmod 644 "$CONFIG_FILE"
    print_info "Wrote master skeleton (built-in, no template found)"
}

# Discover libvirt-managed domains and emit one add_vm_to_config call per VM.
# Silent if virsh is not installed or the user has no permissions.
discover_libvirt_vms() {
    command -v virsh >/dev/null 2>&1 || return 0

    local names
    names=$(virsh list --all --name 2>/dev/null | grep -v '^$') || return 0
    [[ -z "$names" ]] && return 0

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if vm_name_exists "$name"; then
            continue
        fi

        local xml mac disk memory_kib memory_mb cores os_type
        xml=$(virsh dumpxml "$name" 2>/dev/null) || continue

        mac=$(printf '%s' "$xml" | grep -oP "<mac address='\K[^']+" | head -1)
        disk=$(printf '%s' "$xml" | grep -oP "<source file='\K[^']+" | head -1)
        memory_kib=$(printf '%s' "$xml" | grep -oP "<memory[^>]*>\K[0-9]+" | head -1)
        cores=$(printf '%s' "$xml" | grep -oP "<vcpu[^>]*>\K[0-9]+" | head -1)

        memory_mb=$(( ${memory_kib:-0} / 1024 ))
        [[ -z "$mac" ]] && mac=$(generate_mac_address "$(get_next_vm_id)")
        [[ -z "$disk" ]] && disk="unknown"
        [[ -z "$cores" ]] && cores="1"
        [[ $memory_mb -eq 0 ]] && memory_mb="1024"

        if printf '%s' "$xml" | grep -qi 'windows\|win10\|win11'; then
            os_type="windows"
        else
            os_type="ubuntu"
        fi

        local vm_id ssh_port monitor_port
        vm_id=$(get_next_vm_id)
        ssh_port=$(get_next_ssh_port)
        monitor_port=$(get_next_monitor_port)

        add_vm_to_config "$vm_id" "$name" "$os_type" "$memory_mb" "$cores" "2" \
                         "$mac" "$disk" "$ssh_port" "$monitor_port" \
                         "Discovered via libvirt"
    done <<< "$names"
}

# Discover existing VM disk images in the configured image directory and add
# them to the runtime config even when no VM is currently running.
discover_vm_images() {
    [[ -d "$VM_IMAGE_DIR" ]] || return 0

    local image_path
    while IFS= read -r image_path; do
        [[ -z "$image_path" ]] && continue

        local image_name base_name name os_type vm_id ssh_port monitor_port mac
        image_name=$(basename "$image_path")
        base_name="${image_name%.*}"
        name="${base_name//[^A-Za-z0-9_.-]/_}"

        case "$image_name" in
            *.iso) continue ;;
            *.ISO) continue ;;
        esac

        [[ -z "$name" ]] && continue
        if vm_name_exists "$name"; then
            continue
        fi

        case "$name" in
            *ubuntu*|*Ubuntu*) os_type="ubuntu" ;;
            *win*|*Windows*) os_type="windows" ;;
            *) os_type="ubuntu" ;;
        esac

        vm_id=$(get_next_vm_id)
        ssh_port=$(get_next_ssh_port)
        monitor_port=$(get_next_monitor_port)
        mac=$(generate_mac_address "$vm_id")

        add_vm_to_config "$vm_id" "$name" "$os_type" "8192" "4" "2" \
                         "$mac" "$image_path" "$ssh_port" "$monitor_port" \
                         "Discovered from $VM_IMAGE_DIR"
    done < <(find "$VM_IMAGE_DIR" -maxdepth 1 -type f \( -iname '*.img' -o -iname '*.qcow2' -o -iname '*.qcow' -o -iname '*.raw' \) 2>/dev/null | sort)
}

# Discover running QEMU processes started outside libvirt and register them.
# Parses -netdev hostfwd=tcp::PORT-:22 for the SSH port when present.
discover_qemu_processes() {
    command -v pgrep >/dev/null 2>&1 || return 0

    local pids
    pids=$(pgrep -a qemu-system 2>/dev/null | awk '{print $1}') || return 0
    [[ -z "$pids" ]] && return 0

    local pid
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        local cmdline name mac disk ssh_port
        cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null) || continue

        name=$(printf '%s' "$cmdline" | grep -oP '(?<=-name )\S+' | head -1)
        name="${name:-qemu-pid-${pid}}"

        if vm_name_exists "$name"; then
            continue
        fi

        mac=$(printf '%s' "$cmdline" | grep -oP 'mac=\K[0-9A-Fa-f:]+' | head -1)
        disk=$(printf '%s' "$cmdline" | grep -oP '(?<=-drive file=)[^,\s]+' | head -1)
        ssh_port=$(printf '%s' "$cmdline" | grep -oP 'hostfwd=tcp::\K[0-9]+(?=-:22)' | head -1)

        local vm_id monitor_port
        vm_id=$(get_next_vm_id)
        monitor_port=$(get_next_monitor_port)
        [[ -z "$ssh_port" ]] && ssh_port=$(get_next_ssh_port)
        [[ -z "$mac" ]] && mac=$(generate_mac_address "$vm_id")
        [[ -z "$disk" ]] && disk="unknown"

        add_vm_to_config "$vm_id" "$name" "ubuntu" "1024" "1" "2" \
                         "$mac" "$disk" "$ssh_port" "$monitor_port" \
                         "Discovered via qemu-system process"
    done <<< "$pids"
}

# Build the runtime master config from scratch. Safe to call more than once —
# the second call is a no-op unless FORCE=1 is set.
init_master_config() {
    local force="${1:-}"

    if [[ -f "$CONFIG_FILE" && "$force" != "--force" ]]; then
        print_info "Config already exists: $CONFIG_FILE (use --force to rebuild)"
        return 0
    fi

    if [[ "$force" == "--force" ]]; then
        rm -f "$CONFIG_FILE"
    fi

    write_master_skeleton
    discover_vm_images
    discover_libvirt_vms
    discover_qemu_processes

    print_success "Master config ready: $CONFIG_FILE"
}

# Guard called from every read/write path — creates the runtime config on
# first use so callers never see sample data.
ensure_config_exists() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        init_master_config
    fi
}

# Legacy name kept for callers that source this file and invoke it directly.
initialize_config_file() {
    ensure_config_exists
}

# Add a VM entry to the config file
add_vm_to_config() {
    local vm_id="$1"
    local vm_name="$2"
    local os_type="$3"
    local memory_size="$4"
    local cpu_cores="$5"
    local cpu_threads="${6:-2}"
    local mac_address="$7"
    local disk_path="$8"
    local ssh_port="$9"
    local monitor_port="${10}"
    local description="${11:-Virtual Machine}"

    # Validate inputs
    if [[ -z "$vm_id" || -z "$vm_name" || -z "$os_type" || -z "$disk_path" || -z "$ssh_port" || -z "$monitor_port" ]]; then
        print_error "Missing required parameters for add_vm_to_config"
        return 1
    fi

    # Ensure config file exists before any checks
    ensure_config_exists

    # Check for duplicates
    if vm_name_exists "$vm_name"; then
        print_warn "VM name already exists in config: $vm_name"
        return 1
    fi

    if mac_address_exists "$mac_address"; then
        print_warn "MAC address already exists in config: $mac_address"
        return 1
    fi

    if grep -q "id=\"${vm_id}\"" "$CONFIG_FILE" 2>/dev/null; then
        print_warn "VM ID already exists in config: $vm_id"
        return 1
    fi

    # Create VM entry and temporary files
    local temp_file
    temp_file=$(mktemp)

    local vm_entry
    vm_entry=$(create_vm_entry "$vm_id" "$vm_name" "$os_type" "$memory_size" "$cpu_cores" \
                              "$cpu_threads" "$mac_address" "$disk_path" "$ssh_port" \
                              "$monitor_port" "$description")

    # Insert VM entry before closing </virtual_machines> tag using awk
    if awk -v entry="$vm_entry" '/<\/virtual_machines>/ { print entry } { print }' "$CONFIG_FILE" > "$temp_file" && [[ -s "$temp_file" ]]; then
        mv "$temp_file" "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        print_success "VM added to config: $vm_name (ID: $vm_id)"
        return 0
    else
        rm -f "$temp_file"
        print_error "Failed to add VM to config"
        return 1
    fi
}

# Remove a VM entry from the config file
remove_vm_from_config() {
    local vm_name="$1"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_warn "Config file not found: $CONFIG_FILE"
        return 1
    fi

    if ! vm_name_exists "$vm_name"; then
        print_warn "VM not found in config: $vm_name"
        return 1
    fi

    # Create temporary file
    local temp_file
    temp_file=$(mktemp)

    # Remove VM block using awk, consistent with the rest of this file
    if awk -v target="$vm_name" '
    /<vm[ >]|^[ \t]*<vm[ \t]*$/ { in_vm = 1; vl[++vc] = $0; next }
    in_vm {
        vl[++vc] = $0
        if (index($0, "<name>" target "</name>") > 0) found = 1
        if (index($0, "</vm>") > 0) {
            if (!found) { for (i = 1; i <= vc; i++) print vl[i] }
            in_vm = 0; found = 0; vc = 0; delete vl
        }
        next
    }
    { print }
    ' "$CONFIG_FILE" > "$temp_file" && [[ -s "$temp_file" ]]; then
        mv "$temp_file" "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        if ! vm_name_exists "$vm_name"; then
            print_success "VM removed from config: $vm_name"
            return 0
        fi
        print_error "Failed to remove VM from config"
        return 1
    else
        rm -f "$temp_file"
        print_error "Failed to remove VM from config"
        return 1
    fi
}

# Update one or more fields of an existing VM entry
# Usage: update_vm_in_config <vm_name> field=value [field=value ...]
# Supported fields: name, os_type, memory, cpu_cores, cpu_threads,
#                   mac_address, disk_path, ssh_port, monitor_port, description
update_vm_in_config() {
    local vm_name="$1"
    shift

    if [[ $# -eq 0 ]]; then
        print_error "No fields specified. Usage: update-vm <name> field=value [field=value ...]"
        return 1
    fi

    ensure_config_exists

    if ! vm_name_exists "$vm_name"; then
        print_warn "VM not found in config: $vm_name"
        return 1
    fi

    # Map CLI aliases to XML tag names
    declare -A field_map=(
        [name]="name"               [os_type]="os_type"         [os]="os_type"
        [memory]="memory_size"      [memory_size]="memory_size"
        [cpu_cores]="cpu_cores"     [cores]="cpu_cores"
        [cpu_threads]="cpu_threads" [threads]="cpu_threads"
        [mac]="mac_address"         [mac_address]="mac_address"
        [disk]="disk_path"          [disk_path]="disk_path"
        [ssh_port]="ssh_port"       [ssh]="ssh_port"
        [monitor_port]="monitor_port" [monitor]="monitor_port"
        [description]="description" [desc]="description"
    )

    # Validate pairs and build a SOH-delimited update string for awk
    local awk_updates=""
    for arg in "$@"; do
        local field="${arg%%=*}"
        local value="${arg#*=}"
        local xml_tag="${field_map[$field]:-}"

        if [[ -z "$xml_tag" ]]; then
            print_error "Unknown field: '$field'"
            print_info "Valid fields: name, os_type, memory, cpu_cores, cpu_threads, mac_address, disk_path, ssh_port, monitor_port, description"
            return 1
        fi

        if [[ "$xml_tag" == "name" && "$value" != "$vm_name" ]] && vm_name_exists "$value"; then
            print_error "VM name already in use: $value"
            return 1
        fi
        if [[ "$xml_tag" == "mac_address" ]]; then
            local current_mac
            current_mac=$(get_vm_field_by_name "mac_address" "$vm_name" "$CONFIG_FILE")
            if [[ "$value" != "$current_mac" ]] && mac_address_exists "$value"; then
                print_error "MAC address already in use: $value"
                return 1
            fi
        fi

        awk_updates+=$'\x01'"${xml_tag}=${value}"
    done
    awk_updates="${awk_updates#$'\x01'}"  # strip leading SOH

    local temp_file awk_status
    temp_file=$(mktemp)

    awk -v target="$vm_name" -v upd="$awk_updates" '
    BEGIN {
        n = split(upd, pairs, "\001")
        for (i = 1; i <= n; i++) {
            eq = index(pairs[i], "=")
            tag = substr(pairs[i], 1, eq - 1)
            val = substr(pairs[i], eq + 1)
            gsub(/&/, "\\&", val)
            umap[tag] = val
        }
        in_vm = 0; vc = 0; found = 0
    }
    /<vm[ >]|^[ \t]*<vm[ \t]*$/ { in_vm = 1; vl[++vc] = $0; next }
    in_vm {
        vl[++vc] = $0
        if (index($0, "<name>" target "</name>") > 0) found = 1
        if (index($0, "</vm>") > 0) {
            for (i = 1; i <= vc; i++) {
                line = vl[i]
                if (found) {
                    for (tag in umap) {
                        if (index(line, "<" tag ">") > 0)
                            sub("<" tag ">[^<]*</" tag ">", "<" tag ">" umap[tag] "</" tag ">", line)
                    }
                }
                print line
            }
            in_vm = 0; found = 0; vc = 0; delete vl
        }
        next
    }
    { print }
    ' "$CONFIG_FILE" > "$temp_file"; awk_status=$?

    if [[ $awk_status -eq 0 ]] && [[ -s "$temp_file" ]]; then
        mv "$temp_file" "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        print_success "VM updated: $vm_name"
        return 0
    else
        rm -f "$temp_file"
        print_error "Failed to update VM in config"
        return 1
    fi
}

# List all VMs in config
list_vms_in_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_warn "Config file not found: $CONFIG_FILE"
        return 1
    fi

    print_info "VMs in config:"
    echo

    # Extract VM blocks and format them
    local vm_block=""
    local in_vm=false

    while IFS= read -r line; do
        if [[ $line =~ \<vm\ id= ]]; then
            in_vm=true
            vm_block="$line"
        elif [[ $line =~ \</vm\> ]] && [[ "$in_vm" == true ]]; then
            vm_block+=$'\n'"$line"
            in_vm=false

            # Extract fields from the complete VM block
            local id name os ssh monitor disk
            id=$(echo "$vm_block" | grep -oP 'id="\K[0-9]+(?=")' | head -1)
            name=$(echo "$vm_block" | grep -oP '<name>\K[^<]+(?=</name>)')
            os=$(echo "$vm_block" | grep -oP '<os_type>\K[^<]+(?=</os_type>)')
            ssh=$(echo "$vm_block" | grep -oP '<ssh_port>\K[^<]+(?=</ssh_port>)')
            monitor=$(echo "$vm_block" | grep -oP '<monitor_port>\K[^<]+(?=</monitor_port>)')
            disk=$(echo "$vm_block" | grep -oP '<disk_path>\K[^<]+(?=</disk_path>)')

            # Print formatted output
            printf "ID: %-2s | Name: %-15s | OS: %-10s | SSH: %-5s | Monitor: %-5s\n" \
                "$id" "$name" "$os" "$ssh" "$monitor"
            printf "         Path: %s\n" "$disk"
            printf "\n"
        elif [[ "$in_vm" == true ]]; then
            vm_block+=$'\n'"$line"
        fi
    done < "$CONFIG_FILE"
}

################################################################################
# Main Function
################################################################################

main() {
    case "${1:-}" in
        add-vm)
            shift
            add_vm_to_config "$@"
            ;;
        remove-vm)
            shift
            remove_vm_from_config "$@"
            ;;
        update-vm)
            shift
            update_vm_in_config "$@"
            ;;
        list-vms)
            list_vms_in_config
            ;;
        next-vm-id)
            get_next_vm_id
            ;;
        next-ssh-port)
            get_next_ssh_port
            ;;
        next-monitor-port)
            get_next_monitor_port
            ;;
        generate-mac)
            generate_mac_address "$2"
            ;;
        init-config)
            shift
            init_master_config "$@"
            ;;
        *)
            echo "VM Configuration Manager"
            echo "Usage: $0 <command> [options]"
            echo
            echo "Commands:"
            echo "  init-config [--force]   Build master config from template + host discovery"
            echo "  add-vm <id> <name> <os> <memory> <cores> <threads> <mac> <disk> <ssh_port> <monitor_port> [description]"
            echo "  update-vm <vm_name> field=value [field=value ...]"
            echo "            Fields: name, os_type, memory, cpu_cores, cpu_threads,"
            echo "                    mac_address, disk_path, ssh_port, monitor_port, description"
            echo "  remove-vm <vm_name>"
            echo "  list-vms"
            echo "  next-vm-id              Get next available VM ID"
            echo "  next-ssh-port           Get next available SSH port"
            echo "  next-monitor-port       Get next available monitor port"
            echo "  generate-mac <vm_id>    Generate MAC address for VM ID"
            ;;
    esac
}

# Export functions for sourcing
export -f add_vm_to_config
export -f update_vm_in_config
export -f remove_vm_from_config
export -f list_vms_in_config
export -f first_free_integer
export -f get_next_vm_id
export -f get_next_ssh_port
export -f get_next_monitor_port
export -f generate_mac_address
export -f vm_name_exists
export -f mac_address_exists
export -f get_vm_field_by_id
export -f get_vm_field_by_name
export -f write_master_skeleton
export -f discover_libvirt_vms
export -f discover_vm_images
export -f discover_qemu_processes
export -f init_master_config
export -f ensure_config_exists
export -f initialize_config_file
export -f print_error print_success print_warn print_info

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
