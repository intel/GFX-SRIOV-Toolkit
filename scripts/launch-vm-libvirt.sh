#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.
# Version: 1.1
#
# launch-vm-libvirt.sh — VM launcher using libvirt (virsh / virt-manager).
#
# Reads the same XML configuration as launch-vm.sh, generates a libvirt
# domain XML per VM, and defines/starts each domain via virsh.
# Optionally opens virt-manager for interactive management.
#
# Display modes:
#   idv       - GTK window with OpenGL (show-fps, hw-cursor, connector routing
#               passed via qemu:commandline; libvirt <graphics type="gtk">
#               does not expose these options natively)
#   spice     - SPICE server on localhost (connect with virt-viewer / remote-viewer)
#   spice-gtk - SPICE server with GL streaming (OpenGL-accelerated SPICE)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'                     # no colour reset

HUGEPAGE_SIZE_MB=2               # host huge page size in MiB (2 MiB pages)

# Hugepage state — tracks pages added by this script so they can be restored
ORIGINAL_HUGEPAGES=""
APPLIED_HUGEPAGES=""
HUGEPAGES_UPDATED="false"

# libvirt and firmware paths (all overridable via environment variables)
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
LIBVIRT_NVRAM_DIR="${LIBVIRT_NVRAM_DIR:-/var/lib/libvirt/qemu/nvram}"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

show_help() {
    echo -e "${BLUE}=== VM Launcher (libvirt) Help ===${NC}\n"
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help                 Show this help message"
    echo "  -c, --config FILE          VM XML configuration file (required)"
    echo "  -n, --num-vms NUM          Launch only NUM VMs (default: all)"
    echo "  -d, --vm-id ID             Launch only VM with specified ID"
    echo "      --network MODE         Network mode: 'localhost' (default) or 'dynamic'"
    echo "      --virt-manager         Open virt-manager after starting VMs"
    echo "      --define-only          Define VMs in libvirt without starting them"
    echo
    echo "Examples:"
    echo "  $0 -c vm_config.xml                       # Launch all VMs"
    echo "  $0 -c vm_config.xml -n 2                  # Launch first 2 VMs"
    echo "  $0 -c vm_config.xml -d 3                  # Launch VM with ID 3"
    echo "  $0 -c vm_config.xml --virt-manager        # Launch VMs and open virt-manager"
    echo "  $0 -c vm_config.xml --define-only         # Define VMs without starting"
    echo "  $0 -c vm_config.xml --network dynamic     # Use bridge/tap networking"
    echo
    echo "Requirements:"
    echo "  - sudo apt-get install libvirt-clients libvirt-daemon-system ovmf"
    echo "  - sudo usermod -aG libvirt \$USER  (then re-login)"
    echo "  - sudo systemctl enable --now libvirtd"
    echo "  - For IDV display: DISPLAY must be set (X11)"
    echo "  - For SPICE display: virt-viewer or remote-viewer recommended"
    echo
    echo "Environment overrides:"
    echo "  LIBVIRT_URI         libvirt connection URI (default: qemu:///system)"
    echo "  OVMF_CODE           OVMF code firmware path"
    echo "  OVMF_VARS_TEMPLATE  OVMF vars template path"
    echo
}

# ---------------------------------------------------------------------------
# XML Parsing  (identical to launch-vm.sh — same config file works for both)
# ---------------------------------------------------------------------------

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
    # Pattern: 0000:45:00.0, 0000:45:00.1, ..., 0000:45:03.0
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

# ---------------------------------------------------------------------------
# Hugepage Management
# ---------------------------------------------------------------------------
# The host must pre-allocate 2 MiB hugepages before libvirt can start a domain
# that uses <memoryBacking><hugepages/>.  These functions raise the hugepage
# count before launch and restore the original value after all VMs have stopped.

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

# ---------------------------------------------------------------------------
# libvirt Helpers
# ---------------------------------------------------------------------------

# Parse a PCI address "DDDD:BB:SS.F" into space-separated 0x-prefixed components.
parse_pci_address() {
    local pci_addr="$1"
    if [[ "$pci_addr" =~ ^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-9a-fA-F]+)$ ]]; then
        echo "0x${BASH_REMATCH[1]} 0x${BASH_REMATCH[2]} 0x${BASH_REMATCH[3]} 0x${BASH_REMATCH[4]}"
    fi
}

