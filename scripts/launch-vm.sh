#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.
# Version: 1.2
#
# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
HUGEPAGE_SIZE_MB=2

ORIGINAL_HUGEPAGES=""
APPLIED_HUGEPAGES=""
HUGEPAGES_UPDATED="false"

# Print usage help
show_help() {
    echo -e "${BLUE}=== Windows IDV Launcher Help ===${NC}\n"
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help                 Show this help message"
    echo "  -c, --config FILE          VM XML configuration file (required)"
    echo "  -n, --num-vms NUM          Launch only NUM VMs (default: all)"
    echo "  -d, --vm-id ID             Launch only VM with specified ID"
    echo "      --network MODE         Network mode: 'localhost' (default) or 'dynamic'"
    echo
    echo "Examples:"
    echo "  $0 -c vm_config.xml                       # Launch all VMs"
    echo "  $0 -c vm_config.xml -n 2                  # Launch first 2 VMs"
    echo "  $0 -c vm_config.xml -d 3                  # Launch VM with ID 3"
    echo "  $0 -c vm_config.xml --network localhost   # Use localhost network mode"
    echo
}

# Get value of a tag for a given VM ID from XML
get_vm_value() {
    local tag="$1"
    local vm_id="$2"
    local xml_file="$3"
    xmllint --xpath "string(//vm[@id='$vm_id']/$tag)" "$xml_file"
}

get_display_mode_config_value() {
    local mode="$1"
    local tag="$2"
    local xml_file="$3"

    local value
    value=$(xmllint --xpath "string(//display_configurations/mode[@name='$mode']/$tag)" "$xml_file" 2>/dev/null || true)

    if [[ -z "$value" ]]; then
        value=$(xmllint --xpath "string(//display_configuration[display_mode='$mode']/$tag)" "$xml_file" 2>/dev/null || true)
    fi

    echo "$value"
}

get_vm_display_value() {
    local tag="$1"
    local vm_id="$2"
    local xml_file="$3"

    local value
    value=$(xmllint --xpath "string(//vm[@id='$vm_id']/display_configuration/$tag)" "$xml_file" 2>/dev/null || true)

    if [[ -z "$value" ]]; then
        value=$(xmllint --xpath "string(//vm[@id='$vm_id']/$tag)" "$xml_file" 2>/dev/null || true)
    fi

    if [[ -z "$value" ]]; then
        value=$(get_display_mode_config_value "idv" "$tag" "$xml_file")
    fi

    echo "$value"
}

normalize_bool() {
    local value="$1"
    local default_value="$2"

    value="${value,,}"
    case "$value" in
        true|on|yes|1)
            echo "true"
            ;;
        false|off|no|0)
            echo "false"
            ;;
        *)
            echo "$default_value"
            ;;
    esac
}

bool_to_on_off() {
    local value="$1"
    [[ "$value" == "true" ]] && echo "on" || echo "off"
}

normalize_on_off() {
    local value="$1"
    local default_value="$2"

    value="${value,,}"
    case "$value" in
        on|off)
            echo "$value"
            ;;
        true)
            echo "on"
            ;;
        false)
            echo "off"
            ;;
        *)
            echo "$default_value"
            ;;
    esac
}

get_qemu_major_version() {
    qemu-system-x86_64 --version 2>/dev/null \
        | awk '/^QEMU emulator version/ { match($4, /^([0-9]+)/, m); print m[1]; exit }'
}

get_display_connector_count() {
    local mode="$1"
    local xml_file="$2"
    local count

    count=$(xmllint --xpath "count(//display_configurations/mode[@name='$mode']/connectors/connector)" "$xml_file" 2>/dev/null | cut -d'.' -f1)

    if [[ -z "$count" || "$count" == "0" ]]; then
        count=$(xmllint --xpath "count(//display_configuration[display_mode='$mode']/connectors/connector)" "$xml_file" 2>/dev/null | cut -d'.' -f1)
    fi

    [[ -z "$count" ]] && count=0
    echo "$count"
}

