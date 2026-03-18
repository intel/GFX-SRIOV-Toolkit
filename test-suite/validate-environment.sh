#!/bin/bash
# SRIOV System Health Check Script (Shell)
# Performs health checks on Linux/Ubuntu systems for GPU, graphics and SRIOV components

set -u

PASSED=0
FAILED=0
SKIPPED=0

is_guest_environment() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if systemd-detect-virt --quiet; then
            return 0
        fi
    fi

    if [[ -r /sys/class/dmi/id/product_name ]] && grep -Eiq 'kvm|qemu|virtual|vmware|virtualbox|hyper-v' /sys/class/dmi/id/product_name; then
        return 0
    fi

    if [[ -r /sys/class/dmi/id/sys_vendor ]] && grep -Eiq 'qemu|vmware|virtualbox|microsoft corporation' /sys/class/dmi/id/sys_vendor; then
        return 0
    fi

    local output
    output=$(run_cmd "lspci 2>/dev/null | grep -Eiq 'virtio|qemu|vmware|virtualbox|hyper-v' && echo guest" || true)
    if [[ "$output" == "guest" ]]; then
        return 0
    fi

    return 1
}

log_result() {
    local check_name="$1"
    local status="$2"
    local details="${3:-}"

    if [[ "$status" == "true" ]]; then
        printf '[PASS] %s' "$check_name"
        PASSED=$((PASSED + 1))
    else
        printf '[FAIL] %s' "$check_name"
        FAILED=$((FAILED + 1))
    fi

    if [[ -n "$details" ]]; then
        printf ' (%s)' "$details"
    fi
    printf '\n'
}

log_skip() {
    local check_name="$1"
    local details="${2:-}"
    printf '[SKIP] %s' "$check_name"
    SKIPPED=$((SKIPPED + 1))
    if [[ -n "$details" ]]; then
        printf ' (%s)' "$details"
    fi
    printf '\n'
}

run_cmd() {
    local cmd="$1"
    # Use timeout if available to match the Python script behavior
    if command -v timeout >/dev/null 2>&1; then
        timeout 5s bash -c "$cmd"
    else
        bash -c "$cmd"
    fi
}

check_i915_or_xe_driver() {
    local output
    output=$(run_cmd "lsmod" 2>/dev/null || true)

    if echo "$output" | grep -q "^i915"; then
        log_result "GPU Driver (i915/xe)" true "i915 loaded"
        return
    fi
    if echo "$output" | grep -q "^xe"; then
        log_result "GPU Driver (i915/xe)" true "xe loaded"
        return
    fi

    log_result "GPU Driver (i915/xe)" false "Neither i915 nor xe driver loaded"
}

check_gpu_execution_units() {
    local debugfs_path="/sys/kernel/debug/dri/0/gt0/sseu_status"
    if [[ -f "$debugfs_path" ]]; then
        local eu_total eu_per_ss
        eu_total=$(grep -E "Available EU Total" "$debugfs_path" | sed -E 's/[^0-9]*([0-9]+).*/\1/' || true)
        eu_per_ss=$(grep -E "Available EU Per Subslice" "$debugfs_path" | sed -E 's/[^0-9]*([0-9]+).*/\1/' || true)
        if [[ -n "$eu_total" && -n "$eu_per_ss" ]]; then
            log_result "GPU Execution Units" true "Available EU Total: ${eu_total}, Available EU Per Subslice: ${eu_per_ss}"
            return
        fi
    fi

    if ! command -v clinfo >/dev/null 2>&1; then
        run_cmd "sudo apt-get update >/dev/null 2>&1" || true
        run_cmd "sudo apt-get install -y clinfo >/dev/null 2>&1" || true
        if ! command -v clinfo >/dev/null 2>&1; then
            run_cmd "sudo apt-get install -y intel-opencl-icd >/dev/null 2>&1" || true
        fi
    fi

    local output
    output=$(run_cmd "clinfo 2>/dev/null | grep -i 'compute units'" || true)
    if [[ -n "$output" ]]; then
        local compute_units
        compute_units=$(echo "$output" | sed -E 's/.* ([0-9]+)$/\1/' | head -1)
        if [[ -n "$compute_units" ]]; then
            log_result "GPU Execution Units" true "Compute Units: ${compute_units}"
            return
        fi
    fi

    log_result "GPU Execution Units" false "Could not determine EU count"
}