# Build a libvirt <cputune> block from a cpu_assignment range string.
# vCPUs are pinned round-robin when the CPU list is smaller than vcpu_count.
build_cputune_xml() {
    local cpu_assignment="$1"
    local vcpu_count="$2"
    local cpu_array=()
    local range i

    for range in $(echo "$cpu_assignment" | tr ',' ' '); do
        if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((i=BASH_REMATCH[1]; i<=BASH_REMATCH[2]; i++)); do
                cpu_array+=("$i")
            done
        elif [[ "$range" =~ ^[0-9]+$ ]]; then
            cpu_array+=("$range")
        fi
    done

    [[ ${#cpu_array[@]} -eq 0 ]] && return

    echo "  <cputune>"
    for ((i=0; i<vcpu_count; i++)); do
        local cpu="${cpu_array[$((i % ${#cpu_array[@]}))]}"
        echo "    <vcpupin vcpu=\"$i\" cpuset=\"$cpu\"/>"
    done
    echo "  </cputune>"
}

# Generate a complete libvirt domain XML for one VM and write it to stdout.
#
# IDV display options that libvirt's <graphics type="gtk"> does not expose
# natively (show-fps, hw-cursor, connector routing) are forwarded via
# <qemu:commandline>. SPICE modes use native libvirt graphics elements and
# are fully visible/manageable through virt-manager.
generate_domain_xml() {
    local vm_id="$1"
    local xml_file="$2"
    local net_mode="$3"
    local qemu_major_version="$4"

    # -- VM configuration fields --
    local name memory_size cpu_cores cpu_threads mac_address disk_path
    local ssh_port os_type cpu_assignment usb_mouse_hostbus usb_mouse_hostport
    name=$(get_vm_value "name"               "$vm_id" "$xml_file")
    memory_size=$(get_vm_value "memory_size" "$vm_id" "$xml_file")
    cpu_cores=$(get_vm_value "cpu_cores"     "$vm_id" "$xml_file")
    cpu_threads=$(get_vm_value "cpu_threads" "$vm_id" "$xml_file")
    mac_address=$(get_vm_value "mac_address" "$vm_id" "$xml_file")
    disk_path=$(get_vm_value "disk_path"     "$vm_id" "$xml_file")
    ssh_port=$(get_vm_value "ssh_port"       "$vm_id" "$xml_file")
    os_type=$(get_vm_value "os_type"         "$vm_id" "$xml_file")
    cpu_assignment=$(get_vm_value "cpu_assignment"         "$vm_id" "$xml_file")
    usb_mouse_hostbus=$(get_vm_value "usb_mouse_hostbus"   "$vm_id" "$xml_file")
    usb_mouse_hostport=$(get_vm_value "usb_mouse_hostport" "$vm_id" "$xml_file")

    # -- Display configuration --
    local xml_fullscreen xml_show_fps xml_max_outputs xml_blob
    local xml_hw_cursor xml_input xml_render_sync display_mode spice_port connectors_arg
    xml_fullscreen=$(get_vm_display_value "fullscreen"   "$vm_id" "$xml_file")
    xml_show_fps=$(get_vm_display_value "show_fps"       "$vm_id" "$xml_file")
    xml_max_outputs=$(get_vm_display_value "max_outputs" "$vm_id" "$xml_file")
    xml_blob=$(get_vm_display_value "blob"               "$vm_id" "$xml_file")
    xml_hw_cursor=$(get_vm_display_value "hw_cursor"     "$vm_id" "$xml_file")
    xml_input=$(get_vm_display_value "input"             "$vm_id" "$xml_file")
    xml_render_sync=$(get_vm_display_value "render_sync" "$vm_id" "$xml_file")
    display_mode=$(get_vm_display_value "display_mode"   "$vm_id" "$xml_file")
    spice_port=$(get_vm_display_value "spice_port"       "$vm_id" "$xml_file")
    connectors_arg=$(build_vm_connector_arg "$vm_id" "$xml_file")

    if [[ -z "$display_mode" ]]; then
        display_mode=$(xmllint --xpath "string(//display_configurations/mode[1]/@name)" "$xml_file" 2>/dev/null || true)
    fi
    [[ -z "$display_mode" ]] && display_mode="idv"
    display_mode="${display_mode,,}"

    # Validate connector results
    if [[ "$connectors_arg" == INVALID_CONNECTOR_INDEX:* ]]; then
        echo -e "${RED}Error: vm id=${vm_id} has invalid connector index '${connectors_arg#INVALID_CONNECTOR_INDEX:}'.${NC}" >&2
        return 1
    fi
    if [[ "$connectors_arg" == "INVALID_CONNECTOR_NAME" ]]; then
        echo -e "${RED}Error: vm id=${vm_id} has an empty connector name in display_configuration/display_connectors.${NC}" >&2
        return 1
    fi

    # Normalize display options
    xml_fullscreen=$(normalize_bool "$xml_fullscreen" "false")
    xml_show_fps=$(normalize_bool "$xml_show_fps" "true")
    xml_blob=$(normalize_bool "$xml_blob" "true")
    xml_render_sync=$(normalize_bool "$xml_render_sync" "false")
    xml_hw_cursor=$(normalize_on_off "$xml_hw_cursor" "on")
    xml_input=$(normalize_on_off "$xml_input" "on")
    [[ -z "$xml_max_outputs" || ! "$xml_max_outputs" =~ ^[0-9]+$ || "$xml_max_outputs" -lt 1 ]] && xml_max_outputs="1"

    local fullscreen_flag; fullscreen_flag=$(bool_to_on_off "$xml_fullscreen")
    local show_fps_flag;   show_fps_flag=$(bool_to_on_off "$xml_show_fps")

    local vcpu_count=$(( cpu_cores * cpu_threads ))

    # GPU VF PCI passthrough address
    local gpu_pci gpu_domain gpu_bus gpu_slot gpu_func
    gpu_pci=$(get_gpu_vf_device "$vm_id")
    if [[ -n "$gpu_pci" ]]; then
        read -r gpu_domain gpu_bus gpu_slot gpu_func <<< "$(parse_pci_address "$gpu_pci")"
    fi

    # Disk format derived from file extension
    local disk_format
    case "${disk_path##*.}" in
        qcow2) disk_format="qcow2" ;;
        *)     disk_format="raw"   ;;
    esac

    # Per-VM NVRAM vars file; libvirt auto-copies the template on first boot
    local nvram_path="${LIBVIRT_NVRAM_DIR}/${name}_VARS.fd"

    [[ -z "$spice_port" ]] && spice_port=$(( 5900 + vm_id ))

    # -- Build XML sections --

    # CPU pinning
    local cputune_xml=""
    if [[ -n "$cpu_assignment" ]]; then
        if [[ ! "$cpu_assignment" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
            echo -e "${RED}Error: invalid cpu_assignment '${cpu_assignment}' for VM ID $vm_id${NC}" >&2
            return 1
        fi
        cputune_xml=$(build_cputune_xml "$cpu_assignment" "$vcpu_count")
    fi

    # Network: SLIRP user-mode (localhost) or libvirt-managed bridge (dynamic).
    # localhost uses qemu:commandline to forward SSH — no passt required,
    # matching the approach in launch-vm.sh.
    local net_xml="" net_qemu_args=""
    if [[ "$net_mode" == "localhost" ]]; then
        if [[ ! "$ssh_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Error: invalid ssh_port for VM ID $vm_id${NC}" >&2
            return 1
        fi
        net_qemu_args="    <qemu:arg value=\"-device\"/>
    <qemu:arg value=\"pcie-root-port,id=net-rp${vm_id},bus=pcie.0,addr=0x3,chassis=$((100 + vm_id)),port=$((0x18 + vm_id))\"/>
    <qemu:arg value=\"-device\"/>
    <qemu:arg value=\"e1000,netdev=net${vm_id},mac=${mac_address},bus=net-rp${vm_id},addr=0x0\"/>
    <qemu:arg value=\"-netdev\"/>
    <qemu:arg value=\"user,id=net${vm_id},hostfwd=tcp::${ssh_port}-:22\"/>"
    else
        net_xml="    <interface type=\"network\">
      <source network=\"default\"/>
      <mac address=\"${mac_address}\"/>
      <model type=\"e1000\"/>
    </interface>"
    fi

    # GPU VF hostdev (VFIO passthrough)
    local gpu_hostdev_xml=""
    if [[ -n "$gpu_domain" ]]; then
        gpu_hostdev_xml="    <hostdev mode=\"subsystem\" type=\"pci\" managed=\"yes\">
      <source>
        <address domain=\"${gpu_domain}\" bus=\"${gpu_bus}\" slot=\"${gpu_slot}\" function=\"${gpu_func}\"/>
      </source>
    </hostdev>"
    fi

    # USB tablet
    local usb_tablet_xml=""
    if [[ "${os_type,,}" == "ubuntu" || "$xml_max_outputs" -le 1 ]]; then
        usb_tablet_xml="    <input type=\"tablet\" bus=\"usb\"/>"
    fi

    # Windows HyperV enlightenments — passed via qemu:commandline -cpu override
    # because libvirt 10.x lacks <hyperv><time> needed by hv-stimer.  The last
    # -cpu argument wins in QEMU so our override replaces libvirt's generated one.
    local cpu_override_args=""
    if [[ "${os_type,,}" == "windows" ]]; then
        cpu_override_args="    <qemu:arg value=\"-cpu\"/>
    <qemu:arg value=\"host,migratable=off,hv-relaxed=on,hv-vapic=on,hv-spinlocks=0x1000,hv-time=on,hv-runtime=on,hv-synic=on,hv-stimer=on,hv-vpindex=on,hv-tlbflush=on,hv-ipi=on,kvm=off\"/>"
    fi

    # Display — IDV forwards the full -display gtk,... string via qemu:commandline
    # so all IDV-specific options (show-fps, hw-cursor, connectors) are preserved.
    local graphics_xml="" video_xml="" qemu_display_args=""

    # max_outputs is a standard virtio-gpu property; use native libvirt <video>.
    # blob and render_sync are custom (non-upstream) QEMU patches — libvirt does not
    # know them, so they are applied via <qemu:override> on the video0 alias.
    # render_sync was removed in QEMU 10; only include it on older versions.

    video_xml="    <video>
      <model type=\"virtio\" heads=\"${xml_max_outputs}\"/>
    </video>"

    local qemu_override_props="        <qemu:property name=\"blob\" type=\"bool\" value=\"${xml_blob}\"/>"
    if [[ "${qemu_major_version:-0}" -lt 10 ]]; then
        qemu_override_props+="
        <qemu:property name=\"render_sync\" type=\"bool\" value=\"${xml_render_sync}\"/>"
    fi

    local qemu_override_xml="  <qemu:override>
    <qemu:device alias=\"video0\">
      <qemu:frontend>
${qemu_override_props}
      </qemu:frontend>
    </qemu:device>
  </qemu:override>"

    case "$display_mode" in
        idv)
            local display_opts="gtk,gl=on,input=${xml_input},full-screen=${fullscreen_flag},show-fps=${show_fps_flag}"
            [[ "${qemu_major_version:-0}" -lt 10 ]] && display_opts+=",hw-cursor=${xml_hw_cursor}"
            [[ -n "$connectors_arg" ]] && display_opts+=",${connectors_arg}"
            # IDV uses a local GTK window; gl=on requires DRM access — QEMU runs as
            # root via qemu.conf so DRI render nodes are accessible.
            # libvirt injects -display none when no <graphics> element is present;
            # qemu:commandline args come last so -display gtk,... overrides it.
            qemu_display_args="    <qemu:arg value=\"-display\"/>
    <qemu:arg value=\"${display_opts}\"/>
    <qemu:env name=\"DISPLAY\" value=\"${DISPLAY:-:0}\"/>
    <qemu:env name=\"XAUTHORITY\" value=\"${XAUTHORITY:-${HOME}/.Xauthority}\"/>"
            ;;
        spice)
            graphics_xml="    <graphics type=\"spice\" port=\"${spice_port}\" listen=\"127.0.0.1\">
      <listen type=\"address\" address=\"127.0.0.1\"/>
      <image compression=\"off\"/>
    </graphics>"
            ;;
        spice-gtk)
            graphics_xml="    <graphics type=\"spice\" port=\"${spice_port}\" listen=\"0.0.0.0\">
      <listen type=\"address\" address=\"0.0.0.0\"/>
      <streaming mode=\"filter\"/>
      <gl enable=\"yes\"/>
    </graphics>"
            ;;
        *)
            echo -e "${RED}Error: vm id=${vm_id} has unsupported display_mode '${display_mode}'. Supported modes: idv, spice, spice-gtk.${NC}" >&2
            return 1
            ;;
    esac

    # USB mouse passthrough by host bus/port — forwarded via qemu:commandline
    # because libvirt USB hostdev uses vendor/product IDs, not bus/port paths.
    local usb_hostdev_qemu_args=""
    if [[ -n "$usb_mouse_hostbus" || -n "$usb_mouse_hostport" ]]; then
        if [[ -z "$usb_mouse_hostbus" || -z "$usb_mouse_hostport" ]]; then
            echo -e "${RED}Error: vm id=${vm_id} requires both usb_mouse_hostbus and usb_mouse_hostport.${NC}" >&2
            return 1
        fi
        if [[ ! "$usb_mouse_hostbus" =~ ^[0-9]{1,3}$ ]]; then
            echo -e "${RED}Error: vm id=${vm_id} has invalid usb_mouse_hostbus '${usb_mouse_hostbus}'.${NC}" >&2
            return 1
        fi
        if [[ ! "$usb_mouse_hostport" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            echo -e "${RED}Error: vm id=${vm_id} has invalid usb_mouse_hostport '${usb_mouse_hostport}'.${NC}" >&2
            return 1
        fi
        usb_hostdev_qemu_args="    <qemu:arg value=\"-device\"/>
    <qemu:arg value=\"usb-host,bus=xhci.0,hostbus=$((10#${usb_mouse_hostbus})),hostport=${usb_mouse_hostport}\"/>"
    fi

    # QEMU Guest Agent channel
    local qga_xml="    <channel type=\"unix\">
      <source mode=\"bind\" path=\"/tmp/qga${vm_id}.sock\"/>
      <target type=\"virtio\" name=\"org.qemu.guest_agent.0\"/>
    </channel>"

    # Combine qemu:commandline args (network, IDV display, optional USB passthrough).
    # qemu:override is always emitted (for blob/render_sync), so the qemu: namespace
    # is always needed even when qemu:commandline is absent (spice/dynamic without USB).
    local qemu_cmdline_parts=""
    [[ -n "$net_qemu_args" ]]         && qemu_cmdline_parts+="${net_qemu_args}"
    [[ -n "$cpu_override_args" ]]     && qemu_cmdline_parts+="${qemu_cmdline_parts:+$'\n'}${cpu_override_args}"
    [[ -n "$qemu_display_args" ]]     && qemu_cmdline_parts+="${qemu_cmdline_parts:+$'\n'}${qemu_display_args}"
    [[ -n "$usb_hostdev_qemu_args" ]] && qemu_cmdline_parts+="${qemu_cmdline_parts:+$'\n'}${usb_hostdev_qemu_args}"
    local qemu_cmdline_xml=""
    if [[ -n "$qemu_cmdline_parts" ]]; then
        qemu_cmdline_xml="  <qemu:commandline>
${qemu_cmdline_parts}
  </qemu:commandline>"
    fi

    # The qemu: namespace is always required (qemu:override is always emitted)
    local domain_ns=" xmlns:qemu=\"http://libvirt.org/schemas/domain/qemu/1.0\""

    # -- Emit domain XML --
    cat <<DOMAINEOF
<domain type="kvm"${domain_ns}>
  <name>${name}</name>
  <memory unit="MiB">${memory_size}</memory>
  <currentMemory unit="MiB">${memory_size}</currentMemory>
  <memoryBacking>
    <hugepages/>
    <source type="memfd"/>
    <access mode="shared"/>
  </memoryBacking>
  <vcpu placement="static">${vcpu_count}</vcpu>
${cputune_xml}  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode="host-passthrough" check="none" migratable="off">
    <topology sockets="1" cores="${cpu_cores}" threads="${cpu_threads}"/>
  </cpu>
  <os>
    <type arch="x86_64" machine="q35">hvm</type>
    <loader readonly="yes" secure="no" type="pflash">${OVMF_CODE}</loader>
    <nvram template="${OVMF_VARS_TEMPLATE}">${nvram_path}</nvram>
    <boot dev="hd"/>
  </os>
  <clock offset="localtime">
    <timer name="rtc" tickpolicy="catchup"/>
    <timer name="pit" tickpolicy="delay"/>
    <timer name="hpet" present="no"/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="${disk_format}" cache="none"/>
      <source file="${disk_path}"/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <controller type="usb" model="qemu-xhci" index="0"/>
    <controller type="pci" model="pcie-root" index="0"/>
${net_xml}
${usb_tablet_xml}
    <input type="keyboard" bus="ps2"/>
${gpu_hostdev_xml}
${video_xml}
${graphics_xml}
${qga_xml}
    <memballoon model="none"/>
  </devices>
${qemu_cmdline_xml:+${qemu_cmdline_xml}
}${qemu_override_xml}
  <seclabel type="none"/>
</domain>
DOMAINEOF
}

# ---------------------------------------------------------------------------
# Dependency Installation
# ---------------------------------------------------------------------------

check_and_install_deps() {
    # Map: command -> apt package
    local -A cmd_to_pkg=(
        [virsh]="libvirt-clients"
        [xmllint]="libxml2-utils"
        [qemu-system-x86_64]="qemu-system-x86"
    )
    # Additional packages with no single representative binary
    local extra_pkgs=("libvirt-daemon-system" "ovmf")

    local missing_pkgs=()

    for cmd in "${!cmd_to_pkg[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_pkgs+=("${cmd_to_pkg[$cmd]}")
        fi
    done

    for pkg in "${extra_pkgs[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        echo -e "${GREEN}All dependencies are satisfied.${NC}"
        return 0
    fi

    # Deduplicate
    local unique_pkgs
    mapfile -t unique_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)

    echo -e "${YELLOW}Missing packages: ${unique_pkgs[*]}${NC}"
    echo -e "${BLUE}Installing missing dependencies...${NC}"

    if ! sudo apt-get update -qq; then
        echo -e "${RED}Error: apt-get update failed${NC}"
        exit 1
    fi

    if ! sudo apt-get install -y "${unique_pkgs[@]}"; then
        echo -e "${RED}Error: failed to install: ${unique_pkgs[*]}${NC}"
        exit 1
    fi

    echo -e "${GREEN}Dependencies installed successfully.${NC}"

    # Enable and start libvirtd if it was just installed
    if [[ " ${unique_pkgs[*]} " == *" libvirt-daemon-system "* ]]; then
        sudo systemctl enable --now libvirtd 2>/dev/null || true
        if ! groups | grep -qw libvirt; then
            echo -e "${YELLOW}Note: run 'sudo usermod -aG libvirt \$USER' and re-login for non-root virsh access.${NC}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# IDV Display Access Setup
# ---------------------------------------------------------------------------
# IDV mode requires the QEMU process to run as root (configured via qemu.conf)
# so it can open DRI render nodes for EGL/OpenGL.  AppArmor confinement is
# disabled separately via <seclabel type="none"/> in the domain XML.
grant_idv_display_access() {
    # IDV requires -display gtk,gl=on and blob=true on virtio-vga, both of which
    # need EGL/DRM access (/dev/dri/renderD*).
    # Two libvirt barriers must be lifted:
    #   1. user/group: default 'libvirt-qemu' has no DRM access → run as root
    #   2. cgroup_device_acl: libvirt's cgroup allow-list blocks /dev/dri/* even
    #      for root → must explicitly add DRI nodes to the ACL
    local qemu_conf="/etc/libvirt/qemu.conf"
    local needs_restart=false

    # Detect DRI card/render nodes and udmabuf present on this host.
    local extra_devs=""
    for dev in /dev/dri/card* /dev/dri/renderD* /dev/udmabuf; do
        [[ -c "$dev" ]] && extra_devs+=$',\n    '"\"$dev\""
    done

    if [[ ! -f "$qemu_conf" ]]; then
        echo -e "${BLUE}Creating ${qemu_conf} for IDV DRM/EGL access...${NC}"
        cat > "$qemu_conf" << EOF
# /etc/libvirt/qemu.conf — managed by launch-vm-virt.sh
user = "root"
group = "root"
cgroup_device_acl = [
    "/dev/null", "/dev/full", "/dev/zero",
    "/dev/random", "/dev/urandom",
    "/dev/ptmx", "/dev/kvm",
    "/dev/rtc", "/dev/hpet",
    "/dev/net/tun"${extra_devs}
]
EOF
        needs_restart=true
    else
        # user = "root"
        if ! grep -qE '^user\s*=\s*"root"' "$qemu_conf"; then
            grep -qE '^#?[[:space:]]*user[[:space:]]*=' "$qemu_conf" \
                && sed -i 's|^#\?[[:space:]]*user[[:space:]]*=.*|user = "root"|' "$qemu_conf" \
                || echo 'user = "root"' >> "$qemu_conf"
            needs_restart=true
            echo -e "${GREEN}Set QEMU user = root in qemu.conf.${NC}"
        fi
        # group = "root"
        if ! grep -qE '^group\s*=\s*"root"' "$qemu_conf"; then
            grep -qE '^#?[[:space:]]*group[[:space:]]*=' "$qemu_conf" \
                && sed -i 's|^#\?[[:space:]]*group[[:space:]]*=.*|group = "root"|' "$qemu_conf" \
                || echo 'group = "root"' >> "$qemu_conf"
            needs_restart=true
        fi
        # cgroup_device_acl — verify all detected DRI/udmabuf devices are listed;
        # rewrite the block if any are missing.
        local acl_needs_update=false
        for dev in /dev/dri/renderD* /dev/udmabuf; do
            [[ -c "$dev" ]] && ! grep -qF "\"$dev\"" "$qemu_conf" && acl_needs_update=true && break
        done
        if [[ "$acl_needs_update" == "true" ]]; then
            sed -i '/^cgroup_device_acl/,/^\]/d' "$qemu_conf"
            cat >> "$qemu_conf" << EOF
cgroup_device_acl = [
    "/dev/null", "/dev/full", "/dev/zero",
    "/dev/random", "/dev/urandom",
    "/dev/ptmx", "/dev/kvm",
    "/dev/rtc", "/dev/hpet",
    "/dev/net/tun"${extra_devs}
]
EOF
            needs_restart=true
            echo -e "${GREEN}Updated cgroup_device_acl in qemu.conf.${NC}"
        fi
    fi

    if [[ "$needs_restart" == "true" ]]; then
        echo -e "${BLUE}Restarting libvirtd to apply qemu.conf changes...${NC}"
        systemctl restart libvirtd 2>/dev/null || true
        sleep 2
    fi

    # X11 display access — grant to root (the QEMU user after the change above).
    if command -v xhost &>/dev/null && [[ -n "${DISPLAY:-}" ]]; then
        xhost "+si:localuser:root" &>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# VM Lifecycle
# ---------------------------------------------------------------------------

# Define (and optionally start) a libvirt domain.
# Any existing domain with the same name is stopped and undefined first.
launch_vm_libvirt() {
    local domain_xml_file="$1"
    local vm_name="$2"
    local define_only="$3"

    if virsh -c "${LIBVIRT_URI}" domstate "${vm_name}" &>/dev/null 2>&1; then
        echo -e "${YELLOW}Stopping and undefining existing domain: ${vm_name}${NC}"
        virsh -c "${LIBVIRT_URI}" destroy "${vm_name}" 2>/dev/null || true
        virsh -c "${LIBVIRT_URI}" undefine "${vm_name}" --nvram 2>/dev/null \
            || virsh -c "${LIBVIRT_URI}" undefine "${vm_name}" 2>/dev/null || true
    fi

    echo -e "${BLUE}Defining domain: ${vm_name}${NC}"
    if ! virsh -c "${LIBVIRT_URI}" define "${domain_xml_file}"; then
        echo -e "${RED}Error: failed to define domain ${vm_name}${NC}"
        return 1
    fi

    if [[ "$define_only" == "true" ]]; then
        echo -e "${GREEN}Domain defined (not started): ${vm_name}${NC}"
        return 0
    fi

    echo -e "${BLUE}Starting domain: ${vm_name}${NC}"
    if ! virsh -c "${LIBVIRT_URI}" start "${vm_name}"; then
        echo -e "${RED}Error: failed to start domain ${vm_name}${NC}"
        return 1
    fi

    echo -e "${GREEN}Domain started: ${vm_name}${NC}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local vm_id="" xml_file="" vm_count=0 net_mode="localhost"
    local open_virt_manager="false" define_only="false"
    local error_msg=""

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
            --virt-manager)
                open_virt_manager="true"; shift ;;
            --define-only)
                define_only="true"; shift ;;
            *)
                error_msg="Unknown option $1"; break ;;
        esac
    done

    if [[ -n "$error_msg" || -z "$xml_file" ]]; then
        [[ -n "$error_msg" ]] && echo -e "${RED}Error: $error_msg${NC}"
        [[ -z "$xml_file" ]] && echo -e "${RED}Error: XML file not specified${NC}"
        show_help
        exit 1
    fi

    # Dependency checks and installation
    check_and_install_deps

    # Read all VM IDs from config XML
    mapfile -t vm_ids < <(xmllint --xpath '//vm[@id]/@id' "$xml_file" 2>/dev/null | grep -oP 'id="\K[0-9]+')
    if [[ ${#vm_ids[@]} -eq 0 ]]; then
        echo -e "${RED}No VMs found in XML file${NC}"
        exit 1
    fi

    # Apply --vm-id / --num-vms filters
    [[ -n "$vm_id" ]] && vm_ids=("$vm_id")
    local selected_vm_ids=("${vm_ids[@]}")
    if [[ "$vm_count" =~ ^[0-9]+$ && "$vm_count" -gt 0 && ${#selected_vm_ids[@]} -gt "$vm_count" ]]; then
        selected_vm_ids=("${selected_vm_ids[@]:0:$vm_count}")
    fi

    # Pre-allocate hugepages for all selected VMs
    local total_memory_mb
    total_memory_mb=$(calculate_total_vm_memory_mb "$xml_file" "${selected_vm_ids[@]}") || exit 1
    echo -e "${BLUE}Total memory for selected VMs: ${total_memory_mb} MB${NC}"
    set_hugepages "$total_memory_mb" || exit 1

    local qemu_major_version
    qemu_major_version=$(get_qemu_major_version)

    # Ensure libvirt NVRAM directory exists
    sudo mkdir -p "${LIBVIRT_NVRAM_DIR}"

    # Process each VM
    local id name memory_size cpu_cores cpu_threads mac_address disk_path
    local -a started_names=()
    for id in "${selected_vm_ids[@]}"; do
        name=$(get_vm_value "name"               "$id" "$xml_file")
        memory_size=$(get_vm_value "memory_size" "$id" "$xml_file")
        cpu_cores=$(get_vm_value "cpu_cores"     "$id" "$xml_file")
        cpu_threads=$(get_vm_value "cpu_threads" "$id" "$xml_file")
        mac_address=$(get_vm_value "mac_address" "$id" "$xml_file")
        disk_path=$(get_vm_value "disk_path"     "$id" "$xml_file")

        if [[ -n "$name" && -n "$memory_size" && -n "$cpu_cores" && -n "$cpu_threads" \
              && -n "$mac_address" && -n "$disk_path" ]]; then
            echo -e "${GREEN}Processing VM: $name (ID: $id)...${NC}"

            # Grant X display access for IDV mode before attempting to start the VM
            local vm_display_mode
            vm_display_mode=$(get_vm_display_value "display_mode" "$id" "$xml_file")
            [[ -z "$vm_display_mode" ]] && vm_display_mode=$(xmllint --xpath \
                "string(//display_configurations/mode[1]/@name)" "$xml_file" 2>/dev/null || true)
            [[ -z "$vm_display_mode" ]] && vm_display_mode="idv"
            if [[ "${vm_display_mode,,}" == "idv" ]]; then
                grant_idv_display_access
            fi

            local domain_xml_dir
            domain_xml_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/vm-config"
            mkdir -p "${domain_xml_dir}"
            local domain_xml_file="${domain_xml_dir}/libvirt-domain-${name}.xml"

            if ! generate_domain_xml "$id" "$xml_file" "$net_mode" "$qemu_major_version" > "${domain_xml_file}"; then
                echo -e "${RED}Error: failed to generate domain XML for VM $name${NC}"
                exit 1
            fi

            echo -e "${BLUE}Generated domain XML: ${domain_xml_file}${NC}"
            if launch_vm_libvirt "${domain_xml_file}" "${name}" "${define_only}"; then
                [[ "$define_only" != "true" ]] && started_names+=("${name}")
            fi
        else
            echo -e "${YELLOW}Skipping VM ID $id: missing required fields${NC}"
        fi
    done

    # Optionally open virt-manager for interactive management
    if [[ "$open_virt_manager" == "true" ]]; then
        if command -v virt-manager &>/dev/null; then
            echo -e "${BLUE}Opening virt-manager...${NC}"
            virt-manager --connect "${LIBVIRT_URI}" &
        else
            echo -e "${YELLOW}virt-manager not found. Install: sudo apt-get install virt-manager${NC}"
        fi
    fi

    if [[ ${#started_names[@]} -gt 0 ]]; then
        echo -e "${GREEN}All domains started and managed by libvirt: ${started_names[*]}${NC}"
        echo -e "${BLUE}VMs will continue running after this script exits.${NC}"
        echo -e "${BLUE}Use 'virsh -c ${LIBVIRT_URI} list' to check status.${NC}"
        echo -e "${BLUE}Use 'virsh -c ${LIBVIRT_URI} destroy <name>' to stop a VM.${NC}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