build_vm_connector_arg() {
    local vm_id="$1"
    local xml_file="$2"
    local connector_name
    local connector_index
    local connectors_arg=""
    local connector_count
    local i

    connector_count=$(xmllint --xpath "count(//vm[@id='$vm_id']/display_configuration/display_connectors/connector)" "$xml_file" 2>/dev/null | cut -d'.' -f1)

    if [[ -n "$connector_count" && "$connector_count" -gt 0 ]]; then
        for ((i=1; i<=connector_count; i++)); do
            connector_name=$(xmllint --xpath "string((//vm[@id='$vm_id']/display_configuration/display_connectors/connector)[${i}])" "$xml_file" 2>/dev/null || true)
            connector_index=$(xmllint --xpath "string((//vm[@id='$vm_id']/display_configuration/display_connectors/connector)[${i}]/@index)" "$xml_file" 2>/dev/null || true)

            if [[ -z "$connector_name" ]]; then
                echo "INVALID_CONNECTOR_NAME"
                return 0
            fi

            if [[ ! "$connector_index" =~ ^[0-9]+$ ]]; then
                echo "INVALID_CONNECTOR_INDEX:${connector_index}"
                return 0
            fi

            connectors_arg+="${connectors_arg:+,}connectors.${connector_index}=${connector_name}"
        done

        echo "$connectors_arg"
        return 0
    fi

    connector_name=$(xmllint --xpath "string(//vm[@id='$vm_id']/display_configuration/display_connectors/connector[1])" "$xml_file" 2>/dev/null || true)
    connector_index=$(xmllint --xpath "string(//vm[@id='$vm_id']/display_configuration/display_connectors/connector[1]/@index)" "$xml_file" 2>/dev/null || true)

    if [[ -z "$connector_name" ]]; then
        connector_name=$(get_vm_display_value "display_connector" "$vm_id" "$xml_file")
    fi

    if [[ -n "$connector_name" && -z "$connector_index" ]]; then
        case "${connector_name^^}" in
            DP-1)
                connector_index="0"
                ;;
            DP-2)
                connector_index="1"
                ;;
            HDMI-3)
                connector_index="2"
                ;;
            DP-3)
                connector_index="4"
                ;;
        esac
    fi

    [[ -z "$connector_name" ]] && { echo ""; return 0; }

    if [[ ! "$connector_index" =~ ^[0-9]+$ ]]; then
        echo "INVALID_CONNECTOR_INDEX:${connector_index}"
        return 0
    fi

    echo "connectors.${connector_index}=${connector_name}"
}