check_dmc_firmware() {
    if is_guest_environment; then
        log_skip "DMC Firmware Version" "host-level firmware; not applicable in guest environment"
        return
    fi

    local dmc_path="/sys/kernel/debug/dri/0/i915_dmc_info"
    if [[ -f "$dmc_path" ]]; then
        local content
        content=$(cat "$dmc_path" 2>/dev/null || true)
        if echo "$content" | grep -qE "i915/.*_dmc_ver[0-9]+_[0-9]+\.bin"; then
            local version
            version=$(echo "$content" | sed -nE 's/.*_dmc_ver([0-9]+)_([0-9]+)\.bin.*/v\1.\2/p' | head -1)
            if [[ -n "$version" ]]; then
                log_result "DMC Firmware Version" true "$version"
                return
            fi
        fi

        if echo "$content" | grep -qi "i915" && echo "$content" | grep -qi "dmc"; then
            local filename
            filename=$(echo "$content" | sed -nE 's/.*i915\/([^[:space:]]+\.bin).*/\1/p' | head -1)
            if [[ -n "$filename" ]]; then
                log_result "DMC Firmware Version" true "DMC firmware (${filename})"
                return
            fi
        fi

        local version
        version=$(echo "$content" | sed -nE 's/.*fw_version:[[:space:]]*([0-9]+\.[0-9]+).*/\1/p' | head -1)
        if [[ -n "$version" ]]; then
            log_result "DMC Firmware Version" true "v${version}"
            return
        fi

        if echo "$content" | grep -qi "dmc"; then
            log_result "DMC Firmware Version" true "DMC firmware loaded"
            return
        fi
    fi

    local output
    output=$(run_cmd "dmesg | grep -i dmc" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        local version
        version=$(echo "$output" | sed -nE 's/.*\(v([0-9]+\.[0-9]+)\).*/\1/p' | head -1)
        if [[ -n "$version" ]]; then
            log_result "DMC Firmware Version" true "v${version}"
            return
        fi
        if echo "$output" | grep -qi "loaded"; then
            log_result "DMC Firmware Version" true "$(echo "$output" | head -1 | cut -c1-60)"
            return
        fi
    fi

    log_result "DMC Firmware Version" false "DMC info not available"
}

check_gpu_frequency() {
    if is_guest_environment; then
        log_skip "GPU Frequency" "host-level control; not applicable in guest environment"
        return
    fi

    local min_freq cur_freq max_freq

    min_freq=$(run_cmd "cat /sys/class/drm/card0/gt_min_freq_mhz 2>/dev/null" || true)
    cur_freq=$(run_cmd "cat /sys/class/drm/card0/gt_cur_freq_mhz 2>/dev/null" || true)
    max_freq=$(run_cmd "cat /sys/class/drm/card0/gt_max_freq_mhz 2>/dev/null" || true)

    if [[ "$min_freq" =~ ^[0-9]+$ && "$cur_freq" =~ ^[0-9]+$ && "$max_freq" =~ ^[0-9]+$ ]]; then
        log_result "GPU Frequency" true "min: ${min_freq} MHz, cur: ${cur_freq} MHz, max: ${max_freq} MHz"
        return
    fi

    # Dynamic discovery - avoid hardcoded PCI address
    local freq_base
    for freq_base in /sys/devices/pci*/*/*/tile0/gt0/freq0; do
        [[ -f "${freq_base}/min_freq" ]] || continue
        min_freq=$(cat "${freq_base}/min_freq" 2>/dev/null || true)
        cur_freq=$(cat "${freq_base}/cur_freq" 2>/dev/null || true)
        max_freq=$(cat "${freq_base}/max_freq" 2>/dev/null || true)
        if [[ "$min_freq" =~ ^[0-9]+$ && "$cur_freq" =~ ^[0-9]+$ && "$max_freq" =~ ^[0-9]+$ ]]; then
            log_result "GPU Frequency" true "min: ${min_freq} MHz, cur: ${cur_freq} MHz, max: ${max_freq} MHz"
            return
        fi
    done

    if [[ -f "/sys/kernel/debug/dri/0/i915_rps_boost" ]]; then
        log_result "GPU Frequency" true "GPU frequency available"
        return
    fi

    local output
    output=$(run_cmd "lspci | grep -i vga" 2>/dev/null || true)
    if [[ -n "$output" && "$output" == *"Intel"* ]]; then
        log_result "GPU Frequency" true "Intel GPU detected"
        return
    fi

    log_result "GPU Frequency" false "Could not determine GPU frequency"
}

check_mesa_version() {
    local output
    output=$(DISPLAY=:0 run_cmd "glxinfo 2>&1 | grep -i 'OpenGL version'" 2>/dev/null || true)
    if [[ -n "$output" && "$output" == *"OpenGL"* ]]; then
        log_result "MESA Loaded" true "$(echo "$output" | head -1 | cut -c1-60)"
        return
    fi

    output=$(run_cmd "pkg-config --modversion mesa" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "MESA Loaded" true "MESA v${output}"
        return
    fi

    output=$(run_cmd "ldconfig -p | grep -i mesa" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "MESA Loaded" true "MESA libraries found"
        return
    fi

    output=$(run_cmd "ldconfig -p | grep -i 'libGL.so'" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "MESA Loaded" true "OpenGL library found"
        return
    fi

    output=$(run_cmd "dpkg -l 2>/dev/null | grep -i mesa" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "MESA Loaded" true "MESA package installed"
        return
    fi

    log_result "MESA Loaded" false "MESA not detected"
}

check_ihd_loaded() {
    local output
    output=$(run_cmd "ldconfig -p | grep -i 'igc\|igdrcl'" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "iHD Driver Loaded" true "iHD driver libraries found"
        return
    fi

    local igc_paths=(
        "/usr/lib/libigc.so"
        "/usr/lib/x86_64-linux-gnu/libigc.so"
        "/usr/local/lib/libigc.so"
    )
    local path
    for path in "${igc_paths[@]}"; do
        if [[ -f "$path" ]]; then
            log_result "iHD Driver Loaded" true "Found at ${path}"
            return
        fi
    done

    output=$(run_cmd "glxinfo | grep -i vendor" 2>/dev/null || true)
    if [[ -n "$output" && "$output" == *"Intel"* ]]; then
        log_result "iHD Driver Loaded" true "Intel driver detected"
        return
    fi

    log_result "iHD Driver Loaded" false "iHD driver not detected"
}

check_sriov_supported() {
    # sriov_totalvfs is readable without root and directly indicates HW SR-IOV capability.
    local pci_slots=() slot
    while IFS= read -r line; do
        slot="${line%% *}"
        [[ -n "$slot" ]] && pci_slots+=("$slot")
    done < <(lspci 2>/dev/null | grep -i 'VGA compatible controller' | grep -i 'Intel')

    for slot in "${pci_slots[@]}"; do
        [[ "$slot" =~ ^[0-9a-fA-F]{4}: ]] || slot="0000:${slot}"
        local tvfs_path="/sys/bus/pci/devices/${slot}/sriov_totalvfs"
        if [[ -f "$tvfs_path" ]]; then
            local totalvfs
            totalvfs=$(cat "$tvfs_path" 2>/dev/null || echo 0)
            if [[ "$totalvfs" =~ ^[0-9]+$ && "$totalvfs" -gt 0 ]]; then
                log_result "SRIOV Supported" true "SR-IOV capable: max ${totalvfs} VFs (${slot})"
                return
            fi
        fi
    done

    # debugfs paths (require root)
    local sriov_paths=(
        "/sys/kernel/debug/dri/0/i915_sriov_info"
        "/sys/kernel/debug/dri/0/sriov_info"
    )
    local path
    for path in "${sriov_paths[@]}"; do
        if [[ -f "$path" ]]; then
            if grep -qi "supported: yes" "$path"; then
                log_result "SRIOV Supported" true "SR-IOV supported"
                return
            fi
        fi
    done

    local output
    output=$(run_cmd "lspci -v | grep -i 'SR-IOV'" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "SRIOV Supported" true "SR-IOV capability detected"
        return
    fi

    output=$(run_cmd "cat /proc/cmdline | grep -i sriov" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "SRIOV Supported" true "SR-IOV kernel parameter detected"
        return
    fi

    local fail_msg="SR-IOV support not detected"
    if is_guest_environment && [[ "$EUID" -ne 0 ]]; then
        fail_msg+="; rerun with sudo for complete check"
    fi
    log_result "SRIOV Supported" false "$fail_msg"
}

check_sriov_loaded() {
    if is_guest_environment; then
        log_skip "SRIOV Loaded" "host-level provisioning state; not applicable in guest environment"
        return
    fi

    # Dynamically discover all Intel GPU PCI slots
    local pci_slots=()
    local slot
    while IFS= read -r line; do
        slot="${line%% *}"
        [[ -n "$slot" ]] && pci_slots+=("$slot")
    done < <(lspci 2>/dev/null | grep -i 'VGA compatible controller' | grep -i 'Intel')

    # Normalise to full domain form (0000:BB:DD.F)
    local full_slots=()
    for slot in "${pci_slots[@]}"; do
        if [[ "$slot" =~ ^[0-9a-fA-F]{4}: ]]; then
            full_slots+=("$slot")
        else
            full_slots+=("0000:$slot")
        fi
    done

    local path numvfs
    for slot in "${full_slots[@]}"; do
        for path in \
            "/sys/bus/pci/devices/${slot}/sriov_numvfs" \
            "/sys/bus/pci/drivers/i915/${slot}/sriov_numvfs" \
            "/sys/bus/pci/drivers/xe/${slot}/sriov_numvfs"; do
            if [[ -f "$path" ]]; then
                numvfs=$(cat "$path" 2>/dev/null || echo 0)
                if [[ "$numvfs" =~ ^[0-9]+$ && "$numvfs" -gt 0 ]]; then
                    log_result "SRIOV Loaded" true "${numvfs} virtual functions active (${slot})"
                    return
                fi
            fi
        done
    done

    local vf_output
    vf_output=$(run_cmd "lspci | grep -i 'Virtual Function'" 2>/dev/null || true)
    if [[ -n "$vf_output" ]]; then
        log_result "SRIOV Loaded" true "Virtual functions detected via lspci"
        return
    fi

    # Emit diagnostic detail to help debug the failure.
    local diag="No active SR-IOV virtual functions"
    if [[ ${#full_slots[@]} -eq 0 ]]; then
        diag+="; no Intel GPU found via lspci"
    else
        local slots_str
        slots_str=$(printf '%s ' "${full_slots[@]}")
        diag+="; GPU slot(s): ${slots_str% }"
        # Report the numvfs value for each discovered slot to show current state.
        for slot in "${full_slots[@]}"; do
            local nv_path="/sys/bus/pci/devices/${slot}/sriov_numvfs"
            if [[ -f "$nv_path" ]]; then
                numvfs=$(cat "$nv_path" 2>/dev/null || echo "?")
                diag+="; ${slot} numvfs=${numvfs}"
            else
                diag+="; ${slot} sriov_numvfs not found (VFs not provisioned?)"
            fi
        done
    fi
    log_result "SRIOV Loaded" false "$diag"
}

check_iommu_loaded() {
    local output
    output=$(run_cmd "cat /proc/cmdline | grep -i iommu" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "IOMMU Loaded" true "IOMMU enabled in kernel parameters"
        return
    fi

    output=$(run_cmd "dmesg | grep -i 'IOMMU\|DMAR' | head -1" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "IOMMU Loaded" true "IOMMU/DMAR support detected"
        return
    fi

    if [[ -d "/sys/class/iommu" ]] && find /sys/class/iommu -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .; then
        log_result "IOMMU Loaded" true "IOMMU devices found"
        return
    fi

    output=$(run_cmd "lsmod | grep -i vfio" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "IOMMU Loaded" true "VFIO module loaded (requires IOMMU)"
        return
    fi

    local fail_msg="IOMMU not detected"
    if is_guest_environment && [[ "$EUID" -ne 0 ]]; then
        fail_msg+="; rerun with sudo for complete check"
    fi
    log_result "IOMMU Loaded" false "$fail_msg"
}

check_vtd_enabled() {
    # NOTE: VT-D is a host-level feature for physical I/O virtualization.
    # Guest VMs don't need VT-D—the host manages physical I/O.
    # Skip this check in guest environments since it's not applicable.

    if is_guest_environment; then
        log_skip "VT-D Enabled" "host-level feature; not applicable in guest environment"
        return
    fi

    # NOTE: 'vmx' in /proc/cpuinfo flags is VT-x (CPU virtualization), NOT VT-d (I/O virtualization).
    # VT-d is confirmed by the ACPI DMAR table, kernel cmdline, or dmesg.

    # Primary: ACPI DMAR table presence confirms VT-d hardware support
    if [[ -f "/sys/firmware/acpi/tables/DMAR" ]]; then
        log_result "VT-D Enabled" true "DMAR ACPI table present"
        return
    fi

    local output
    output=$(run_cmd "cat /proc/cmdline | grep -i 'intel_iommu'" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "VT-D Enabled" true "Intel IOMMU enabled"
        return
    fi

    output=$(run_cmd "dmesg | grep -i 'vt-d\|vtd\|directed i/o' | head -1" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "VT-D Enabled" true "VT-D detected in kernel messages"
        return
    fi

    output=$(run_cmd "dmesg | grep -i 'DMAR' | head -1" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "VT-D Enabled" true "VT-D support detected"
        return
    fi

    log_result "VT-D Enabled" false "VT-D not detected"
}

check_opencl_initialized() {
    if ! command -v clinfo >/dev/null 2>&1; then
        run_cmd "sudo apt-get update >/dev/null 2>&1" || true
        run_cmd "sudo apt-get install -y clinfo >/dev/null 2>&1" || true
        if ! command -v clinfo >/dev/null 2>&1; then
            run_cmd "sudo apt-get install -y intel-opencl-icd >/dev/null 2>&1" || true
        fi
    fi

    local output
    output=$(run_cmd "clinfo 2>/dev/null | head -1" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "OpenCL Initialized" true "OpenCL devices detected"
        return
    fi

    output=$(run_cmd "pkg-config --modversion OpenCL" 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        log_result "OpenCL Initialized" true "OpenCL v${output}"
        return
    fi

    if [[ -d "/etc/OpenCL/vendors" || -f "/usr/lib/x86_64-linux-gnu/libOpenCL.so" || -f "/usr/lib/libOpenCL.so" ]]; then
        log_result "OpenCL Initialized" true "OpenCL ICD found"
        return
    fi

    log_result "OpenCL Initialized" false "OpenCL not detected"
}

check_sriov_kparams() {
    if is_guest_environment; then
        log_skip "SR-IOV Kernel Params" "host-level configuration; check on host system"
        return
    fi

    local cmdline
    cmdline=$(cat /proc/cmdline 2>/dev/null || true)
    local missing=() found=() info=()

    # intel_iommu=on and iommu=pt improve isolation but are not strictly required
    # on all platforms (can be firmware-enabled). Report as informational.
    if echo "$cmdline" | grep -q 'intel_iommu=on'; then
        info+=("intel_iommu=on")
    fi
    if echo "$cmdline" | grep -qE '(^| )iommu=pt( |$)'; then
        info+=("iommu=pt")
    fi

    # Detect active GPU driver: xe takes precedence when i915 is blacklisted or xe module is loaded.
    local active_driver="unknown"
    if lsmod 2>/dev/null | grep -q "^xe"; then
        active_driver="xe"
    elif lsmod 2>/dev/null | grep -q "^i915"; then
        active_driver="i915"
    elif echo "$cmdline" | grep -q 'modprobe.blacklist=i915'; then
        active_driver="xe"
    fi

    case "$active_driver" in
        xe)
            # xe driver: SR-IOV enabled via xe.max_vfs=<n> (n > 0)
            local max_vfs_val
            max_vfs_val=$(echo "$cmdline" | grep -oE 'xe\.max_vfs=[0-9]+' | cut -d= -f2)
            if [[ -n "$max_vfs_val" && "$max_vfs_val" -gt 0 ]]; then
                found+=("xe.max_vfs=${max_vfs_val}")
            else
                missing+=("xe.max_vfs (must be >0 for xe SR-IOV)")
            fi
            ;;
        i915)
            # i915 driver: SR-IOV requires enable_guc>=3 AND max_vfs>0
            if echo "$cmdline" | grep -qE 'i915\.enable_guc=[3-9]([^0-9]|$)|i915\.enable_guc=[1-9][0-9]'; then
                local guc_val
                guc_val=$(echo "$cmdline" | grep -oE 'i915\.enable_guc=[0-9]+' | cut -d= -f2)
                found+=("i915.enable_guc=${guc_val}")
            else
                missing+=("i915.enable_guc (SR-IOV requires >=3)")
            fi
            local i915_vfs_val
            i915_vfs_val=$(echo "$cmdline" | grep -oE 'i915\.max_vfs=[0-9]+' | cut -d= -f2)
            if [[ -n "$i915_vfs_val" && "$i915_vfs_val" -gt 0 ]]; then
                found+=("i915.max_vfs=${i915_vfs_val}")
            else
                missing+=("i915.max_vfs (must be >0 for i915 SR-IOV)")
            fi
            ;;
        *)
            missing+=("SR-IOV driver param (could not detect xe or i915)")
            ;;
    esac

    local detail="[driver: ${active_driver}]"
    [[ ${#found[@]} -gt 0 ]] && detail="$(IFS=', '; echo "${found[*]}") ${detail}"
    [[ ${#info[@]} -gt 0 ]] && detail+=" (also set: $(IFS=', '; echo "${info[*]}"))"

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_result "SR-IOV Kernel Params" true "$detail"
    else
        log_result "SR-IOV Kernel Params" false "Missing: $(IFS=', '; echo "${missing[*]}") — ${detail}"
    fi
}

check_guc_firmware() {
    # GuC firmware is required for SR-IOV on Intel GPUs.
    local output
    output=$(run_cmd "dmesg | grep -iE 'guc.*firmware|firmware.*guc' | tail -5" 2>/dev/null || true)

    if echo "$output" | grep -qiE 'fetch success|load success|running|preloaded'; then
        local ver
        ver=$(echo "$output" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
        if echo "$output" | grep -qi 'preloaded'; then
            log_result "GuC Firmware" true "${ver:-PRELOADED}"
        else
            log_result "GuC Firmware" true "${ver:-loaded}"
        fi
        return
    fi

    if echo "$output" | grep -qiE 'fail|error'; then
        local reason
        reason=$(echo "$output" | grep -iE 'fail|error' | tail -1 | sed 's/^.*\] //' | cut -c1-70)
        log_result "GuC Firmware" false "load failed: ${reason}"
        return
    fi

    # debugfs fallback (requires root)
    local guc_info
    for guc_info in /sys/kernel/debug/dri/*/gt*/uc/guc_info; do
        [[ -f "$guc_info" ]] || continue
        local content
        content=$(cat "$guc_info" 2>/dev/null || true)
        if echo "$content" | grep -qiE 'status.*RUNNING|fw_status.*RUNNING|status.*PRELOADED|fw_status.*PRELOADED'; then
            if echo "$content" | grep -qiE 'status.*PRELOADED|fw_status.*PRELOADED'; then
                log_result "GuC Firmware" true "GuC PRELOADED"
            else
                log_result "GuC Firmware" true "GuC running"
            fi
            return
        fi
    done

    if [[ "$EUID" -ne 0 && ! -r "/sys/kernel/debug/dri" ]]; then
        log_skip "GuC Firmware" "debugfs requires root; rerun with sudo for full check"
        return
    fi

    log_result "GuC Firmware" false "GuC firmware status unknown"
}

check_kvm_loaded() {
    if is_guest_environment; then
        log_skip "KVM Module" "host-level virtualization; not applicable in guest environment"
        return
    fi

    local output
    output=$(run_cmd "lsmod" 2>/dev/null || true)

    if echo "$output" | grep -q "^kvm_intel"; then
        log_result "KVM Module" true "kvm_intel loaded"
        return
    fi
    if echo "$output" | grep -q "^kvm"; then
        log_result "KVM Module" true "kvm loaded"
        return
    fi

    if [[ -c "/dev/kvm" ]]; then
        log_result "KVM Module" true "/dev/kvm available"
        return
    fi

    log_result "KVM Module" false "KVM module not loaded"
}

run_all_checks() {
    local environment_type="Host"
    if is_guest_environment; then
        environment_type="Guest"
    fi

    printf '\n%s\n' "============================================================"
    printf 'SRIOV System Health Check\n'
    printf 'Environment: %s\n' "$environment_type"
    printf '%s\n\n' "============================================================"

    check_i915_or_xe_driver
    check_gpu_execution_units
    check_dmc_firmware
    check_gpu_frequency
    check_mesa_version
    check_ihd_loaded
    check_sriov_supported
    check_sriov_loaded
    check_sriov_kparams
    check_guc_firmware
    check_kvm_loaded
    check_iommu_loaded
    check_vtd_enabled
    check_opencl_initialized

    printf '\n%s\n' "============================================================"
    printf 'Summary: %d Passed, %d Failed, %d Skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
    printf '%s\n\n' "============================================================"

    if [[ $FAILED -eq 0 ]]; then
        return 0
    fi
    return 1
}

main() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        printf 'Error: This script is designed to run on Linux/Ubuntu systems\n'
        exit 1
    fi

    if [[ "$EUID" -ne 0 ]]; then
        printf 'Warning: Some checks may require root privileges for full results\n'
        printf 'Consider running with: sudo ./sriov_health_check.sh\n\n'
    fi

    run_all_checks
    exit $?
}

main "$@"