get_gpu_vf_device() {
    # Pattern: 45:00.0, 45:00.1, ..., 45:03.0
    # Assume vm_id is an integer index into the list of available devices
    local vm_id="$1"
    # Get all matching VGA devices from lspci output (with domain prefix)
    mapfile -t vga_devices < <(lspci -D | grep -i 'vga' | grep -i intel | awk '{print $1}')
    # Return the device corresponding to vm_id index
    if [[ $vm_id -ge 0 && $vm_id -lt ${#vga_devices[@]} ]]; then
        echo "${vga_devices[$vm_id]}"
    else
        echo ""
    fi
}

get_nr_hugepages() {
    cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo ""
}

write_nr_hugepages() {
    local pages="$1"
    echo "$pages" | sudo tee /proc/sys/vm/nr_hugepages > /dev/null 2>&1
}

calculate_total_vm_memory_mb() {
    local xml_file="$1"
    shift
    local ids=("$@")
    local total_memory_mb=0
    local id
    local memory_size

    for id in "${ids[@]}"; do
        memory_size=$(get_vm_value "memory_size" "$id" "$xml_file")
        if [[ ! "$memory_size" =~ ^[0-9]+$ || "$memory_size" -le 0 ]]; then
            echo -e "${RED}Error: invalid memory_size '${memory_size}' for VM ID $id${NC}" >&2
            return 1
        fi
        total_memory_mb=$((total_memory_mb + memory_size))
    done

    echo "$total_memory_mb"
}

# Set hugepages based on total VM memory in MB.
# Hugepages are 2MB each by default, so hugepages_needed = memory_mb / 2.
set_hugepages() {
    local memory_mb="$1"

    if [[ ! "$memory_mb" =~ ^[0-9]+$ || "$memory_mb" -le 0 ]]; then
        echo -e "${RED}Error: invalid memory value for hugepages: ${memory_mb}${NC}"
        return 1
    fi

    if [[ -z "$ORIGINAL_HUGEPAGES" ]]; then
        ORIGINAL_HUGEPAGES=$(get_nr_hugepages)
    fi

    if [[ ! "$ORIGINAL_HUGEPAGES" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: unable to read original hugepages value${NC}"
        return 1
    fi

    local old_hugepages="$ORIGINAL_HUGEPAGES"
    local new_hugepages=$((old_hugepages + (memory_mb / HUGEPAGE_SIZE_MB)))

    if (( memory_mb % HUGEPAGE_SIZE_MB != 0 )); then
        echo -e "${YELLOW}Warning: VM memory ${memory_mb} MB is not divisible by ${HUGEPAGE_SIZE_MB}; integer division applies.${NC}"
    fi

    echo -e "${BLUE}Configuring hugepages${NC}"
    echo -e "${BLUE}  VM Memory size     : ${memory_mb} MB${NC}"
    echo -e "${BLUE}  Old Hugepages size : ${old_hugepages}${NC}"
    echo -e "${BLUE}  New Hugepages size : ${new_hugepages}${NC}"

    if ! write_nr_hugepages "$new_hugepages"; then
        echo -e "${RED}Error: failed to set hugepages${NC}"
        return 1
    fi

    APPLIED_HUGEPAGES=$(get_nr_hugepages)
    HUGEPAGES_UPDATED="true"

    if [[ "$APPLIED_HUGEPAGES" == "$new_hugepages" ]]; then
        echo -e "${GREEN}Hugepages configured: ${APPLIED_HUGEPAGES}${NC}"
    else
        echo -e "${YELLOW}Hugepages applied with system adjustment: requested ${new_hugepages}, actual ${APPLIED_HUGEPAGES}${NC}"
    fi
}

destroy_hugepages() {
    if [[ "$HUGEPAGES_UPDATED" != "true" ]]; then
        return 0
    fi

    if [[ ! "$ORIGINAL_HUGEPAGES" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}Skipping hugepages destroy: original value is unavailable.${NC}"
        return 0
    fi

    if [[ ! "$APPLIED_HUGEPAGES" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}Skipping hugepages destroy: applied value is unavailable.${NC}"
        return 0
    fi

    local current_hugepages
    current_hugepages=$(get_nr_hugepages)
    local added_hugepages=$((APPLIED_HUGEPAGES - ORIGINAL_HUGEPAGES))

    if (( added_hugepages <= 0 )); then
        echo -e "${BLUE}No additional hugepages to destroy.${NC}"
        return 0
    fi

    if [[ "$current_hugepages" == "$ORIGINAL_HUGEPAGES" ]]; then
        echo -e "${BLUE}Hugepages already at original value: ${ORIGINAL_HUGEPAGES}${NC}"
        return 0
    fi

    if (( current_hugepages < added_hugepages )); then
        echo -e "${YELLOW}Skipping hugepages destroy: current value ${current_hugepages} is smaller than added pages ${added_hugepages}.${NC}"
        return 0
    fi

    local new_hugepages=$((current_hugepages - added_hugepages))

    echo -e "${BLUE}Destroying hugepages: ${current_hugepages} -> ${new_hugepages}${NC}"
    if write_nr_hugepages "$new_hugepages"; then
        echo -e "${GREEN}Hugepages destroyed successfully${NC}"
    else
        echo -e "${YELLOW}Warning: failed to destroy added hugepages${NC}"
    fi
}

# Pin vCPU threads to individual CPUs from the assigned range
pin_vcpu_threads() {
    local qemu_pid="$1"
    local cpu_assignment="$2"
    local cpu_cores="$3"
    local vm_id="$4"

    if [[ -z "$cpu_assignment" ]]; then
        return 0
    fi

    # Convert CPU range to individual CPU list (e.g., "4-7" -> [4, 5, 6, 7])
    local cpu_array=()
    local i
    for range in $(echo "$cpu_assignment" | tr ',' ' '); do
        if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            for ((i=start; i<=end; i++)); do
                cpu_array+=("$i")
            done
        elif [[ "$range" =~ ^[0-9]+$ ]]; then
            cpu_array+=("$range")
        fi
    done

    if [[ ${#cpu_array[@]} -eq 0 ]]; then
        return 0
    fi

    # Wait a moment for QEMU threads to be created
    sleep 1

    # Find vCPU threads by looking for KVM threads associated with this process
    local vcpu_count=0
    local tid
    local cpu_idx=0

    # Get TIDs of threads in the QEMU process
    local task_dir="/proc/$qemu_pid/task"
    if [[ ! -d "$task_dir" ]]; then
        echo -e "${YELLOW}Warning: Could not access task directory for PID $qemu_pid${NC}"
        return 0
    fi

    # Pin CPUs for KVM vCPU threads (typically named KVM vcpu:*)
    for tid_dir in "$task_dir"/*; do
        if [[ -d "$tid_dir" ]]; then
            tid=$(basename "$tid_dir")
            # Try to pin each thread to one of the assigned CPUs
            # Distribute threads across assigned CPUs
            local assigned_cpu="${cpu_array[$((cpu_idx % ${#cpu_array[@]}))]}"

            # Check if this thread name suggests it's a vCPU thread
            local comm_file="$tid_dir/comm"
            if [[ -f "$comm_file" ]]; then
                local thread_name
                thread_name=$(<"$comm_file")
                # Pin vCPU and IO threads
                if [[ "$thread_name" =~ ^(qemu-system|CPU|IO|kvm).*$ ]]; then
                    if taskset -p -c "$assigned_cpu" "$tid" >/dev/null 2>&1; then
                        ((vcpu_count++))
                        ((cpu_idx++))
                    fi
                fi
            fi
        fi
    done

    if [[ $vcpu_count -gt 0 ]]; then
        echo -e "${GREEN}Pinned $vcpu_count threads for VM $vm_id to CPUs: $cpu_assignment${NC}"
    fi
}

main() {
    # Default values
    vm_id=""
    xml_file=""
    vm_count=0           # 0 means all
    net_mode="localhost"
    error_msg=""

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help; exit 0 ;;
            -c|--config)
                if [[ -n "$2" && "$2" != -* ]]; then
                    xml_file="$2"; shift 2
                else
                    error_msg="Missing value for $1"; break
                fi ;;
            -n|--num-vms)
                if [[ -n "$2" && "$2" != -* ]]; then
                    vm_count="$2"; shift 2
                else
                    error_msg="Missing value for $1"; break
                fi ;;
            -d|--vm-id)
                if [[ -n "$2" && "$2" != -* ]]; then
                    vm_id="$2"; shift 2
                else
                    error_msg="Missing value for $1"; break
                fi ;;
            --network)
                if [[ -n "$2" && "$2" != -* ]]; then
                    net_mode="$2"; shift 2
                else
                    error_msg="Missing value for $1"; break
                fi ;;
            *)
                error_msg="Unknown option $1"; break ;;
        esac
    done

    # Validate arguments
    if [[ -n "$error_msg" || -z "$xml_file" ]]; then
        [[ -n "$error_msg" ]] && echo -e "${RED}Error: $error_msg${NC}"
        [[ -z "$xml_file" ]] && echo -e "${RED}Error: XML file not specified${NC}"
        show_help
        exit 1
    fi

    # Read all VM IDs from XML
    mapfile -t vm_ids < <(xmllint --xpath '//vm[@id]/@id' "$xml_file" 2>/dev/null | grep -oP 'id="\K[0-9]+')
    if [[ ${#vm_ids[@]} -eq 0 ]]; then
        echo -e "${RED}No VMs found in XML file${NC}"
        exit 1
    fi

    # First, calculate hugepages size required for all selected VMs, then set hugepages before launching any VM
    [[ -n "$vm_id" ]] && vm_ids=("$vm_id")

    selected_vm_ids=("${vm_ids[@]}")
    if [[ "$vm_count" =~ ^[0-9]+$ && "$vm_count" -gt 0 && ${#selected_vm_ids[@]} -gt "$vm_count" ]]; then
        selected_vm_ids=("${selected_vm_ids[@]:0:$vm_count}")
    fi

    total_memory_mb=$(calculate_total_vm_memory_mb "$xml_file" "${selected_vm_ids[@]}") || exit 1

    echo -e "${BLUE}Total memory for selected VMs: ${total_memory_mb} MB${NC}"
    set_hugepages "$total_memory_mb" || exit 1

    local qemu_major_version
    qemu_major_version=$(get_qemu_major_version)

    for id in "${selected_vm_ids[@]}"; do

        # Extract VM details
        name=$(get_vm_value "name" "$id" "$xml_file")
        memory_size=$(get_vm_value "memory_size" "$id" "$xml_file")
        cpu_cores=$(get_vm_value "cpu_cores" "$id" "$xml_file")
        cpu_threads=$(get_vm_value "cpu_threads" "$id" "$xml_file")
        mac_address=$(get_vm_value "mac_address" "$id" "$xml_file")
        disk_path=$(get_vm_value "disk_path" "$id" "$xml_file")
        ssh_port=$(get_vm_value "ssh_port" "$id" "$xml_file")
        monitor_port=$(get_vm_value "monitor_port" "$id" "$xml_file")
        vm_pid=$(get_vm_value "vm_pid" "$id" "$xml_file")
        os_type=$(get_vm_value "os_type" "$id" "$xml_file")
        description=$(get_vm_value "description" "$id" "$xml_file")
        cpu_assignment=$(get_vm_value "cpu_assignment" "$id" "$xml_file")
        usb_mouse_hostbus=$(get_vm_value "usb_mouse_hostbus" "$id" "$xml_file")
        usb_mouse_hostport=$(get_vm_value "usb_mouse_hostport" "$id" "$xml_file")

        # Only launch when all required fields are present
        if [[ -n "$name" && -n "$memory_size" && -n "$cpu_cores" && -n "$cpu_threads" && -n "$mac_address" && -n "$disk_path" && -n "$vm_pid" ]]; then
            echo -e "${GREEN}Launching VM: $name (ID: $id)...${NC}"

            # Network configuration
            if [[ "$net_mode" == "localhost" ]]; then
                if [[ ! "$ssh_port" =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}Error: invalid ssh_port for VM ID $id${NC}"
                    exit 1
                fi
                net_args=(-device "e1000,netdev=net${id},mac=${mac_address}" -netdev "user,id=net${id},hostfwd=tcp::${ssh_port}-:22")
            else
                net_args=(-device "e1000,netdev=net${id},mac=${mac_address}" -netdev "tap,id=net${id}")
            fi

            # CPU configuration
            if [[ "${os_type,,}" == "ubuntu" ]]; then
                cpu_args=(-cpu "host,host-phys-bits=on,host-phys-bits-limit=39")
            else
                cpu_args=(-cpu "host,hv_relaxed,hv-vapic,hv-spinlocks=4096,hv-time,hv-runtime,hv-synic,hv-stimer,hv_vpindex,hv-tlbflush,hv-ipi,kvm=off")
            fi

            # Bootloader configuration (OVMF for UEFI boot)
            guest_hint="${name,,} ${disk_path,,} ${description,,}"
            local disk_base="${disk_path%.*}"
            if [[ "${os_type,,}" == "ubuntu" || ( -z "$os_type" && "$guest_hint" == *"ubuntu"* ) ]]; then
                local ovmf_fd="${disk_base}_OVMF.fd"
                if [[ ! -f "$ovmf_fd" ]]; then
                    echo -e "${BLUE}Creating per-VM OVMF: ${ovmf_fd}${NC}"
                    cp "/usr/share/qemu/OVMF.fd" "$ovmf_fd" || { echo -e "${RED}Error: failed to copy OVMF.fd for VM ID $id${NC}"; exit 1; }
                fi
                ovmf_args=(
                    -drive file="${ovmf_fd},format=raw,if=pflash"
                )
                disk_format="raw"
            else
                local ovmf_code="${disk_base}_OVMF_CODE_4M.fd"
                local ovmf_vars="${disk_base}_OVMF_VARS_4M.fd"
                if [[ ! -f "$ovmf_code" ]]; then
                    echo -e "${BLUE}Creating per-VM OVMF CODE: ${ovmf_code}${NC}"
                    cp "/usr/share/OVMF/OVMF_CODE_4M.fd" "$ovmf_code" || { echo -e "${RED}Error: failed to copy OVMF_CODE_4M.fd for VM ID $id${NC}"; exit 1; }
                fi
                if [[ ! -f "$ovmf_vars" ]]; then
                    echo -e "${BLUE}Creating per-VM OVMF VARS: ${ovmf_vars}${NC}"
                    cp "/usr/share/OVMF/OVMF_VARS_4M.fd" "$ovmf_vars" || { echo -e "${RED}Error: failed to copy OVMF_VARS_4M.fd for VM ID $id${NC}"; exit 1; }
                fi
                ovmf_args=(
                    -drive file="${ovmf_code},format=raw,if=pflash,unit=0,readonly=on"
                    -drive file="${ovmf_vars},format=raw,if=pflash,unit=1"
                )
                disk_format="qcow2"
            fi

            # Memory configuration
            mem_args=(
                -object "memory-backend-memfd,id=mem${id},hugetlb=on,size=${memory_size}M"
                -machine "memory-backend=mem${id}"
            )

            # QEMU Guest Agent channel
            qga_id="qga${id}"
            qga_sock="/tmp/${qga_id}.sock"
            qga_args=(
                -device virtio-serial
                -chardev "socket,path=${qga_sock},server=on,wait=off,id=${qga_id}"
                -device "virtserialport,chardev=${qga_id},name=org.qemu.guest_agent.0"
            )

            # Optional QEMU monitor (telnet) configuration per VM from XML
            monitor_args=()
            if [[ "$monitor_port" =~ ^[0-9]+$ ]]; then
                monitor_args=(-monitor "telnet:localhost:${monitor_port},server,nowait")
            fi

            # Optional USB mouse passthrough per VM by host bus/port from lsusb -t.
            usb_args=()
            if [[ -n "$usb_mouse_hostbus" || -n "$usb_mouse_hostport" ]]; then
                if [[ -z "$usb_mouse_hostbus" || -z "$usb_mouse_hostport" ]]; then
                    echo -e "${RED}Error: vm id=${id} requires both usb_mouse_hostbus and usb_mouse_hostport.${NC}"
                    exit 1
                fi

                if [[ ! "$usb_mouse_hostbus" =~ ^[0-9]{1,3}$ ]]; then
                    echo -e "${RED}Error: vm id=${id} has invalid usb_mouse_hostbus '${usb_mouse_hostbus}'.${NC}"
                    exit 1
                fi

                if [[ ! "$usb_mouse_hostport" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
                    echo -e "${RED}Error: vm id=${id} has invalid usb_mouse_hostport '${usb_mouse_hostport}'.${NC}"
                    exit 1
                fi

                usb_args=(-device "usb-host,bus=xhci.0,hostbus=$((10#${usb_mouse_hostbus})),hostport=${usb_mouse_hostport}")
            fi

            # Display configuration
            display_args=()
            virtio_args=()
            local xml_fullscreen
            local xml_show_fps
            local xml_max_outputs
            local xml_blob
            local xml_hw_cursor
            local xml_input
            local xml_render_sync
            local connectors_arg
            local display_mode
            local display_mode_normalized
            local primary_ip
            local spice_port
            local host_primary_ip
            local fullscreen_flag
            local show_fps_flag
            local hw_cursor_flag
            local input_flag
            spice_args=()

            xml_fullscreen=$(get_vm_display_value "fullscreen" "$id" "$xml_file")
            xml_show_fps=$(get_vm_display_value "show_fps" "$id" "$xml_file")
            xml_max_outputs=$(get_vm_display_value "max_outputs" "$id" "$xml_file")
            xml_blob=$(get_vm_display_value "blob" "$id" "$xml_file")
            xml_hw_cursor=$(get_vm_display_value "hw_cursor" "$id" "$xml_file")
            xml_input=$(get_vm_display_value "input" "$id" "$xml_file")
            xml_render_sync=$(get_vm_display_value "render_sync" "$id" "$xml_file")
            display_mode=$(get_vm_display_value "display_mode" "$id" "$xml_file")
            spice_port=$(get_vm_display_value "spice_port" "$id" "$xml_file")
            connectors_arg=$(build_vm_connector_arg "$id" "$xml_file")

            if [[ -z "$display_mode" ]]; then
                display_mode=$(xmllint --xpath "string(//display_configurations/mode[1]/@name)" "$xml_file" 2>/dev/null || true)
            fi

            if [[ "$connectors_arg" == INVALID_CONNECTOR_INDEX:* ]]; then
                echo -e "${RED}Error: vm id=${id} has invalid connector index '${connectors_arg#INVALID_CONNECTOR_INDEX:}'.${NC}"
                exit 1
            fi

            if [[ "$connectors_arg" == "INVALID_CONNECTOR_NAME" ]]; then
                echo -e "${RED}Error: vm id=${id} has an empty connector name in display_configuration/display_connectors.${NC}"
                exit 1
            fi

            xml_fullscreen=$(normalize_bool "$xml_fullscreen" "false")
            xml_show_fps=$(normalize_bool "$xml_show_fps" "true")
            xml_blob=$(normalize_bool "$xml_blob" "true")
            xml_render_sync=$(normalize_bool "$xml_render_sync" "false")
            xml_hw_cursor=$(normalize_on_off "$xml_hw_cursor" "on")
            xml_input=$(normalize_on_off "$xml_input" "on")
            [[ -z "$xml_max_outputs" || ! "$xml_max_outputs" =~ ^[0-9]+$ || "$xml_max_outputs" -lt 1 ]] && xml_max_outputs="1"

            # USB tablet input: always for Ubuntu; for others only on single-monitor (max_outputs <= 1)
            usb_tablet_args=()
            if [[ "${os_type,,}" == "ubuntu" || "$xml_max_outputs" -le 1 ]]; then
                usb_tablet_args=(-device "usb-tablet,id=input0")
            fi

            fullscreen_flag=$(bool_to_on_off "$xml_fullscreen")
            show_fps_flag=$(bool_to_on_off "$xml_show_fps")
            hw_cursor_flag="$xml_hw_cursor"
            input_flag="$xml_input"
            display_mode_normalized="${display_mode,,}"
            [[ -z "$display_mode_normalized" ]] && display_mode_normalized="idv"

            if [[ -z "$primary_ip" ]]; then
                host_primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
                if [[ -n "$host_primary_ip" ]]; then
                    primary_ip="$host_primary_ip"
                elif [[ "$net_mode" == "localhost" ]]; then
                    primary_ip="127.0.0.1"
                else
                    primary_ip="0.0.0.0"
                fi
            fi

            if [[ -z "$spice_port" ]]; then
                    spice_port="$((5900 + id))"
            fi

            case "$display_mode_normalized" in
                idv)
                    local idv_display_opts="gtk,input=${input_flag},gl=on,full-screen=${fullscreen_flag},show-fps=${show_fps_flag}"
                    [[ "${qemu_major_version:-0}" -lt 10 ]] && idv_display_opts+=",hw-cursor=${hw_cursor_flag}"
                    [[ -n "$connectors_arg" ]] && idv_display_opts+=",${connectors_arg}"
                    display_args=(-display "$idv_display_opts")
                    ;;
                spice)
                    display_args=(-display "egl-headless")
                    spice_args=(-spice "addr=${primary_ip},port=${spice_port},disable-ticketing=on")
                    ;;
                spice-gtk)
                    display_args=(-display "none")
                    spice_args=(-spice "addr=${primary_ip},port=${spice_port},disable-ticketing=on,gl=on,streaming-video=filter,preferred-codec=gstreamer:h264,agent-mouse=on")
                    ;;
                *)
                    echo -e "${RED}Error: vm id=${id} has unsupported display_mode '${display_mode}'. Supported modes: idv, spice, spice-gtk.${NC}"
                    exit 1
                    ;;
            esac

            local virtio_device_opts="virtio-vga,max_outputs=${xml_max_outputs},blob=${xml_blob}"
            [[ "${qemu_major_version:-0}" -lt 10 ]] && virtio_device_opts+=",render_sync=${xml_render_sync}"
            virtio_args=(-device "$virtio_device_opts")

            # CPU assignment for taskset (optional)
            taskset_args=()
            if [[ -n "$cpu_assignment" ]]; then
                if [[ ! "$cpu_assignment" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
                    echo -e "${RED}Error: invalid cpu_assignment '${cpu_assignment}' for VM ID $id${NC}"
                    exit 1
                fi
                taskset_args=(taskset -c "$cpu_assignment")
            fi

            # QEMU command
            qemu_cmd=(
                "${taskset_args[@]}"
                qemu-system-x86_64 -k en-us
                -nodefaults -enable-kvm
                -name "$name"
                -m "$memory_size"
                -pidfile "$vm_pid"
                "${cpu_args[@]}"
                -smp cores="${cpu_cores},threads=${cpu_threads},sockets=1"
                -machine "q35,kernel_irqchip=on"
                "${ovmf_args[@]}"
                -device "qemu-xhci,id=xhci"
                -rtc base=localtime
                "${usb_tablet_args[@]}"
                "${usb_args[@]}"
                -drive file="${disk_path},format=${disk_format},cache=none"
                -device "vfio-pci,host=$(get_gpu_vf_device "$id")"
                "${net_args[@]}"
                "${virtio_args[@]}"
                "${display_args[@]}"
                "${spice_args[@]}"
                "${mem_args[@]}"
                "${monitor_args[@]}"
                "${qga_args[@]}"
            )

            echo -e "${BLUE}QEMU command:${NC}"
            echo "${qemu_cmd[*]} &"
            "${qemu_cmd[@]}" &
            local qemu_pid=$!

            # Pin vCPU threads to assigned CPUs
            if [[ -n "$cpu_assignment" ]]; then
                pin_vcpu_threads "$qemu_pid" "$cpu_assignment" "$cpu_cores" "$id"
            fi
        else
            echo -e "${YELLOW}Skipping VM ID $id: missing required fields${NC}"
        fi
    done
    wait
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap destroy_hugepages EXIT
    main "$@"
fi
