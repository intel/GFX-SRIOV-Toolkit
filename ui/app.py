#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# VM Manager Web UI - Flask Backend

import os
import json
import subprocess
import threading
import time
import shlex
import socket
from flask import Flask, render_template, request, jsonify, Response
from datetime import datetime
import re

app = Flask(__name__)

# Configuration - Auto-detect libvirt-int path (parent directory of ui/)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LIBVIRT_INT_PATH = os.path.dirname(SCRIPT_DIR)  # Parent directory of ui/
PROVISION_SCRIPT = os.path.join(LIBVIRT_INT_PATH, "scripts", "provision-sriov.sh")
CREATE_VM_UBUNTU = os.path.join(LIBVIRT_INT_PATH, "scripts", "create-vm-ubuntu.sh")
CREATE_VM_WIN = os.path.join(LIBVIRT_INT_PATH, "scripts", "create-vm-win.sh")
LAUNCH_VM_QEMU = os.path.join(LIBVIRT_INT_PATH, "scripts", "launch-vm.sh")
# libvirt-based launches now go through launch-vm.sh --virsh (launch-vm-libvirt.sh was merged in)
LAUNCH_VM_LIBVIRT = LAUNCH_VM_QEMU
SETUP_LIBVIRT = os.path.join(LIBVIRT_INT_PATH, "scripts", "setup-libvirt.sh")
CLONE_VM_SCRIPT = os.path.join(LIBVIRT_INT_PATH, "scripts", "clone-vm.sh")
VM_CONFIG_MANAGER = os.path.join(LIBVIRT_INT_PATH, "scripts", "vm-config-manager.sh")
# Single source of truth for VM entries: vm-config-manager.sh's default config
# file, kept in sync automatically by create/delete scripts. CONFIG_XML is the
# name used across launch/advanced-save/config-defaults routes; MASTER_CONFIG_XML
# is the same file, used where the config-manager CLI semantics are relevant.
MASTER_CONFIG_XML = os.path.join(LIBVIRT_INT_PATH, "config", "vm-config", "vm-master-config.xml")
TEMPLATE_CONFIG_XML = os.path.join(LIBVIRT_INT_PATH, "config", "vm-config", "vm-master-config.xml.template")
CONFIG_XML        = MASTER_CONFIG_XML
VGPU_PROFILE_DIR  = os.path.join(LIBVIRT_INT_PATH, "config", "vgpu-profile")

# Global state for tracking operations
operations = {}
operation_id_counter = 0
operation_lock = threading.Lock()


def find_available_port(start_port, end_port):
    """Find an available port in the given range"""
    import socket
    for port in range(start_port, end_port + 1):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.bind(('', port))
                return port
        except OSError:
            continue
    return None


def get_next_operation_id():
    global operation_id_counter
    with operation_lock:
        operation_id_counter += 1
        return f"op_{operation_id_counter}"


def run_command_async(operation_id, command, description):
    """Run a command asynchronously and track output"""
    operations[operation_id] = {
        'status': 'running',
        'description': description,
        'output': [],
        'start_time': datetime.now().isoformat(),
        'command': command
    }

    def execute():
        try:
            # Preserve X11 environment for GUI applications
            env = os.environ.copy()
            if 'DISPLAY' not in env:
                env['DISPLAY'] = ':0'
            if 'XAUTHORITY' not in env and os.path.exists(os.path.expanduser('~/.Xauthority')):
                env['XAUTHORITY'] = os.path.expanduser('~/.Xauthority')

            process = subprocess.Popen(
                command,
                shell=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env=env
            )

            for line in iter(process.stdout.readline, ''):
                if line:
                    operations[operation_id]['output'].append(line.rstrip())

            process.wait()

            operations[operation_id]['status'] = 'completed' if process.returncode == 0 else 'failed'
            operations[operation_id]['return_code'] = process.returncode
            operations[operation_id]['end_time'] = datetime.now().isoformat()

        except Exception as e:
            operations[operation_id]['status'] = 'error'
            operations[operation_id]['output'].append(f"Error: {str(e)}")
            operations[operation_id]['end_time'] = datetime.now().isoformat()

    thread = threading.Thread(target=execute)
    thread.daemon = True
    thread.start()

    return operation_id


# Hard ceiling on VFs across all supported GPUs (dGPU/BMG: 24, iGPU: 7).
# The per-profile limit is applied in the UI; this is the backend backstop.
MAX_NUM_VFS = 24


def validate_num_vfs(raw):
    """Coerce a requested VF count to an int within 1..MAX_NUM_VFS.

    Returns (num_vfs, None) on success or (None, error_message) on failure.
    Also keeps non-numeric input out of the provisioning shell command.
    """
    try:
        num_vfs = int(str(raw).strip())
    except (TypeError, ValueError):
        return None, f'Invalid number of VFs: {raw!r}. Enter a whole number between 1 and {MAX_NUM_VFS}.'
    if num_vfs < 1 or num_vfs > MAX_NUM_VFS:
        return None, f'Number of VFs must be between 1 and {MAX_NUM_VFS} (got {num_vfs}).'
    return num_vfs, None


def read_profile_tiers(xml_path):
    """List the <vGPUResources><Profile> tiers declared in a vGPU profile XML.

    Each entry is {'name', 'vf_count', 'selector'}. `selector` is the value the
    user types in the UI to pick that tier: for tiers named <prefix>_<n> (e.g.
    Bmg_24) it is the numeric suffix, otherwise it is the VFCount itself.

    The BMG suffix is LMEM GiB per VF, not a VF count, and it runs opposite to
    VFCount (Bmg_24 = 1 VF x 20 GiB ... Bmg_6 = 4 VFs x 5 GiB), so the selector
    and the number of VFs actually provisioned are deliberately distinct.
    """
    import xml.etree.ElementTree as ET
    tiers = []
    try:
        root = ET.parse(xml_path).getroot()
    except Exception:
        return tiers
    for el in (root.find('.//vGPUResources/Profile') or []):
        raw_vf = (el.findtext('VFCount') or '').strip()
        if not raw_vf.isdigit():
            continue
        vf_count = int(raw_vf)
        suffix = el.tag.rsplit('_', 1)[-1] if '_' in el.tag else ''
        selector = int(suffix) if suffix.isdigit() else vf_count
        tiers.append({'name': el.tag, 'vf_count': vf_count, 'selector': selector})
    return tiers


def resolve_profile_tier(xml_path, requested):
    """Map a user-entered value to a tier in `xml_path`.

    Returns (tier, None) or (None, error_message). A selector match wins over a
    VFCount match so that on BMG "24" resolves to Bmg_24 (1 VF x 20 GiB) rather
    than being rejected; iGPU profiles name tiers igpu_profile_<n> where the
    suffix equals VFCount, so both keys agree and the behaviour is unchanged.
    """
    tiers = read_profile_tiers(xml_path)
    if not tiers:
        return None, (f'No vGPU resource tiers found in {os.path.basename(xml_path)}. '
                      'The profile XML may be malformed.')

    for key in ('selector', 'vf_count'):
        for tier in tiers:
            if tier[key] == requested:
                return tier, None

    allowed = sorted({t['selector'] for t in tiers} | {t['vf_count'] for t in tiers})
    detail = ', '.join(f"{t['selector']} ({t['name']} -> {t['vf_count']} VF"
                       f"{'s' if t['vf_count'] != 1 else ''})" for t in tiers)
    return None, (f'{requested} is not defined in {os.path.basename(xml_path)}. '
                  f'Defined values: {", ".join(str(a) for a in allowed)}. '
                  f'Tiers: {detail}.')


def check_sriov_status():
    """Check if SR-IOV is currently enabled"""
    try:
        # Check for Intel GPU
        result = subprocess.run(
            "ls /sys/bus/pci/devices/*/sriov_numvfs 2>/dev/null | head -1",
            shell=True,
            capture_output=True,
            text=True
        )

        if result.stdout.strip():
            sriov_file = result.stdout.strip()
            with open(sriov_file, 'r') as f:
                num_vfs = int(f.read().strip())
                return {
                    'enabled': num_vfs > 0,
                    'num_vfs': num_vfs,
                    'device': sriov_file.split('/')[5]
                }

        return {'enabled': False, 'num_vfs': 0}
    except Exception as e:
        return {'enabled': False, 'error': str(e)}


def sriov_not_provisioned_response(action='starting a VM'):
    """Return a 409 response if SR-IOV has no active VFs, else None.

    A VM is created and launched with a GPU Virtual Function passed through.
    Without one, QEMU gets an empty vfio-pci device and exits immediately, so
    callers must refuse up front instead of reporting a successful operation.
    """
    status = check_sriov_status()
    if not status.get('enabled'):
        return jsonify({
            'success': False,
            'error': ('SR-IOV is not provisioned. No GPU Virtual Function is '
                      f'available to pass through to the VM. Provision Virtual '
                      f'Functions first (SR-IOV settings -> Provision SR-IOV) '
                      f'before {action}.'),
            'sriov_provisioned': False,
        }), 409
    return None


def get_os_type_map():
    """Map VM name -> os_type from the master XML config."""
    import xml.etree.ElementTree as ET
    os_types = {}
    try:
        tree = ET.parse(CONFIG_XML)
        root = tree.getroot()
        for vm_el in root.findall('.//vm'):
            name_el = vm_el.find('name')
            os_el = vm_el.find('os_type')
            if name_el is not None and name_el.text:
                name = name_el.text.strip()
                os_types[name] = (os_el.text.strip() if os_el is not None and os_el.text else '')
    except Exception as e:
        print(f"Error reading os_type map: {e}")
    return os_types


def guess_os_type(vm_name):
    """Best-effort OS guess from the VM's name, used only as a fallback for
    VMs not yet tracked in the master config (e.g. discovered purely via a
    running process or disk image) so the UI doesn't show a blank OS type."""
    lname = (vm_name or '').lower()
    if 'win' in lname:
        return 'windows'
    if 'ubuntu' in lname or 'linux' in lname:
        return 'ubuntu'
    return ''



# Fields accepted by `vm-config-manager.sh update-vm`, mirrored here so the UI
# can validate before shelling out (the script rejects unknown fields anyway).
CONFIG_MANAGER_FIELDS = (
    'name', 'os_type', 'memory', 'cpu_cores', 'cpu_threads',
    'mac_address', 'disk_path', 'ssh_port', 'monitor_port', 'description',
)

# Fields that may legitimately be saved as empty, i.e. where clearing the input
# means "erase this" rather than "leave it alone". Everything else in
# CONFIG_MANAGER_FIELDS is required for a VM to launch at all.
CLEARABLE_CONFIG_FIELDS = ('description',)


def run_config_manager(args, timeout=30):
    """Run vm-config-manager.sh with an argv list (no shell) and capture output.

    Returns (returncode, stdout, stderr). Using an argv list instead of
    shell=True keeps user-supplied values (names, descriptions, paths) out of
    a shell interpreter entirely, avoiding command injection.
    """
    cmd = ['bash', VM_CONFIG_MANAGER] + [str(a) for a in args]
    # Pass the config/template paths explicitly rather than relying on the
    # script's own BASH_SOURCE-relative lookup, which depends on the caller's
    # cwd -- keeps this correct regardless of where the Flask process is run from.
    env = os.environ.copy()
    env['CONFIG_FILE'] = MASTER_CONFIG_XML
    env['TEMPLATE_FILE'] = TEMPLATE_CONFIG_XML
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        return 1, '', 'vm-config-manager.sh command timed out'
    except Exception as e:
        return 1, '', str(e)


def ensure_master_config_ready():
    """Run `vm-config-manager.sh init-config` (no-op if the file already exists).

    Discovers pre-existing libvirt domains, QEMU processes, and disk images so
    they show up in the UI without a manual step. Best-effort: failures are
    logged but never block the page from loading.
    """
    rc, out, err = run_config_manager(['init-config'])
    if rc != 0:
        print(f"Warning: vm-config-manager.sh init-config failed: {err or out}")


def get_master_config_vms():
    """Parse the master VM config XML into a list of plain dicts."""
    import xml.etree.ElementTree as ET
    vms = []
    if not os.path.exists(MASTER_CONFIG_XML):
        return vms
    try:
        root = ET.parse(MASTER_CONFIG_XML).getroot()
        for vm_el in root.findall('.//virtual_machines/vm'):
            vm = {'id': vm_el.get('id', '')}
            for tag in ('name', 'os_type', 'memory_size', 'cpu_cores', 'cpu_threads',
                        'mac_address', 'disk_path', 'ssh_port', 'monitor_port', 'description'):
                el = vm_el.find(tag)
                vm[tag] = (el.text or '').strip() if el is not None and el.text else ''
            vms.append(vm)
    except Exception as e:
        print(f"Error parsing master config: {e}")
    return vms


# launch-vm.sh emits `-spice addr=<ip>,port=<n>,...` and pairs it with a
# -display mode; both are parsed off the live command line so the UI reports
# how a VM is *actually* running rather than what its XML asked for.
QEMU_SPICE_RE = re.compile(r'-spice\s+\S*?\bport=(\d+)')
QEMU_DISPLAY_RE = re.compile(r'-display\s+(\S+)')


def get_qemu_display_mode(cmdline):
    """Identify how a running QEMU VM presents its display.

    Mirrors the three modes launch-vm.sh builds:
      idv       -> -display gtk,...        (no -spice)
      spice     -> -display egl-headless   + -spice
      spice-gtk -> -display none           + -spice

    Returns (mode, spice_port) with spice_port None outside the SPICE modes.
    """
    spice = QEMU_SPICE_RE.search(cmdline)
    if not spice:
        return 'idv', None

    display = QEMU_DISPLAY_RE.search(cmdline)
    kind = display.group(1) if display else ''
    if kind.startswith('none'):
        return 'spice-gtk', spice.group(1)
    # egl-headless is plain SPICE; anything else still has a SPICE server
    # attached, so report it as SPICE rather than guessing a new mode name.
    return 'spice', spice.group(1)


def get_libvirt_display_mode(cmdline):
    """SPICE detection for a libvirt domain's QEMU process.

    libvirt builds its own -display/-spice arguments, so the idv/spice-gtk
    split get_qemu_display_mode() draws from launch-vm.sh doesn't apply here --
    a libvirt SPICE domain also runs with `-display none` and would be
    mislabelled spice-gtk. Only report whether a SPICE server is attached.
    """
    spice = QEMU_SPICE_RE.search(cmdline)
    return ('spice', spice.group(1)) if spice else (None, None)


def get_vm_list():
    """Get list of VMs (both QEMU and libvirt, running or stopped)"""
    vms = []
    seen_names = set()
    os_type_map = get_os_type_map()
    # display_mode/spice_port for libvirt domains, harvested from their QEMU
    # child processes in the scan below and consumed by the libvirt block.
    libvirt_display = {}

    # Check QEMU VMs (running only)
    try:
        result = subprocess.run(
            "ps aux | grep qemu-system-x86_64 | grep -v grep",
            shell=True,
            capture_output=True,
            text=True,
            timeout=5
        )

        for line in result.stdout.split('\n'):
            if line and 'qemu-system-x86_64' in line:
                pid = line.split()[1]

                # libvirt always launches its qemu child as
                # `-name guest=<name>,debug-threads=on`. Skip these here so
                # they aren't double-counted; the libvirt block below reports
                # them once, with the correct name and domain state. Its
                # display mode is only visible on this command line, though,
                # so grab that on the way past.
                if re.search(r'-name\s+guest=', line):
                    guest_match = re.search(r'-name\s+guest=([^,\s]+)', line)
                    if guest_match:
                        libvirt_display[guest_match.group(1)] = get_libvirt_display_mode(line)
                    continue

                # Try to extract VM name from command line. launch-vm.sh (like
                # libvirt) appends ",debug-threads=on" to -name, so stop at the
                # comma -- otherwise vm_name picks up ",debug-threads=on" and
                # no longer matches the VM's real name, showing up as a
                # duplicate sidebar entry instead of updating the real one.
                match = re.search(r'-name\s+([^,\s]+)', line)
                if match:
                    vm_name = match.group(1)
                else:
                    # Try to extract from disk image name
                    disk_match = re.search(r'file=([^\s,]+\.(?:img|qcow2))', line)
                    if disk_match:
                        disk_path = disk_match.group(1)
                        vm_name = os.path.basename(disk_path).replace('.img', '').replace('.qcow2', '')
                    else:
                        # Use PID as identifier for truly unknown VMs
                        vm_name = f"qemu-{pid}"

                # A live QEMU process can still be paused (HMP `stop`), which
                # `ps` can't tell us -- ask the monitor so the UI can offer
                # Resume instead of Pause. No monitor port means no way to
                # pause it in the first place, so 'running' is correct there.
                port_match = QEMU_MONITOR_RE.search(line)
                monitor_port = port_match.group(1) if port_match else None
                status = get_qemu_run_state(monitor_port) if monitor_port else 'running'

                display_mode, spice_port = get_qemu_display_mode(line)

                # Only add if not already seen
                if vm_name not in seen_names:
                    vms.append({
                        'name': vm_name,
                        'type': 'qemu',
                        'pid': pid,
                        'monitor_port': monitor_port,
                        'display_mode': display_mode,
                        'spice_port': spice_port,
                        'status': status
                    })
                    seen_names.add(vm_name)
    except Exception as e:
        # Log error but continue
        print(f"Error checking QEMU VMs: {e}")

    # Check libvirt VMs (all - running and stopped)
    try:
        # Use --name flag to get just names, which is more reliable
        result = subprocess.run(
            "virsh --connect qemu:///system list --all --name 2>/dev/null",
            shell=True,
            capture_output=True,
            text=True,
            timeout=5
        )

        # Get names first
        vm_names = [name.strip() for name in result.stdout.split('\n') if name.strip()]

        # Get detailed info for each VM
        for vm_name in vm_names:
            # Skip domains already reported as a running QEMU process above,
            # otherwise the same VM shows up twice (once running, once as a
            # separate "shut off" libvirt entry) in the sidebar.
            if vm_name in seen_names:
                continue
            try:
                # Get state
                state_result = subprocess.run(
                    f"virsh --connect qemu:///system domstate {vm_name} 2>/dev/null",
                    shell=True,
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                state = state_result.stdout.strip() if state_result.returncode == 0 else 'unknown'

                # Get domain ID if running
                id_result = subprocess.run(
                    f"virsh --connect qemu:///system domid {vm_name} 2>/dev/null",
                    shell=True,
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                vm_id = id_result.stdout.strip() if id_result.returncode == 0 else '-'

                display_mode, spice_port = libvirt_display.get(vm_name, (None, None))

                vms.append({
                    'name': vm_name,
                    'type': 'libvirt',
                    'id': vm_id,
                    'display_mode': display_mode,
                    'spice_port': spice_port,
                    'status': state
                })
                seen_names.add(vm_name)
            except Exception as e:
                print(f"Error getting details for VM {vm_name}: {e}")
                # Add with minimal info
                vms.append({
                    'name': vm_name,
                    'type': 'libvirt',
                    'id': '-',
                    'status': 'unknown'
                })
                seen_names.add(vm_name)

    except Exception as e:
        print(f"Error checking libvirt VMs: {e}")

    # Check for VM disk images that exist but aren't tracked
    try:
        vm_dirs = ['/data/vm-images', '/home/user']
        for vm_dir in vm_dirs:
            if os.path.exists(vm_dir):
                result = subprocess.run(
                    f"find {vm_dir} -maxdepth 2 -type f \\( -name '*.img' -o -name '*.qcow2' \\) 2>/dev/null",
                    shell=True,
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                for disk_path in result.stdout.split('\n'):
                    if disk_path.strip():
                        disk_name = os.path.basename(disk_path).replace('.img', '').replace('.qcow2', '')
                        # Skip common installer/base images
                        if 'installer' in disk_name.lower() or 'base' in disk_name.lower():
                            continue
                        # Only add if not already tracked
                        if disk_name not in seen_names:
                            vms.append({
                                'name': disk_name,
                                'type': 'disk-image',
                                'pid': None,
                                'id': '-',
                                'status': 'stopped (disk image exists)'
                            })
                            seen_names.add(disk_name)
    except Exception as e:
        print(f"Error checking disk images: {e}")

    # Attach OS type (windows/ubuntu) from the master XML config, matched by
    # name; fall back to guessing from the name for VMs not tracked there yet.
    for vm in vms:
        vm['os_type'] = os_type_map.get(vm['name']) or guess_os_type(vm['name'])

    return vms


@app.route('/')
def index():
    """Serve the main UI page"""
    ensure_master_config_ready()
    return render_template('index.html')


@app.route('/api/system/memory')
def get_system_memory():
    """Lightweight endpoint: total + available system memory (MB)."""
    try:
        with open('/proc/meminfo') as f:
            fields = {}
            for line in f:
                if ':' in line:
                    key, val = line.split(':', 1)
                    parts = val.strip().split()
                    if parts and parts[0].isdigit():
                        fields[key.strip()] = int(parts[0])  # kB
        total_kb = fields.get('MemTotal', 0)
        avail_kb = fields.get('MemAvailable', fields.get('MemFree', 0))
        return jsonify({
            'total_mb': total_kb // 1024,
            'available_mb': avail_kb // 1024,
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/system-info')
def get_system_info():
    """Fetch system hardware and OS information"""
    import platform

    def read_sysfs(path, default='N/A'):
        try:
            with open(path) as f:
                return f.read().strip() or default
        except Exception:
            return default

    def run_cmd(cmd, default='N/A'):
        try:
            r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=6)
            return r.stdout.strip() or default
        except Exception:
            return default

    info = {}

    # Hostname & OS
    info['hostname'] = run_cmd('hostname', platform.node())
    os_name = 'N/A'
    try:
        with open('/etc/os-release') as f:
            for line in f:
                if line.startswith('PRETTY_NAME='):
                    os_name = line.split('=', 1)[1].strip().strip('"')
                    break
    except Exception:
        os_name = platform.version()
    info['os'] = os_name
    info['kernel'] = run_cmd('uname -r', platform.release())
    info['uptime'] = run_cmd("uptime -p", 'N/A')
    # head -1 because --version also prints a copyright line, and run_cmd
    # returns the whole of stdout. Falls back to 'N/A' when QEMU is absent,
    # which the UI's row() helper then omits entirely.
    info['qemu_version'] = run_cmd("qemu-system-x86_64 --version 2>/dev/null | head -1")

    # CPU — parse lscpu
    lscpu_out = run_cmd('lscpu')
    lscpu = {}
    for line in lscpu_out.splitlines():
        if ':' in line:
            k, v = line.split(':', 1)
            lscpu[k.strip()] = v.strip()

    info['cpu_model']           = lscpu.get('Model name', run_cmd("grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2").strip())
    info['cpu_architecture']    = lscpu.get('Architecture', 'N/A')
    info['cpu_sockets']         = lscpu.get('Socket(s)', '1')
    info['cpu_cores_per_socket']= lscpu.get('Core(s) per socket', 'N/A')
    info['cpu_threads_per_core']= lscpu.get('Thread(s) per core', 'N/A')
    info['cpu_total_threads']   = lscpu.get('CPU(s)', run_cmd('nproc'))
    info['cpu_freq_max_mhz']    = lscpu.get('CPU max MHz', lscpu.get('CPU MHz', 'N/A'))
    info['cpu_cache_l3']        = lscpu.get('L3 cache', 'N/A')
    info['cpu_virtualization']  = lscpu.get('Virtualization', 'N/A')

    # Memory
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                if line.startswith('MemTotal:'):
                    kb = int(line.split()[1])
                    info['ram_total'] = f"{kb / (1024*1024):.1f} GB ({kb // 1024} MB)"
                elif line.startswith('MemAvailable:'):
                    kb = int(line.split()[1])
                    info['ram_available'] = f"{kb / (1024*1024):.1f} GB"
    except Exception:
        info['ram_total'] = info['ram_available'] = 'N/A'

    # DMI / SKU (sysfs — no sudo needed)
    info['sys_vendor']      = read_sysfs('/sys/class/dmi/id/sys_vendor')
    info['product_name']    = read_sysfs('/sys/class/dmi/id/product_name')
    info['product_version'] = read_sysfs('/sys/class/dmi/id/product_version')
    info['product_sku']     = read_sysfs('/sys/class/dmi/id/product_sku')
    info['board_vendor']    = read_sysfs('/sys/class/dmi/id/board_vendor')
    info['board_name']      = read_sysfs('/sys/class/dmi/id/board_name')
    info['bios_version']    = read_sysfs('/sys/class/dmi/id/bios_version')
    info['bios_date']       = read_sysfs('/sys/class/dmi/id/bios_date')

    # GPU(s)
    gpu_raw = run_cmd("lspci | grep -iE 'VGA|Display|3D controller'")
    gpus = []
    if gpu_raw and gpu_raw != 'N/A':
        for ln in gpu_raw.splitlines():
            if ln:
                pci_addr = ln.split()[0] if ln.split() else ''
                device_name = ln.split(':', 2)[-1].strip()
                gpus.append({'pci': pci_addr, 'name': device_name})
    info['gpus'] = gpus

    # Total physical CPU cores (sockets × cores-per-socket)
    try:
        _sockets   = int(lscpu.get('Socket(s)', '1'))
        _cores_per = int(lscpu.get('Core(s) per socket', '1'))
        info['cpu_total_cores'] = str(_sockets * _cores_per)
    except Exception:
        info['cpu_total_cores'] = info.get('cpu_cores_per_socket', 'N/A')

    # GPU Execution Unit (EU) count — parsed from sysfs gt_info
    _eu_count = 'N/A'
    try:
        import glob as _glob
        for _gt_path in _glob.glob('/sys/class/drm/card*/gt_info'):
            with open(_gt_path) as _f:
                _content = _f.read()
            _eu_per, _subslice = None, None
            for _ln in _content.splitlines():
                _kv = _ln.split(':')
                if len(_kv) < 2:
                    continue
                _k, _v = _kv[0].strip().lower(), _kv[1].strip()
                if 'eu total' in _k or 'total eu' in _k:
                    _eu_count = _v
                    break
                if 'eu per subslice' in _k or 'eus per subslice' in _k:
                    _eu_per = int(_v) if _v.isdigit() else None
                if 'subslice count' in _k:
                    _subslice = int(_v) if _v.isdigit() else None
            if _eu_count != 'N/A':
                break
            if _eu_per and _subslice:
                _eu_count = str(_eu_per * _subslice)
                break
    except Exception:
        pass
    info['gpu_eu_count'] = _eu_count

    # Connected displays via xrandr --listmonitors
    _monitors, _monitors_raw = [], ''
    try:
        _env = os.environ.copy()
        if 'DISPLAY' not in _env:
            _env['DISPLAY'] = ':0'
        _xr = subprocess.run(
            'xrandr --listmonitors 2>/dev/null',
            shell=True, capture_output=True, text=True, timeout=5, env=_env
        )
        _monitors_raw = _xr.stdout.strip()
        for _line in _monitors_raw.splitlines():
            _line = _line.strip()
            if not _line or _line.lower().startswith('monitors:'):
                continue
            _parts = _line.split()
            if len(_parts) < 2:
                continue
            _display_name = _parts[-1]
            _res = ''
            for _p in _parts:
                if 'x' in _p and '/' in _p:
                    try:
                        _pw = _p.split('x')[0].split('+')[0].split('/')[0]
                        _ph = _p.split('x')[1].split('+')[0].split('/')[0]
                        _res = f"{_pw}x{_ph}"
                    except Exception:
                        pass
                    break
            _monitors.append({'name': _display_name, 'resolution': _res, 'primary': '*' in _line})
    except Exception:
        pass
    info['monitors'] = _monitors
    info['monitors_raw'] = _monitors_raw

    # Storage (root fs)
    df_out = run_cmd("df -h / | tail -1")
    if df_out and df_out != 'N/A':
        parts = df_out.split()
        if len(parts) >= 4:
            info['disk_total'] = parts[1]
            info['disk_used']  = parts[2]
            info['disk_free']  = parts[3]
            info['disk_use_pct'] = parts[4] if len(parts) > 4 else 'N/A'

    return jsonify(info)


@app.route('/api/grub-max-vfs')
def get_grub_max_vfs():
    """Read max_vfs value from xe.max_vfs or i915.max_vfs in /etc/default/grub"""
    import re as _re
    try:
        with open('/etc/default/grub') as f:
            content = f.read()
        m = _re.search(r'(?:xe|i915)\.max_vfs=(\d+)', content)
        if m:
            return jsonify({'max_vfs': int(m.group(1))})
    except Exception:
        pass
    return jsonify({'max_vfs': None})


@app.route('/api/status')
def get_status():
    """Get system status"""
    return jsonify({
        'sriov': check_sriov_status(),
        'vms': get_vm_list(),
        'timestamp': datetime.now().isoformat()
    })


@app.route('/api/sriov/profiles')
def get_sriov_profiles():
    """List available vGPU profile XMLs with their metadata"""
    import xml.etree.ElementTree as ET
    import glob
    results = []
    for xml_path in sorted(glob.glob(os.path.join(VGPU_PROFILE_DIR, '*.xml'))):
        fname = os.path.basename(xml_path)
        scheduling = {}
        try:
            root = ET.parse(xml_path).getroot()
            schedulers = [child.tag for child in (root.find('.//vGPUScheduler/Profile') or [])]
            default_sched = (root.findtext('.//vGPUScheduler/Default') or '').strip()
            vf_counts = sorted(set(
                int(el.text) for el in root.findall('.//vGPUResources/Profile/*/VFCount')
                if el.text and el.text.strip().isdigit()
            ))
            # Per-scheduler PF/VF scheduling parameters
            for sched_el in (root.find('.//vGPUScheduler/Profile') or []):
                ts = sched_el.find('GPUTimeSlicing')
                if ts is None:
                    continue
                vfs = {}
                for vf in ts.findall('VFAttributes/VF'):
                    count = vf.get('VFCount')
                    if count:
                        vfs[count] = {
                            'exec_quantum':    (vf.findtext('ExecutionQuantum') or '').strip(),
                            'preempt_timeout': (vf.findtext('PreemptionTimeout') or '').strip(),
                        }
                scheduling[sched_el.tag] = {
                    'pf_exec_quantum':    (ts.findtext('PFExecutionQuantum') or '').strip(),
                    'pf_preempt_timeout': (ts.findtext('PFPreemptionTimeout') or '').strip(),
                    'vfs': vfs,
                }
        except Exception:
            schedulers, default_sched, vf_counts = [], '', []
        # Resource tiers, so the UI can tell "not defined in XML" from a valid
        # selection without a provisioning round-trip.
        tiers = read_profile_tiers(xml_path)
        # Friendly label: strip .xml, replace - with space, title-case
        label = fname.replace('.xml', '').replace('-', ' ').replace('profile', '').strip().title()
        results.append({
            'file': fname,
            'path': xml_path,
            'label': label,
            'schedulers': schedulers,
            'default_scheduler': default_sched,
            'vf_counts': vf_counts,
            'tiers': tiers,
            'scheduling': scheduling,
        })
    return jsonify(results)


@app.route('/api/sriov/provision', methods=['POST'])
def provision_sriov():
    """Provision SR-IOV VFs"""
    import shlex
    data = request.json
    num_vfs    = data.get('num_vfs', 4)
    scheduler  = data.get('scheduler', '')
    ecc_mode   = data.get('ecc_mode', 'off')
    profile    = data.get('profile', '')   # path to vGPU profile XML

    num_vfs, err = validate_num_vfs(num_vfs)
    if err:
        return jsonify({'success': False, 'error': err}), 400

    # Resolve the requested value against the tiers the profile actually
    # declares. The script matches tiers by VFCount, so pass the tier's VFCount
    # rather than what the user typed -- on BMG "24" means the Bmg_24 tier,
    # which is 1 VF with 20 GiB of local memory.
    tier = None
    if profile and os.path.exists(profile):
        tier, err = resolve_profile_tier(profile, num_vfs)
        if err:
            return jsonify({'success': False, 'error': err, 'undefined_tier': True}), 400
        num_vfs = tier['vf_count']

    # Build command
    cmd = f"sudo {PROVISION_SCRIPT} -n {num_vfs}"
    if profile:
        cmd += f" -c {shlex.quote(profile)}"
    if scheduler:
        cmd += f" -s {shlex.quote(scheduler)}"
    if ecc_mode:
        cmd += f" -e {shlex.quote(ecc_mode)}"

    desc = f"Provisioning SR-IOV with {num_vfs} VFs"
    if tier:
        desc += f" (tier {tier['name']})"
    operation_id = run_command_async(get_next_operation_id(), cmd, desc)

    return jsonify({
        'success': True,
        'operation_id': operation_id,
        'tier': tier['name'] if tier else None,
        'num_vfs': num_vfs,
    })


@app.route('/api/sriov/disable', methods=['POST'])
def disable_sriov():
    """Disable SR-IOV"""
    cmd = f"sudo {PROVISION_SCRIPT} --disable"

    operation_id = run_command_async(
        get_next_operation_id(),
        cmd,
        "Disabling SR-IOV"
    )

    return jsonify({
        'success': True,
        'operation_id': operation_id
    })


@app.route('/api/vm/create', methods=['POST'])
def create_vm():
    """Create a new VM"""
    # The create scripts boot the installer with a GPU VF passed through, so
    # SR-IOV must already be provisioned.
    blocked = sriov_not_provisioned_response('creating a VM')
    if blocked:
        return blocked

    data = request.json
    os_type = data.get('os_type', 'ubuntu')
    vm_name = data.get('vm_name', 'vm-guest')
    disk_size = data.get('disk_size', '50G')
    memory = data.get('memory', '8192')
    cpus = data.get('cpus', '4')
    iso_path = data.get('iso_path', '')
    disk_format = data.get('disk_format', 'raw')
    proxy = data.get('proxy', '')

    # Build the appropriate command based on OS type
    if os_type == 'ubuntu':
        import shlex

        # The Ubuntu installer forwards a host port to the guest's sshd so the
        # script can drive the post-install setup. It used to be hardcoded to
        # 3333, so a second create failed while another was running -- and the
        # old pre-flight check rejected *Windows* creates too, which never use
        # this port at all. Allocate a free one per create instead.
        install_ssh_port = find_available_port(3333, 3399)
        if install_ssh_port is None:
            return jsonify({
                'success': False,
                'error': 'No free port in 3333-3399 for the installer SSH forward. '
                         'Wait for an in-progress VM creation to finish.'
            }), 409

        user_home = os.path.expanduser("~")
        xauth_file = f"{user_home}/.Xauthority"
        # Allow root to use the X display, then run the script with DISPLAY/XAUTHORITY
        # passed explicitly through sudo so the internal `sudo -E qemu-system-x86_64`
        # inside the script can open the GTK window.
        cmd  = "xhost +local:root > /dev/null 2>&1 || true && "
        cmd += f"sudo -E DISPLAY=:0 XAUTHORITY={shlex.quote(xauth_file)} {CREATE_VM_UBUNTU}"

        # Only add -i flag if ISO path is provided
        # If not provided, the script will auto-download from default URL
        if iso_path and iso_path.strip():
            # Validate that the provided ISO path exists
            if not os.path.exists(iso_path):
                return jsonify({'success': False, 'error': f'ISO file not found: {iso_path}'}), 400
            cmd += f" -i {shlex.quote(iso_path)}"
        # else: script will auto-download Ubuntu ISO from default URL

        cmd += f" -n {shlex.quote(vm_name)}"
        cmd += f" -s {shlex.quote(disk_size)}"
        cmd += f" -m {shlex.quote(str(memory))}"
        cmd += f" -c {shlex.quote(str(cpus))}"
        cmd += f" --install-ssh-port {install_ssh_port}"
        if disk_format == 'qcow2':
            cmd += " --qcow2"
        # Optional proxy pass-through for apt/downloads inside the guest
        if proxy and proxy.strip():
            cmd += f" --proxy {shlex.quote(proxy.strip())}"
    elif os_type == 'windows':
        import shlex
        # Windows script requires ISO path (does not support auto-download)
        if not iso_path or not iso_path.strip():
            return jsonify({'success': False, 'error': 'Windows ISO path is required'}), 400
        if not os.path.exists(iso_path):
            return jsonify({'success': False, 'error': f'ISO file not found: {iso_path}'}), 400

        user_home = os.path.expanduser("~")
        xauth_file = f"{user_home}/.Xauthority"
        # Use the create-vm-win.sh script instead of inline QEMU commands
        cmd  = "xhost +local:root > /dev/null 2>&1 || true && "
        cmd += f"sudo -E DISPLAY=:0 XAUTHORITY={shlex.quote(xauth_file)} {CREATE_VM_WIN}"
        cmd += f" -i {shlex.quote(iso_path)}"
        cmd += f" -n {shlex.quote(vm_name)}"
        cmd += f" -s {shlex.quote(disk_size)}"
        cmd += f" -m {shlex.quote(str(memory))}"
        cmd += f" -c {shlex.quote(str(cpus))}"
        # Note: create-vm-win.sh doesn't support --qcow2 flag, it always creates raw images
        # If you need qcow2 support for Windows, the script would need to be modified
    else:
        return jsonify({'success': False, 'error': 'Invalid OS type'}), 400

    operation_id = run_command_async(
        get_next_operation_id(),
        cmd,
        f"Creating {os_type} VM: {vm_name}"
    )

    return jsonify({
        'success': True,
        'operation_id': operation_id
    })


def resolve_vm_id(root, vm_number, vm_name):
    """Resolve the numeric <vm id="..."> to target: match by name if given,
    since the Configure tab's hidden vm-number fields don't track the actual
    selection and would otherwise always fall back to a stale/default id.
    """
    vm_name = (vm_name or '').strip()
    if vm_name:
        for vm_el in root.findall('.//vm'):
            name_el = vm_el.find('name')
            if name_el is not None and name_el.text and name_el.text.strip() == vm_name:
                return vm_el.get('id', str(vm_number))
    return str(vm_number)


def _is_blank(val):
    """True when a submitted override means "cleared" rather than a value."""
    return val is None or str(val).strip() == ''


def _set_or_clear(parent, tag, val):
    """Write `val` into <tag>, or delete <tag> when the user cleared the field.

    Clearing has to remove the element. Previously an empty value was skipped,
    so the stale value stayed in the XML while the UI still reported "Saved".
    """
    import xml.etree.ElementTree as ET

    el = parent.find(tag)
    if _is_blank(val):
        if el is not None:
            parent.remove(el)
        return
    if el is None:
        el = ET.SubElement(parent, tag)
    el.text = str(val)


def _prune_if_empty(parent, child):
    """Drop `child` from `parent` once it has no elements left."""
    if child is not None and len(child) == 0:
        parent.remove(child)


def _apply_advanced_to_root(root, vm_id, advanced):
    """Apply an advanced overrides dict onto an already-parsed XML tree root.

    Kept centralized so `launch_vm_qemu` and `save_vm_advanced_config` stay in sync.

    Key presence is what decides the action, not truthiness:
      - key absent          -> leave the existing XML alone (sparse launch overrides)
      - key present, empty  -> remove the element (the user cleared the field)
      - key present, value  -> create or update the element
    That distinction is what lets the Configure tab's Save reset a field back to
    unset; treating empty as "not supplied" silently kept the old value.
    """
    import xml.etree.ElementTree as ET

    vm_id = str(vm_id)
    vm_els = root.findall(f".//vm[@id='{vm_id}']")

    for vm_el in vm_els:
        for tag in ('memory_size', 'cpu_cores', 'cpu_threads', 'cpu_assignment', 'disk_path'):
            if tag in advanced:
                _set_or_clear(vm_el, tag, advanced[tag])

    # Only touch USB when it was actually submitted -- this block rebuilds the
    # whole <usb_passthrough> subtree, so running it on a sparse launch payload
    # would wipe saved USB devices from the temp config.
    if 'usb_devices' in advanced and isinstance(advanced['usb_devices'], list):
        for vm_el in vm_els:
            for legacy_tag in ('usb_mouse_hostbus', 'usb_mouse_hostport'):
                legacy_el = vm_el.find(legacy_tag)
                if legacy_el is not None:
                    vm_el.remove(legacy_el)
            usb_root = vm_el.find('usb_passthrough')
            if usb_root is not None:
                vm_el.remove(usb_root)
            valid = [d for d in advanced['usb_devices']
                     if isinstance(d, dict)
                     and str(d.get('hostbus', '')).strip()
                     and str(d.get('hostport', '')).strip()]
            if valid:
                usb_root = ET.SubElement(vm_el, 'usb_passthrough')
                for dev in valid:
                    de = ET.SubElement(usb_root, 'device')
                    de.set('hostbus', str(dev['hostbus']).strip())
                    de.set('hostport', str(dev['hostport']).strip())

    for mode_el in root.findall(".//display_configurations/mode[@name='idv']"):
        for tag in ('fullscreen', 'show_fps', 'max_outputs', 'blob',
                    'render_sync', 'hw_cursor', 'input'):
            if tag in advanced:
                _set_or_clear(mode_el, tag, advanced[tag])

    for tag_key in ('display_mode', 'spice_port'):
        if tag_key not in advanced:
            continue
        for vm_el in vm_els:
            disp_cfg = vm_el.find('display_configuration')
            if _is_blank(advanced[tag_key]):
                if disp_cfg is not None:
                    _set_or_clear(disp_cfg, tag_key, '')
                    _prune_if_empty(vm_el, disp_cfg)
                continue
            if disp_cfg is None:
                disp_cfg = ET.SubElement(vm_el, 'display_configuration')
            _set_or_clear(disp_cfg, tag_key, advanced[tag_key])

    if 'connectors' in advanced:
        connectors = advanced['connectors'] or []
        named = [(i, str(c).strip()) for i, c in enumerate(connectors)
                 if c and str(c).strip()]
        for vm_el in vm_els:
            disp_cfg = vm_el.find('display_configuration')
            if not named:
                if disp_cfg is not None:
                    disp_conn = disp_cfg.find('display_connectors')
                    if disp_conn is not None:
                        disp_cfg.remove(disp_conn)
                    _prune_if_empty(vm_el, disp_cfg)
                continue
            if disp_cfg is None:
                disp_cfg = ET.SubElement(vm_el, 'display_configuration')
            disp_conn = disp_cfg.find('display_connectors')
            if disp_conn is None:
                disp_conn = ET.SubElement(disp_cfg, 'display_connectors')
            else:
                for old in list(disp_conn.findall('connector')):
                    disp_conn.remove(old)
            for idx, name in named:
                el = ET.SubElement(disp_conn, 'connector')
                el.set('index', str(idx))
                el.text = name


@app.route('/api/vm/advanced/save', methods=['POST'])
def save_vm_advanced_config():
    """Persist advanced overrides to the master config XML for a given vm_id."""
    import xml.etree.ElementTree as ET

    data = request.json or {}
    vm_number = data.get('vm_number', 1)
    vm_name   = str(data.get('vm_name') or '').strip()
    config    = data.get('config', CONFIG_XML)

    # Deliberately NOT filtering out empty values here: Save means "make the XML
    # match the form", so a cleared field must arrive as '' and remove its tag.
    # Filtering empties is what made a revert report "Saved" without changing
    # anything. An entirely empty dict still means nothing was submitted.
    advanced = data.get('advanced') or {}

    if not advanced:
        return jsonify({'success': False, 'error': 'No advanced values provided'}), 400
    if not os.path.exists(config):
        return jsonify({'success': False, 'error': f'Config file not found: {config}'}), 404

    try:
        ET.register_namespace('', '')
        tree = ET.parse(config)
        root = tree.getroot()
        vm_id = resolve_vm_id(root, vm_number, vm_name)
        _apply_advanced_to_root(root, vm_id, advanced)
        tree.write(config, encoding='utf-8', xml_declaration=True)
        return jsonify({'success': True, 'config': config, 'vm_id': vm_id})
    except Exception as e:
        return jsonify({'success': False, 'error': f'Failed to save advanced config: {e}'}), 500


# ---------------------------------------------------------------------------
# GPU VF assignment
#
# launch-vm.sh picks a VM's VF in get_gpu_vf_device() by indexing
#
#     lspci -D | grep -i 'vga' | grep -i intel
#
# with the VM's <vm id="..."> attribute. There is no "next free VF" search and
# nothing tracks which VFs are already taken, so two VMs can be handed the same
# VF and a VM whose id is 0 gets the *physical* function.
#
# Rather than change that script, the VF is chosen here and launch-vm.sh is
# handed a temp XML in which the target VM has been renumbered to the index of
# the VF we want it to bind. The id attribute is the only thing that selects
# the VF; -name and -pidfile come from their own tags, so renumbering doesn't
# rename the VM or move its pidfile.
#
# IMPORTANT: LSPCI_VF_ENUM_CMD must stay identical to the pipeline inside
# get_gpu_vf_device() in scripts/launch-vm.sh. If the two disagree on filtering
# or ordering, the index chosen here maps to a different device than the one
# the script actually binds. Change them together.
# ---------------------------------------------------------------------------

LSPCI_VF_ENUM_CMD = "lspci -D | grep -i 'vga' | grep -i intel | awk '{print $1}'"


def get_gpu_pci_devices():
    """The device list launch-vm.sh indexes into, in its exact order.

    Index 0 is the physical function and the VFs follow, so index N is
    normally the VF numbered N. Index 0 is never allocated -- handing a guest
    the PF would take the display away from the host.
    """
    try:
        result = subprocess.run(LSPCI_VF_ENUM_CMD, shell=True,
                                capture_output=True, text=True, timeout=10)
    except Exception as e:
        print(f"Error enumerating GPU devices: {e}")
        return []
    return [line.strip() for line in result.stdout.split('\n') if line.strip()]


def get_sriov_vf_addresses():
    """VF addresses from sysfs -- ground truth, used to audit the lspci list.

    /sys/bus/pci/devices/<PF>/virtfn<N> symlinks to the Nth VF's device dir.
    """
    import glob
    vfs = []
    for numvfs_path in glob.glob('/sys/bus/pci/devices/*/sriov_numvfs'):
        pf_dir = os.path.dirname(numvfs_path)
        virtfns = glob.glob(os.path.join(pf_dir, 'virtfn*'))
        for virtfn in sorted(virtfns, key=lambda p: int(re.sub(r'\D', '', os.path.basename(p)) or 0)):
            try:
                vfs.append(os.path.basename(os.path.realpath(virtfn)))
            except OSError:
                continue
    return vfs


def get_busy_vf_addresses():
    """VF addresses currently bound to a running QEMU process.

    Read off the live command line (`-device vfio-pci,host=<BDF>`, the form
    launch-vm.sh builds) rather than a bookkeeping file, so it reflects what
    is really claimed even after a crash or an out-of-band launch.
    """
    try:
        result = subprocess.run("ps aux | grep qemu-system-x86_64 | grep -v grep",
                                shell=True, capture_output=True, text=True, timeout=5)
    except Exception as e:
        print(f"Error scanning for in-use VFs: {e}")
        return set()
    return set(re.findall(r'vfio-pci,host=([0-9a-fA-F:.]+)', result.stdout))


def allocate_vf_index():
    """Pick the lowest free index into get_gpu_pci_devices().

    Returns (index, pci_address, None), or (None, None, error_message).
    """
    devices = get_gpu_pci_devices()
    if not devices:
        return None, None, ('No Intel GPU is visible to '
                            '`lspci -D | grep -i vga | grep -i intel`. '
                            'Provision SR-IOV first.')

    # launch-vm.sh can only bind a device that shows up in that VGA-filtered
    # list. On some parts the VFs enumerate as class 0380 "Display controller"
    # rather than 0300 "VGA compatible controller", in which case the filter
    # matches the PF alone and no renumbering here can reach them. Say so
    # plainly instead of falling back to index 0 and passing through the PF.
    missing = [vf for vf in get_sriov_vf_addresses() if vf not in devices]
    if missing:
        return None, None, (
            f"{len(missing)} SR-IOV VF(s) exist in sysfs but are invisible to the VGA "
            f"filter launch-vm.sh uses to pick a VF (first missing: {missing[0]}). "
            f"get_gpu_vf_device() in scripts/launch-vm.sh must match 'vga|display' "
            f"instead of 'vga' before these VFs can be assigned."
        )

    busy = get_busy_vf_addresses()
    for index in range(1, len(devices)):        # index 0 is the PF
        if devices[index] not in busy:
            return index, devices[index], None

    return None, None, (f'All {max(0, len(devices) - 1)} GPU VF(s) are in use. '
                        f'Stop a running VM or provision more VFs.')


# Temp launch configs are written per launch; tag them so stale ones from
# earlier runs can be pruned instead of accumulating in /tmp.
LAUNCH_CONFIG_PREFIX = 'sriov-launch-'
LAUNCH_CONFIG_MAX_AGE = 3600


def _prune_stale_launch_configs():
    """Delete launch configs left behind by previous launches. Best effort."""
    import glob
    import tempfile
    pattern = os.path.join(tempfile.gettempdir(), LAUNCH_CONFIG_PREFIX + '*.xml')
    for path in glob.glob(pattern):
        try:
            if time.time() - os.path.getmtime(path) > LAUNCH_CONFIG_MAX_AGE:
                os.unlink(path)
        except OSError:
            continue


def build_single_vm_launch_config(source_config, vm_id, vf_index, advanced=None):
    """Write a temp XML holding only this VM, renumbered to `vf_index`.

    Dropping the other <vm> entries keeps the new id from colliding with a
    real one. Everything else in the document is preserved -- notably the
    root-level <display_configurations>, which launch-vm.sh also queries.

    Returns (temp_path, None) or (None, error_message).
    """
    import xml.etree.ElementTree as ET
    import tempfile

    try:
        ET.register_namespace('', '')
        tree = ET.parse(source_config)
        root = tree.getroot()

        # Overrides match on the original id, so apply them before renumbering.
        if advanced:
            _apply_advanced_to_root(root, vm_id, advanced)

        vms_parent = root.find('.//virtual_machines')
        if vms_parent is None:
            return None, f'No <virtual_machines> section in {source_config}'

        target = None
        for vm_el in list(vms_parent.findall('vm')):
            if vm_el.get('id') == str(vm_id):
                target = vm_el
            else:
                vms_parent.remove(vm_el)

        if target is None:
            return None, f'VM id {vm_id} not found in {source_config}'

        target.set('id', str(vf_index))

        _prune_stale_launch_configs()
        tf = tempfile.NamedTemporaryFile(prefix=LAUNCH_CONFIG_PREFIX, suffix='.xml',
                                         delete=False, mode='wb')
        tree.write(tf, encoding='utf-8', xml_declaration=True)
        tf.close()
        return tf.name, None
    except Exception as e:
        return None, f'Failed to build launch config: {e}'


def build_qemu_launch(config, vm_number, vm_name, advanced=None):
    """Resolve the VM, reserve a VF, and build the launch-vm.sh command line.

    Returns (cmd, vf_address, None) or (None, None, (error_message, status)).
    """
    import xml.etree.ElementTree as ET

    try:
        vm_id = resolve_vm_id(ET.parse(config).getroot(), vm_number, vm_name)
    except Exception as e:
        return None, None, (f'Failed to read VM config: {e}', 500)

    vf_index, vf_address, error = allocate_vf_index()
    if error:
        return None, None, (error, 409)

    config_path, error = build_single_vm_launch_config(config, vm_id, vf_index, advanced)
    if error:
        return None, None, (error, 500)

    # -d is launch-vm.sh's --vm-id, and the VM now carries vf_index as its id.
    cmd = f"sudo {LAUNCH_VM_QEMU} -n 1 -d {vf_index} -c {config_path}"
    return cmd, vf_address, None


@app.route('/api/vm/launch/qemu', methods=['POST'])
def launch_vm_qemu():
    """Launch VM using QEMU (direct)"""
    blocked = sriov_not_provisioned_response()
    if blocked:
        return blocked

    data = request.json
    vm_number = data.get('vm_number', 1)
    vm_name   = str(data.get('vm_name') or '').strip()
    config    = data.get('config', CONFIG_XML)
    advanced  = {k: v for k, v in data.get('advanced', {}).items() if v not in (None, '')}

    cmd, vf_address, error = build_qemu_launch(config, vm_number, vm_name, advanced)
    if error:
        message, status = error
        return jsonify({'success': False, 'error': message}), status

    operation_id = run_command_async(
        get_next_operation_id(),
        cmd,
        f"Launching VM via QEMU: {vm_name or vm_number} (VF {vf_address})"
    )

    return jsonify({
        'success': True,
        'operation_id': operation_id,
        'vf_device': vf_address
    })


def find_vm_disk(vm_name):
    """Return the path to the actual disk image created for a VM, or None.

    Checks the common fixed locations first, then falls back to a recursive
    search under the standard VM image directories.
    """
    if not vm_name:
        return None

    candidates = [
        f"/data/vm-images/{vm_name}.qcow2",
        f"/data/vm-images/{vm_name}.img",
        f"/home/user/{vm_name}.qcow2",
        f"/home/user/{vm_name}.img",
    ]
    for path in candidates:
        if os.path.exists(path):
            return path

    for vm_dir in ['/data/vm-images', '/home/user']:
        if not os.path.isdir(vm_dir):
            continue
        try:
            result = subprocess.run(
                f"find {shlex.quote(vm_dir)} -maxdepth 2 -type f "
                f"\\( -name {shlex.quote(vm_name + '.img')} -o -name {shlex.quote(vm_name + '.qcow2')} \\) 2>/dev/null",
                shell=True, capture_output=True, text=True, timeout=5
            )
            for line in result.stdout.split('\n'):
                if line.strip():
                    return line.strip()
        except Exception:
            pass
    return None


def resolve_or_register_vm_id(vm_name, disk_path):
    """Return the real numeric <vm id="..."> for vm_name in the master config.

    IDs are dynamically assigned (gap-filled) by vm-config-manager.sh, so they
    can't be guessed from the VM's name. If the VM isn't tracked yet (started
    outside the create scripts before discovery ran), register it here so
    launch-vm.sh has a config entry to read from.
    Returns (vm_id, None) on success or (None, error_message) on failure.
    """
    match = next((v for v in get_master_config_vms() if v.get('name') == vm_name), None)
    if match:
        return match.get('id'), None

    os_type = 'windows' if 'win' in vm_name.lower() else 'ubuntu'
    rc, vm_id, err = run_config_manager(['next-vm-id'])
    if rc != 0:
        return None, err or 'Failed to allocate a VM ID'
    rc, ssh_port, err = run_config_manager(['next-ssh-port'])
    if rc != 0:
        return None, err or 'Failed to allocate an SSH port'
    rc, monitor_port, err = run_config_manager(['next-monitor-port'])
    if rc != 0:
        return None, err or 'Failed to allocate a monitor port'
    rc, mac_address, err = run_config_manager(['generate-mac', vm_id])
    if rc != 0:
        return None, err or 'Failed to generate a MAC address'
    rc, out, err = run_config_manager(['add-vm', vm_id, vm_name, os_type,
                                       '8192', '4', '2', mac_address, disk_path,
                                       ssh_port, monitor_port, 'Virtual Machine'])
    if rc != 0:
        return None, err or out or 'Failed to add VM to config'
    return vm_id, None


@app.route('/api/vm/config-defaults')
def get_vm_config_defaults():
    """Read default parameter values from the XML config for a given VM ID"""
    import xml.etree.ElementTree as ET
    vm_id  = request.args.get('vm_id', '1')
    config = request.args.get('config', CONFIG_XML)
    vm_name = request.args.get('vm_name', '').strip()
    try:
        tree = ET.parse(config)
        root = tree.getroot()

        def txt(el): return el.text.strip() if el is not None and el.text else ''

        # Prefer matching by VM name (from the master XML); fall back to slot id.
        vm_el = None
        if vm_name:
            for el in root.findall('.//vm'):
                name_el = el.find('name')
                if name_el is not None and name_el.text and name_el.text.strip() == vm_name:
                    vm_el = el
                    break
        if vm_el is None:
            vm_el = root.find(f".//vm[@id='{vm_id}']")
        vm_data = {}
        if vm_el is not None:
            for tag in ['os_type', 'memory_size', 'cpu_cores', 'cpu_threads', 'cpu_assignment', 'disk_path']:
                vm_data[tag] = txt(vm_el.find(tag))
            # USB passthrough devices. Combine the legacy single pair (if present)
            # with any <usb_passthrough><device/></usb_passthrough> entries.
            usb_devices = []
            legacy_bus = txt(vm_el.find('usb_mouse_hostbus'))
            legacy_port = txt(vm_el.find('usb_mouse_hostport'))
            if legacy_bus or legacy_port:
                usb_devices.append({'hostbus': legacy_bus, 'hostport': legacy_port})
            for d_el in vm_el.findall('usb_passthrough/device'):
                usb_devices.append({
                    'hostbus':  (d_el.get('hostbus') or '').strip(),
                    'hostport': (d_el.get('hostport') or '').strip(),
                })
            vm_data['usb_devices'] = usb_devices
            # Connectors
            conn_list = [''] * 4
            for c_el in vm_el.findall('.//display_connectors/connector'):
                try:
                    idx = int(c_el.get('index', -1))
                    if 0 <= idx < 4:
                        conn_list[idx] = (c_el.text or '').strip()
                except (ValueError, TypeError):
                    pass
            vm_data['connectors'] = conn_list

        # Prefer the actual disk image created for this specific VM, if one exists.
        if vm_name:
            actual_disk = find_vm_disk(vm_name)
            if actual_disk:
                vm_data['disk_path'] = actual_disk

        mode_el = root.find(".//display_configurations/mode[@name='idv']")
        disp_data = {}
        if mode_el is not None:
            for tag in ['fullscreen', 'show_fps', 'max_outputs', 'blob', 'render_sync', 'hw_cursor', 'input']:
                disp_data[tag] = txt(mode_el.find(tag))

        return jsonify({'vm': vm_data, 'display': disp_data})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/vm/template-defaults')
def get_vm_template_defaults():
    """Read "Reset Default" values from vm-master-config.xml.template.

    Matched by os_type (the template's sample VMs use placeholder names/ids
    that don't correspond to real VMs), not by name or id like config-defaults.
    disk_path is deliberately never returned here so Reset can't clobber a
    VM's real disk association.
    """
    import xml.etree.ElementTree as ET

    vm_name = request.args.get('vm_name', '').strip()
    os_type = request.args.get('os_type', '').strip().lower()

    if not os_type and vm_name:
        match = next((v for v in get_master_config_vms() if v.get('name') == vm_name), None)
        if match:
            os_type = (match.get('os_type') or '').strip().lower()
    os_type = os_type or 'ubuntu'

    if not os.path.exists(TEMPLATE_CONFIG_XML):
        return jsonify({'error': f'Template file not found: {TEMPLATE_CONFIG_XML}'}), 404

    try:
        root = ET.parse(TEMPLATE_CONFIG_XML).getroot()

        def txt(el):
            return el.text.strip() if el is not None and el.text else ''

        vm_el = None
        for el in root.findall('.//vm'):
            if txt(el.find('os_type')).lower() == os_type:
                vm_el = el
                break

        vm_data = {}
        if vm_el is not None:
            for tag in ['os_type', 'memory_size', 'cpu_cores', 'cpu_threads', 'cpu_assignment']:
                vm_data[tag] = txt(vm_el.find(tag))
            usb_devices = []
            for d_el in vm_el.findall('usb_passthrough/device'):
                usb_devices.append({
                    'hostbus':  (d_el.get('hostbus') or '').strip(),
                    'hostport': (d_el.get('hostport') or '').strip(),
                })
            vm_data['usb_devices'] = usb_devices
            conn_list = [''] * 4
            for c_el in vm_el.findall('.//display_connectors/connector'):
                try:
                    idx = int(c_el.get('index', -1))
                    if 0 <= idx < 4:
                        conn_list[idx] = (c_el.text or '').strip()
                except (ValueError, TypeError):
                    pass
            vm_data['connectors'] = conn_list

        mode_el = root.find(".//display_configurations/mode[@name='idv']")
        disp_data = {}
        if mode_el is not None:
            for tag in ['fullscreen', 'show_fps', 'max_outputs', 'blob', 'render_sync', 'hw_cursor', 'input']:
                disp_data[tag] = txt(mode_el.find(tag))

        return jsonify({'vm': vm_data, 'display': disp_data})
    except Exception as e:
        return jsonify({'error': str(e)}), 500



@app.route('/api/vm/launch/libvirt', methods=['POST'])
def launch_vm_libvirt():
    """Launch VM using libvirt"""
    blocked = sriov_not_provisioned_response()
    if blocked:
        return blocked

    data = request.json
    domain = data.get('domain', 'ubuntu')
    display = data.get('display', 'sriov')
    vm_name = data.get('vm_name', domain)

    cmd = f"{LAUNCH_VM_LIBVIRT} --virsh -d {domain} -g {display}"
    if vm_name != domain:
        cmd += f" {vm_name}"

    operation_id = run_command_async(
        get_next_operation_id(),
        cmd,
        f"Launching VM via libvirt: {domain}"
    )

    return jsonify({
        'success': True,
        'operation_id': operation_id
    })


@app.route('/api/libvirt/setup', methods=['POST'])
def setup_libvirt():
    """Run libvirt setup"""
    cmd = f"sudo {SETUP_LIBVIRT}"

    operation_id = run_command_async(
        get_next_operation_id(),
        cmd,
        "Setting up libvirt environment"
    )

    return jsonify({
        'success': True,
        'operation_id': operation_id
    })


@app.route('/api/operations/<operation_id>')
def get_operation_status(operation_id):
    """Get status of a specific operation"""
    if operation_id in operations:
        return jsonify(operations[operation_id])
    return jsonify({'error': 'Operation not found'}), 404


@app.route('/api/operations/<operation_id>/stream')
def stream_operation_output(operation_id):
    """Stream operation output in real-time"""
    def generate():
        if operation_id not in operations:
            yield f"data: {json.dumps({'error': 'Operation not found'})}\n\n"
            return

        last_line = 0
        while True:
            op = operations[operation_id]

            # Send new output lines
            if last_line < len(op['output']):
                for line in op['output'][last_line:]:
                    yield f"data: {json.dumps({'type': 'output', 'line': line})}\n\n"
                last_line = len(op['output'])

            # Send status updates
            yield f"data: {json.dumps({'type': 'status', 'status': op['status']})}\n\n"

            # Stop streaming if operation is done
            if op['status'] in ['completed', 'failed', 'error']:
                break

            time.sleep(0.5)

    return Response(generate(), mimetype='text/event-stream')


@app.route('/api/operations')
def list_operations():
    """List all operations"""
    return jsonify({
        'operations': [
            {
                'id': op_id,
                'description': op['description'],
                'status': op['status'],
                'start_time': op['start_time']
            }
            for op_id, op in operations.items()
        ]
    })


@app.route('/api/browse-files')
def browse_files():
    """Browse files in a directory (for ISO selection)"""
    path = request.args.get('path', '/data/vm-images')

    # Virtual/kernel filesystems that should never be browsed
    SKIP_PATHS = {'/proc', '/sys', '/dev', '/run', '/snap'}

    try:
        # Sanitize path to prevent directory traversal
        path = os.path.abspath(path)

        # Fall back to filesystem root if path doesn't exist
        if not os.path.exists(path):
            path = '/'

        if not os.path.isdir(path):
            return jsonify({'error': 'Not a directory'}), 400

        items = []

        # Add parent directory link when not at filesystem root
        if path != '/':
            parent_dir = os.path.dirname(path)
            items.append({
                'name': '..',
                'path': parent_dir,
                'type': 'directory',
                'size': ''
            })

        # List directory contents
        for item in sorted(os.listdir(path)):
            item_path = os.path.join(path, item)
            if item_path in SKIP_PATHS:
                continue
            try:
                stat_info = os.stat(item_path)
                is_dir = os.path.isdir(item_path)

                # For files, show size
                size = ''
                if not is_dir:
                    size_bytes = stat_info.st_size
                    if size_bytes < 1024:
                        size = f"{size_bytes} B"
                    elif size_bytes < 1024 * 1024:
                        size = f"{size_bytes / 1024:.1f} KB"
                    elif size_bytes < 1024 * 1024 * 1024:
                        size = f"{size_bytes / (1024 * 1024):.1f} MB"
                    else:
                        size = f"{size_bytes / (1024 * 1024 * 1024):.2f} GB"

                items.append({
                    'name': item,
                    'path': item_path,
                    'type': 'directory' if is_dir else 'file',
                    'size': size,
                    'extension': os.path.splitext(item)[1].lower() if not is_dir else ''
                })
            except (OSError, PermissionError):
                continue

        return jsonify({
            'current_path': path,
            'items': items
        })

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/vm/disk-info/<vm_name>')
def get_vm_disk_info(vm_name):
    """Get disk information for a VM"""
    try:
        # Common disk locations
        disk_paths = [
            f"/data/vm-images/{vm_name}.img",
            f"/data/vm-images/{vm_name}.qcow2",
            f"/home/user/{vm_name}.img",
            f"/home/user/{vm_name}.qcow2",
        ]

        for disk_path in disk_paths:
            if os.path.exists(disk_path):
                # Get disk size
                size_bytes = os.path.getsize(disk_path)
                size_gb = size_bytes / (1024**3)

                # Determine format
                disk_format = 'qcow2' if disk_path.endswith('.qcow2') else 'raw'

                # Try to get actual disk usage with qemu-img
                try:
                    result = subprocess.run(
                        f"qemu-img info {disk_path}",
                        shell=True,
                        capture_output=True,
                        text=True
                    )
                    if result.returncode == 0:
                        # Parse qemu-img output for more details
                        for line in result.stdout.split('\n'):
                            if 'virtual size' in line.lower():
                                size_str = line.split(':')[1].strip()
                                return jsonify({
                                    'path': disk_path,
                                    'size': size_str,
                                    'format': disk_format,
                                    'physical_size': f"{size_gb:.2f} GB"
                                })
                except:
                    pass

                return jsonify({
                    'path': disk_path,
                    'size': f"{size_gb:.2f} GB",
                    'format': disk_format
                })

        return jsonify({'error': 'Disk not found'}), 404

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/vm/details/<vm_name>')
def get_vm_details(vm_name):
    """Get detailed information about a VM"""
    vm_type = request.args.get('type', 'libvirt')

    try:
        if vm_type == 'libvirt':
            # Get libvirt domain info
            result = subprocess.run(
                f"virsh dominfo {vm_name} 2>/dev/null",
                shell=True,
                capture_output=True,
                text=True
            )

            if result.returncode == 0:
                details = {'persistent': False, 'autostart': False}

                for line in result.stdout.split('\n'):
                    if 'Persistent:' in line:
                        details['persistent'] = 'yes' in line.lower()
                    elif 'Autostart:' in line:
                        details['autostart'] = 'enable' in line.lower()

                return jsonify(details)

        return jsonify({'error': 'VM not found or unsupported type'}), 404

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/vm/start', methods=['POST'])
def start_vm():
    """Start/launch a VM.

Always launches via launch-vm.sh (direct QEMU) using a temporary config
whose disk_path points at the VM's actual image -- launch-vm.sh picks the
right disk format (raw/qcow2) internally based on the file extension.
libvirt is never used to start a VM, even one still defined as a libvirt
domain (its disk is located via `virsh dumpxml` as a fallback).
"""
    import xml.etree.ElementTree as ET
    import tempfile

    data = request.json
    vm_name = data.get('vm_name')
    vm_type = data.get('vm_type', 'libvirt')

    if not vm_name:
        return jsonify({'success': False, 'error': 'VM name required'}), 400

    blocked = sriov_not_provisioned_response()
    if blocked:
        return blocked

    # Disk-image / QEMU VM -> launch via launch-vm.sh against its real image.
    disk = find_vm_disk(vm_name)
    if not disk and vm_type == 'libvirt':
        # Still-defined libvirt domain: its disk may not follow the standard
        # naming convention find_vm_disk() looks for, so read it straight
        # from the domain's own XML instead of falling back to virsh start.
        try:
            result = subprocess.run(
                f"virsh --connect qemu:///system dumpxml {shlex.quote(vm_name)}",
                shell=True, capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                m = re.search(r"<source file=['\"]([^'\"]+)['\"]", result.stdout)
                if m:
                    disk = m.group(1)
        except Exception:
            pass

    if not disk:
        return jsonify({'success': False,
                        'error': f'No disk image found for "{vm_name}"'}), 400

    # Look up this VM's real id in the master config (IDs are dynamically
    # gap-filled, not derivable from the name), registering it if needed.
    vm_id, id_err = resolve_or_register_vm_id(vm_name, disk)
    if id_err:
        return jsonify({'success': False, 'error': id_err}), 500

    if not os.path.exists(CONFIG_XML):
        return jsonify({'success': False,
                        'error': f'Config file not found: {CONFIG_XML}'}), 400

    # Reserve a free VF before touching the config -- see the GPU VF assignment
    # notes above allocate_vf_index(). The VM is renumbered to the VF's index
    # below, which is how launch-vm.sh is steered onto that VF.
    vf_index, vf_address, vf_err = allocate_vf_index()
    if vf_err:
        return jsonify({'success': False, 'error': vf_err}), 409

    # Build a temp config overriding the chosen VM's disk_path with the real image.
    try:
        tree = ET.parse(CONFIG_XML)
        root = tree.getroot()
        vm_el = root.find(f".//vm[@id='{vm_id}']")
        if vm_el is None:
            return jsonify({'success': False,
                            'error': f'VM id {vm_id} not found in config'}), 400
        disk_el = vm_el.find('disk_path')
        if disk_el is None:
            disk_el = ET.SubElement(vm_el, 'disk_path')
        disk_el.text = disk

        # Override the config name so the launched QEMU process maps back to this
        # exact VM (otherwise a duplicate entry appears under the config's name).
        name_el = vm_el.find('name')
        if name_el is None:
            name_el = ET.SubElement(vm_el, 'name')
        name_el.text = vm_name

        # Drop the other VMs so the renumbered id can't collide with a real
        # one, then renumber onto the allocated VF.
        vms_parent = root.find('.//virtual_machines')
        if vms_parent is None:
            return jsonify({'success': False,
                            'error': 'No <virtual_machines> section in config'}), 400
        for other in list(vms_parent.findall('vm')):
            if other is not vm_el:
                vms_parent.remove(other)
        vm_el.set('id', str(vf_index))

        _prune_stale_launch_configs()
        tf = tempfile.NamedTemporaryFile(prefix=LAUNCH_CONFIG_PREFIX, suffix='.xml',
                                         delete=False, mode='wb')
        tree.write(tf, encoding='utf-8', xml_declaration=True)
        tf.close()
        config_path = tf.name
    except Exception as e:
        return jsonify({'success': False,
                        'error': f'Failed to build launch config: {e}'}), 500

# Always launch via direct QEMU (launch-vm.sh); it handles both raw and
    # qcow2 disks internally based on the file extension, so libvirt is never
    # needed here.
    launch_script = LAUNCH_VM_QEMU
    launch_label = 'QEMU'

# Forward DISPLAY/XAUTHORITY through sudo (like /api/vm/create), otherwise
    # the launched QEMU process has no display and its GTK window never
    # appears -- it just runs invisibly in the background.
    user_home = os.path.expanduser("~")
    xauth_file = f"{user_home}/.Xauthority"
    cmd = "xhost +local:root > /dev/null 2>&1 || true && "
    cmd += (f"sudo -E DISPLAY=:0 XAUTHORITY={shlex.quote(xauth_file)} "
            f"{launch_script} -d {shlex.quote(str(vf_index))} "
            f"-c {shlex.quote(config_path)}")
    operation_id = run_command_async(
        get_next_operation_id(), cmd,
        f"Launching VM: {vm_name} via {launch_label} "
        f"(VF {vf_address}, {os.path.basename(disk)})")
    return jsonify({'success': True, 'operation_id': operation_id, 'vf_device': vf_address})


@app.route('/api/vm/start-configured', methods=['POST'])
def start_vm_configured():
    """Start a VM using its saved configuration (qemu or libvirt)"""
    data = request.json
    vm_name = data.get('vm_name')
    config = data.get('config')

    if not vm_name:
        return jsonify({'success': False, 'error': 'VM name required'}), 400

    if not config:
        return jsonify({'success': False, 'error': 'VM configuration required'}), 400

    blocked = sriov_not_provisioned_response()
    if blocked:
        return blocked

    launch_method = config.get('launch_method', 'qemu')

    # Extract unified configuration parameters
    os_type = config.get('os_type', 'ubuntu')
    memory_size = config.get('memory_size', 8192)
    cpu_cores = config.get('cpu_cores', 4)
    cpu_threads = config.get('cpu_threads', 2)
    disk_path = config.get('disk_path', '')
    mac_address = config.get('mac_address', '')
    ssh_port = config.get('ssh_port', 3333)
    monitor_port = config.get('monitor_port', 1111)

    if launch_method == 'libvirt':
        # Launch via libvirt
        # The libvirt script will use the XML config or generate one
        domain = os_type  # ubuntu or windows
        display = 'sriov'  # Default to SR-IOV

        cmd = f"{LAUNCH_VM_LIBVIRT} --virsh -d {domain} -g {display}"
        if vm_name != domain:
            cmd += f" {vm_name}"

        description = f"Starting VM via libvirt: {vm_name}"

    elif launch_method == 'qemu':
        # Launch via QEMU. -d is launch-vm.sh's --vm-id, and the VF is derived
        # from that same id, so build_qemu_launch() reserves a free VF and
        # hands over a temp config with the VM renumbered onto it.
        vm_number = 1  # Could be enhanced to auto-assign based on existing VMs

        cmd, vf_address, error = build_qemu_launch(CONFIG_XML, vm_number, vm_name)
        if error:
            message, status = error
            return jsonify({'success': False, 'error': message}), status

        # NOTE: -m/-s/-i are NOT accepted by launch-vm.sh -- its parser only
        # knows -h/-c/-n/-d/--network and aborts with "Unknown option" on
        # anything else. Memory, CPU and disk already come from the config XML
        # this route hands over, so appending them here only broke the launch.
        description = f"Starting VM via QEMU: {vm_name} (VF {vf_address}, {memory_size}MB RAM)"

    else:
        return jsonify({'success': False, 'error': f'Unknown launch method: {launch_method}'}), 400

    operation_id = run_command_async(
        get_next_operation_id(),
        cmd,
        description
    )

    return jsonify({
        'success': True,
        'operation_id': operation_id
    })


@app.route('/api/vm/stop', methods=['POST'])
def stop_vm():
    """Stop a running VM"""
    data = request.json
    vm_name = data.get('vm_name')
    vm_type = data.get('vm_type', 'libvirt')
    pid = data.get('pid')

    if not vm_name:
        return jsonify({'success': False, 'error': 'VM name required'}), 400

    # Build command based on VM type
    if vm_type == 'libvirt':
        cmd = f"virsh shutdown {vm_name}"
        description = f"Stopping VM (libvirt): {vm_name}"
    elif vm_type == 'qemu' and pid:
        cmd = f"sudo kill -TERM {pid}"
        description = f"Stopping VM (QEMU): {vm_name} (PID: {pid})"
    else:
        return jsonify({'success': False, 'error': 'Unsupported VM type or missing PID'}), 400

    # Use async operation tracking
    operation_id = run_command_async(
        get_next_operation_id(),
        cmd,
        description
    )

    return jsonify({
        'success': True,
        'operation_id': operation_id
    })


# ---------------------------------------------------------------------------
# QEMU HMP monitor
#
# libvirt VMs are driven through virsh, but QEMU VMs have no such control
# channel -- until now the only thing the UI could do to one was kill its PID
# (see stop_vm above). launch-vm.sh starts every QEMU VM with
#   -monitor telnet:localhost:<monitor_port>,server,nowait
# so pause/resume/reboot are reachable over that socket as the HMP commands
# `stop`, `cont` and `system_reset`.
# ---------------------------------------------------------------------------

MONITOR_HOST = '127.0.0.1'
MONITOR_TIMEOUT = 5

# Matches the -monitor argument launch-vm.sh builds, capturing the port.
QEMU_MONITOR_RE = re.compile(r'-monitor\s+telnet:[^:,\s]*:(\d+)')


def _strip_telnet_iac(data):
    """Drop the telnet IAC negotiation bytes QEMU's telnet chardev sends.

    Without this the connect banner and command echo come back peppered with
    0xFF control sequences, which would show up as mojibake in the operation
    log the UI streams.
    """
    out = bytearray()
    i = 0
    while i < len(data):
        if data[i] == 0xFF:
            if i + 1 < len(data) and data[i + 1] == 0xFA:   # subnegotiation
                end = data.find(b'\xff\xf0', i + 2)
                i = len(data) if end == -1 else end + 2
            else:
                i += 3                                      # IAC + verb + option
            continue
        out.append(data[i])
        i += 1
    return bytes(out)


def _read_monitor(sock, timeout):
    """Read from the monitor until QEMU re-prints its `(qemu)` prompt."""
    data = b''
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sock.settimeout(max(0.1, deadline - time.monotonic()))
        try:
            chunk = sock.recv(4096)
        except (socket.timeout, TimeoutError):
            break
        if not chunk:
            break
        data += chunk
        if _strip_telnet_iac(data).rstrip().endswith(b'(qemu)'):
            break
    return _strip_telnet_iac(data).decode('utf-8', 'replace')


def qemu_monitor_command(monitor_port, hmp_command, timeout=MONITOR_TIMEOUT):
    """Send one HMP command to a QEMU monitor. Returns (ok, output_text).

    HMP has no exit codes, so "ok" means the socket accepted the command and
    QEMU didn't answer with an error line. The connection is closed rather
    than sent `quit` -- `quit` would terminate the VM.
    """
    try:
        with socket.create_connection((MONITOR_HOST, int(monitor_port)), timeout=timeout) as sock:
            _read_monitor(sock, timeout)          # drain the connect banner
            sock.sendall((hmp_command + '\n').encode())
            reply = _read_monitor(sock, timeout)
    except (OSError, ValueError) as e:
        return False, f"Could not reach the QEMU monitor on port {monitor_port}: {e}"

    for line in reply.splitlines():
        stripped = line.strip()
        if stripped.startswith('Error') or 'unknown command' in stripped:
            return False, reply
    return True, reply


def _qemu_monitor_port_from_ps(vm_name):
    """Find vm_name's monitor port on the live qemu-system-x86_64 command line."""
    try:
        result = subprocess.run(
            "ps aux | grep qemu-system-x86_64 | grep -v grep",
            shell=True, capture_output=True, text=True, timeout=5
        )
    except Exception as e:
        print(f"Error scanning QEMU processes for monitor port: {e}")
        return None

    for line in result.stdout.split('\n'):
        if 'qemu-system-x86_64' not in line:
            continue
        name_match = re.search(r'-name\s+(\S+)', line)
        if not name_match or name_match.group(1) != vm_name:
            continue
        port_match = QEMU_MONITOR_RE.search(line)
        if port_match:
            return port_match.group(1)
    return None


def resolve_qemu_monitor_port(vm_name):
    """Resolve vm_name's HMP port, or return (None, message) for the UI.

    The running process wins over the master config: the config is what the VM
    *should* have been launched with, the command line is what it actually got.
    """
    port = _qemu_monitor_port_from_ps(vm_name)
    if port:
        return port, None

    for vm in get_master_config_vms():
        if vm.get('name') == vm_name and vm.get('monitor_port'):
            return vm['monitor_port'], None

    return None, (f"No QEMU monitor found for '{vm_name}'. The VM must be running and "
                  f"launched with a monitor port set in its VM configuration.")


def get_qemu_run_state(monitor_port):
    """Map QEMU's `info status` onto the UI's status vocabulary.

    Falls back to 'running' whenever the monitor can't be reached -- the
    process is alive either way, so that matches the previous behaviour.
    """
    ok, output = qemu_monitor_command(monitor_port, 'info status', timeout=1.5)
    if ok and 'vm status: paused' in output.lower():
        return 'paused'
    return 'running'


def run_monitor_command_async(operation_id, monitor_port, hmp_command, description):
    """Run an HMP command in the background, tracked like run_command_async.

    Mirrors run_command_async's `operations` bookkeeping so the UI's
    monitorOperation()/stream endpoints work the same for QEMU and libvirt.
    """
    operations[operation_id] = {
        'status': 'running',
        'description': description,
        'output': [],
        'start_time': datetime.now().isoformat(),
        'command': f"(qemu monitor :{monitor_port}) {hmp_command}"
    }

    def execute():
        try:
            ok, output = qemu_monitor_command(monitor_port, hmp_command)
            for line in output.splitlines():
                if line.strip():
                    operations[operation_id]['output'].append(line.rstrip())
            operations[operation_id]['status'] = 'completed' if ok else 'failed'
            operations[operation_id]['return_code'] = 0 if ok else 1
        except Exception as e:
            operations[operation_id]['status'] = 'error'
            operations[operation_id]['output'].append(f"Error: {str(e)}")
        operations[operation_id]['end_time'] = datetime.now().isoformat()

    thread = threading.Thread(target=execute)
    thread.daemon = True
    thread.start()

    return operation_id


def dispatch_vm_control(action, virsh_command, hmp_command):
    """Shared body for the pause/resume/reboot routes.

    Each dispatches to virsh for libvirt VMs and to the HMP monitor for QEMU
    VMs, the same split stop_vm uses, and returns a Flask response tuple.
    """
    data = request.json
    vm_name = data.get('vm_name')
    vm_type = data.get('vm_type', 'libvirt')

    if not vm_name:
        return jsonify({'success': False, 'error': 'VM name required'}), 400

    if vm_type == 'libvirt':
        operation_id = run_command_async(
            get_next_operation_id(),
            f"virsh {virsh_command} {shlex.quote(vm_name)}",
            f"{action} VM (libvirt): {vm_name}"
        )
    elif vm_type == 'qemu':
        monitor_port, error = resolve_qemu_monitor_port(vm_name)
        if error:
            return jsonify({'success': False, 'error': error}), 400
        operation_id = run_monitor_command_async(
            get_next_operation_id(),
            monitor_port,
            hmp_command,
            f"{action} VM (QEMU): {vm_name} (monitor :{monitor_port})"
        )
    else:
        return jsonify({'success': False, 'error': f'Unsupported VM type: {vm_type}'}), 400

    return jsonify({'success': True, 'operation_id': operation_id})


@app.route('/api/vm/reboot', methods=['POST'])
def reboot_vm():
    """Reboot a running VM (libvirt or QEMU)"""
    return dispatch_vm_control('Rebooting', 'reboot', 'system_reset')


@app.route('/api/vm/pause', methods=['POST'])
def pause_vm():
    """Pause (suspend CPUs of) a running VM (libvirt or QEMU)"""
    return dispatch_vm_control('Pausing', 'suspend', 'stop')


@app.route('/api/vm/resume', methods=['POST'])
def resume_vm():
    """Resume a paused VM (libvirt or QEMU)"""
    return dispatch_vm_control('Resuming', 'resume', 'cont')


@app.route('/api/vm/hibernate', methods=['POST'])
def hibernate_vm():
    """Hibernate is temporarily disabled.

    Guest S4 suspend-to-disk needs qemu-guest-agent running inside the guest,
    which the QEMU launch path doesn't install or wire up. Rejected here (and
    greyed out in the UI) rather than quietly doing something that isn't a
    hibernate. Re-enable by restoring `virsh dompmsuspend <vm> --target disk`
    for libvirt and adding a guest-agent channel to the QEMU launch.
    """
    return jsonify({
        'success': False,
        'error': 'Hibernate is temporarily disabled.'
    }), 503


@app.route('/api/vm/config/<vm_name>')
def get_vm_config(vm_name):
    try:
        # Get domain XML
        result = subprocess.run(
            f"virsh dumpxml {vm_name}",
            shell=True,
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            return jsonify({'error': 'Failed to get VM configuration'}), 404

        import xml.etree.ElementTree as ET
        root = ET.fromstring(result.stdout)

        # Parse basic configuration
        config = {}

        # Memory (in KB, convert to MB)
        memory_elem = root.find('memory')
        if memory_elem is not None:
            config['memory'] = int(int(memory_elem.text) / 1024)

        # vCPUs
        vcpu_elem = root.find('vcpu')
        if vcpu_elem is not None:
            config['vcpus'] = int(vcpu_elem.text)

        # Disk path
        disk_elem = root.find(".//disk[@type='file']/source")
        if disk_elem is not None:
            config['disk_path'] = disk_elem.get('file', '')

        # VF device (try to extract from hostdev if present)
        hostdev_elem = root.find(".//hostdev[@type='pci']")
        if hostdev_elem is not None:
            address_elem = hostdev_elem.find('source/address')
            if address_elem is not None:
                # Extract device number from PCI address if possible
                config['vf_device'] = address_elem.get('device', '0x00').replace('0x', '')

        # Display type
        graphics_elem = root.find('.//graphics')
        if graphics_elem is not None:
            config['display_type'] = graphics_elem.get('type', 'sriov')
        else:
            config['display_type'] = 'sriov'

        return jsonify(config)

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/vm/xml/<vm_name>')
def get_vm_xml(vm_name):
    """Get VM domain XML"""
    try:
        result = subprocess.run(
            f"virsh dumpxml {vm_name}",
            shell=True,
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            return jsonify({'error': 'Failed to get domain XML'}), 404

        return jsonify({'xml': result.stdout})

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/vm/config', methods=['POST'])
def update_vm_config():
    """Update VM configuration (basic parameters)"""
    data = request.json
    vm_name = data.get('vm_name')

    if not vm_name:
        return jsonify({'success': False, 'error': 'VM name required'}), 400

    try:
        # Get current XML
        result = subprocess.run(
            f"virsh dumpxml {vm_name}",
            shell=True,
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            return jsonify({'success': False, 'error': 'Failed to get VM configuration'}), 404

        import xml.etree.ElementTree as ET
        root = ET.fromstring(result.stdout)

        # Update memory (convert MB to KB)
        if data.get('memory'):
            memory_mb = int(data['memory'])
            memory_kb = memory_mb * 1024
            memory_elem = root.find('memory')
            if memory_elem is not None:
                memory_elem.text = str(memory_kb)
            current_memory_elem = root.find('currentMemory')
            if current_memory_elem is not None:
                current_memory_elem.text = str(memory_kb)

        # Update vCPUs
        if data.get('vcpus'):
            vcpu_elem = root.find('vcpu')
            if vcpu_elem is not None:
                vcpu_elem.text = str(int(data['vcpus']))

        # Update disk path
        if data.get('disk_path'):
            disk_elem = root.find(".//disk[@type='file']/source")
            if disk_elem is not None:
                disk_elem.set('file', data['disk_path'])

        # Convert back to XML string
        updated_xml = ET.tostring(root, encoding='unicode')

        # Write to temp file
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', suffix='.xml', delete=False) as f:
            f.write(updated_xml)
            temp_xml_path = f.name

        # Undefine and redefine the domain
        commands = []
        commands.append(f"virsh undefine {vm_name}")
        commands.append(f"virsh define {temp_xml_path}")
        commands.append(f"rm -f {temp_xml_path}")

        cmd = " && ".join(commands)

        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)

        if result.returncode == 0:
            return jsonify({'success': True})
        else:
            return jsonify({'success': False, 'error': result.stderr}), 500

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


@app.route('/api/vm/xml', methods=['POST'])
def update_vm_xml():
    """Update VM domain XML directly"""
    data = request.json
    vm_name = data.get('vm_name')
    xml = data.get('xml')

    if not vm_name or not xml:
        return jsonify({'success': False, 'error': 'VM name and XML required'}), 400

    try:
        # Write XML to temp file
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', suffix='.xml', delete=False) as f:
            f.write(xml)
            temp_xml_path = f.name

        # Undefine and redefine the domain
        commands = []
        commands.append(f"virsh undefine {vm_name}")
        commands.append(f"virsh define {temp_xml_path}")
        commands.append(f"rm -f {temp_xml_path}")

        cmd = " && ".join(commands)

        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)

        if result.returncode == 0:
            return jsonify({'success': True})
        else:
            return jsonify({'success': False, 'error': result.stderr}), 500

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


@app.route('/api/vm/xml/validate', methods=['POST'])
def validate_xml():
    """Validate domain XML"""
    data = request.json
    xml = data.get('xml')

    if not xml:
        return jsonify({'valid': False, 'error': 'XML content required'}), 400

    try:
        import xml.etree.ElementTree as ET
        # Try to parse the XML
        ET.fromstring(xml)

        # Additional validation: check for required elements
        root = ET.fromstring(xml)
        if root.tag != 'domain':
            return jsonify({'valid': False, 'error': 'Root element must be <domain>'}), 400

        # Check for name element
        if root.find('name') is None:
            return jsonify({'valid': False, 'error': 'Missing required <name> element'}), 400

        return jsonify({'valid': True})

    except ET.ParseError as e:
        return jsonify({'valid': False, 'error': f'XML parse error: {str(e)}'}), 400
    except Exception as e:
        return jsonify({'valid': False, 'error': str(e)}), 400


@app.route('/api/vm/clone', methods=['POST'])
def clone_vm():
    """Cloning is temporarily disabled.

    Greyed out in the UI; also rejected here so nothing can reach
    clone-vm.sh in the meantime. Re-enable by restoring the
    run_command_async call on CLONE_VM_SCRIPT below.
    """
    return jsonify({
        'success': False,
        'error': 'Cloning is temporarily disabled.'
    }), 503


################################################################################
# VM Config Manager (scripts/vm-config-manager.sh) — manages entries in the
# master VM config XML: create, delete, and parameter changes.
################################################################################

@app.route('/api/config-manager/vms')
def config_manager_list_vms():
    """List all VM entries currently in the master config XML."""
    return jsonify({
        'config_file': MASTER_CONFIG_XML,
        'exists': os.path.exists(MASTER_CONFIG_XML),
        'vms': get_master_config_vms(),
    })


@app.route('/api/config-manager/init', methods=['POST'])
def config_manager_init():
    """Build (or rebuild) the master config from template + host discovery."""
    data = request.json or {}
    force = bool(data.get('force'))

    args = ['init-config'] + (['--force'] if force else [])
    rc, out, err = run_config_manager(args, timeout=60)
    if rc != 0:
        return jsonify({'success': False, 'error': err or out or 'Failed to initialize config'}), 500

    return jsonify({'success': True, 'message': out or 'Config initialized', 'vms': get_master_config_vms()})


@app.route('/api/config-manager/next-ids')
def config_manager_next_ids():
    """Return the next available VM ID, SSH port, monitor port, and a matching MAC."""
    rc1, vm_id, err1 = run_config_manager(['next-vm-id'])
    rc2, ssh_port, err2 = run_config_manager(['next-ssh-port'])
    rc3, monitor_port, err3 = run_config_manager(['next-monitor-port'])
    if rc1 != 0 or rc2 != 0 or rc3 != 0:
        return jsonify({'success': False, 'error': err1 or err2 or err3 or 'Failed to compute next values'}), 500

    mac_address = ''
    rc4, mac_out, _err4 = run_config_manager(['generate-mac', vm_id])
    if rc4 == 0:
        mac_address = mac_out

    return jsonify({
        'success': True,
        'vm_id': vm_id,
        'ssh_port': ssh_port,
        'monitor_port': monitor_port,
        'mac_address': mac_address,
    })


@app.route('/api/config-manager/generate-mac', methods=['POST'])
def config_manager_generate_mac():
    """Generate a MAC address tied to a specific VM ID."""
    data = request.json or {}
    vm_id = str(data.get('vm_id') or '').strip()
    if not vm_id.isdigit():
        return jsonify({'success': False, 'error': 'A valid numeric VM ID is required'}), 400

    rc, out, err = run_config_manager(['generate-mac', vm_id])
    if rc != 0:
        return jsonify({'success': False, 'error': err or 'Failed to generate MAC address'}), 500

    return jsonify({'success': True, 'mac_address': out})


@app.route('/api/config-manager/add', methods=['POST'])
def config_manager_add_vm():
    """Add a new VM entry to the master config XML (create)."""
    data = request.json or {}

    vm_name = str(data.get('vm_name') or '').strip()
    os_type = str(data.get('os_type') or '').strip()
    disk_path = str(data.get('disk_path') or '').strip()
    description = str(data.get('description') or '').strip()

    if not vm_name or not os_type or not disk_path:
        return jsonify({'success': False, 'error': 'VM name, OS type, and disk path are required'}), 400
    if os_type not in ('ubuntu', 'windows'):
        return jsonify({'success': False, 'error': 'OS type must be "ubuntu" or "windows"'}), 400

    vm_id = str(data.get('vm_id') or '').strip()
    memory = str(data.get('memory') or '8192').strip()
    cpu_cores = str(data.get('cpu_cores') or '4').strip()
    cpu_threads = str(data.get('cpu_threads') or '2').strip()
    ssh_port = str(data.get('ssh_port') or '').strip()
    monitor_port = str(data.get('monitor_port') or '').strip()
    mac_address = str(data.get('mac_address') or '').strip()

    for label, value in (('VM ID', vm_id), ('memory', memory), ('CPU cores', cpu_cores),
                         ('CPU threads', cpu_threads)):
        if value and not value.isdigit():
            return jsonify({'success': False, 'error': f'{label} must be a whole number'}), 400
    for label, value in (('SSH port', ssh_port), ('monitor port', monitor_port)):
        if value and not value.isdigit():
            return jsonify({'success': False, 'error': f'{label} must be a whole number'}), 400
    if mac_address and not re.match(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$', mac_address):
        return jsonify({'success': False, 'error': 'MAC address must look like EE:DD:BB:42:AA:05'}), 400

    if not vm_id:
        rc, vm_id, err = run_config_manager(['next-vm-id'])
        if rc != 0:
            return jsonify({'success': False, 'error': err or 'Failed to allocate a VM ID'}), 500
    if not ssh_port:
        rc, ssh_port, err = run_config_manager(['next-ssh-port'])
        if rc != 0:
            return jsonify({'success': False, 'error': err or 'Failed to allocate an SSH port'}), 500
    if not monitor_port:
        rc, monitor_port, err = run_config_manager(['next-monitor-port'])
        if rc != 0:
            return jsonify({'success': False, 'error': err or 'Failed to allocate a monitor port'}), 500
    if not mac_address:
        rc, mac_address, err = run_config_manager(['generate-mac', vm_id])
        if rc != 0:
            return jsonify({'success': False, 'error': err or 'Failed to generate a MAC address'}), 500

    args = ['add-vm', vm_id, vm_name, os_type, memory, cpu_cores, cpu_threads,
            mac_address, disk_path, ssh_port, monitor_port]
    if description:
        args.append(description)

    rc, out, err = run_config_manager(args)
    if rc != 0:
        return jsonify({'success': False, 'error': err or out or 'Failed to add VM to config'}), 400

    return jsonify({
        'success': True,
        'message': out or f'VM added to config: {vm_name} (ID: {vm_id})',
        'vm_id': vm_id, 'ssh_port': ssh_port, 'monitor_port': monitor_port, 'mac_address': mac_address,
    })


@app.route('/api/config-manager/update', methods=['POST'])
def config_manager_update_vm():
    """Update one or more fields of an existing VM entry (parameter changes).

    Upserts: if the VM isn't tracked in the config yet (e.g. it was started
    outside the create scripts before discovery ran), create its entry instead
    of failing, so Configure-tab edits always land in the XML.
    """
    data = request.json or {}
    vm_name = str(data.get('vm_name') or '').strip()
    updates = data.get('updates') or {}

    if not vm_name:
        return jsonify({'success': False, 'error': 'VM name required'}), 400
    if not isinstance(updates, dict) or not updates:
        return jsonify({'success': False, 'error': 'No fields to update'}), 400

    pairs = []
    clean = {}
    for field, value in updates.items():
        if field not in CONFIG_MANAGER_FIELDS:
            return jsonify({'success': False, 'error': f'Unknown field: {field}'}), 400
        value = str(value).strip() if value is not None else ''
        if not value and field not in CLEARABLE_CONFIG_FIELDS:
            # Every other field is required -- a VM can't have no MAC, no ports
            # or no memory -- so an empty one means "unchanged", not "erase".
            continue
        if field in ('memory', 'cpu_cores', 'cpu_threads', 'ssh_port', 'monitor_port') and not value.isdigit():
            return jsonify({'success': False, 'error': f'{field} must be a whole number'}), 400
        if field == 'mac_address' and not re.match(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$', value):
            return jsonify({'success': False, 'error': 'MAC address must look like EE:DD:BB:42:AA:05'}), 400
        clean[field] = value
        pairs.append(f"{field}={value}")

    if not pairs:
        return jsonify({'success': False, 'error': 'No non-empty fields to update'}), 400

    tracked = any(v.get('name') == vm_name for v in get_master_config_vms())
    if not tracked:
        disk_path = clean.get('disk_path') or find_vm_disk(vm_name)
        if not disk_path:
            return jsonify({'success': False,
                            'error': f'"{vm_name}" is not in the config and no disk image could be '
                                     'found for it, so a new entry cannot be created'}), 404

        rc, vm_id, err = run_config_manager(['next-vm-id'])
        if rc != 0:
            return jsonify({'success': False, 'error': err or 'Failed to allocate a VM ID'}), 500
        rc, ssh_port, err = run_config_manager(['next-ssh-port'])
        if rc != 0:
            return jsonify({'success': False, 'error': err or 'Failed to allocate an SSH port'}), 500
        rc, monitor_port, err = run_config_manager(['next-monitor-port'])
        if rc != 0:
            return jsonify({'success': False, 'error': err or 'Failed to allocate a monitor port'}), 500
        mac_address = clean.get('mac_address')
        if not mac_address:
            rc, mac_address, err = run_config_manager(['generate-mac', vm_id])
            if rc != 0:
                return jsonify({'success': False, 'error': err or 'Failed to generate a MAC address'}), 500

        add_args = ['add-vm', vm_id, vm_name,
                    clean.get('os_type', 'ubuntu'),
                    clean.get('memory', '8192'),
                    clean.get('cpu_cores', '4'),
                    clean.get('cpu_threads', '2'),
                    mac_address, disk_path, ssh_port, monitor_port,
                    clean.get('description', 'Virtual Machine')]
        rc, out, err = run_config_manager(add_args)
        if rc != 0:
            return jsonify({'success': False, 'error': err or out or 'Failed to add VM to config'}), 400
        return jsonify({'success': True, 'message': out or f'VM added to config: {vm_name} (ID: {vm_id})',
                        'created': True})

    rc, out, err = run_config_manager(['update-vm', vm_name] + pairs)
    if rc != 0:
        return jsonify({'success': False, 'error': err or out or 'Failed to update VM'}), 400

    return jsonify({'success': True, 'message': out or f'VM updated: {vm_name}'})


@app.route('/api/config-manager/remove', methods=['POST'])
def config_manager_remove_vm():
    """Remove a VM entry from the master config XML (delete)."""
    data = request.json or {}
    vm_name = str(data.get('vm_name') or '').strip()
    if not vm_name:
        return jsonify({'success': False, 'error': 'VM name required'}), 400

    rc, out, err = run_config_manager(['remove-vm', vm_name])
    if rc != 0:
        return jsonify({'success': False, 'error': err or out or 'Failed to remove VM'}), 400

    return jsonify({'success': True, 'message': out or f'VM removed from config: {vm_name}'})


@app.route('/api/vm/delete', methods=['POST'])
def delete_vm():
    """Delete a VM (domain and disk image)"""
    data = request.json
    vm_name = data.get('vm_name')
    vm_type = data.get('vm_type', 'libvirt')
    vm_status = data.get('status', '')

    if not vm_name:
        return jsonify({'success': False, 'error': 'VM name required'}), 400

    # Build deletion script
    # This will:
    # 1. Stop VM if running (forcefully)
    # 2. Undefine libvirt domain with NVRAM and snapshots (if libvirt)
    # 3. Find and delete disk images
    # 4. Verify deletion

    commands = []

    # For libvirt VMs - comprehensive cleanup
    if vm_type == 'libvirt':
        # Stop VM forcefully if running
        if 'running' in vm_status.lower():
            commands.append(f"echo 'Stopping VM {vm_name}...'")
            commands.append(f"virsh destroy {vm_name} 2>/dev/null || true")
            commands.append(f"sleep 1")  # Give it a moment to shut down

        # Undefine domain with all associated storage (NVRAM, snapshots, etc.)
        commands.append(f"echo 'Undefining libvirt domain {vm_name}...'")
        commands.append(f"virsh undefine {vm_name} --nvram --snapshots-metadata 2>/dev/null || virsh undefine {vm_name} 2>/dev/null || true")

        # Verify undefine succeeded
        commands.append(f"if virsh dominfo {vm_name} &>/dev/null; then echo 'WARNING: Failed to undefine domain'; else echo 'Domain undefined successfully'; fi")

    # For QEMU VMs and disk-image types - stop if running
    elif vm_type in ['qemu', 'disk-image']:
        commands.append(f"echo 'Stopping QEMU VM {vm_name}...'")
        # Get PID from ps output matching the disk image path
        commands.append(f"VM_PID=$(ps aux | grep '[q]emu-system-x86_64' | grep '{vm_name}' | awk '{{print $2}}' | head -1)")
        commands.append(f"if [ -n \"$VM_PID\" ]; then echo 'Found QEMU process PID: '$VM_PID; sudo kill -TERM $VM_PID 2>/dev/null || true; sleep 2; sudo kill -KILL $VM_PID 2>/dev/null || true; echo 'QEMU process stopped'; else echo 'No running QEMU process found for {vm_name}'; fi")

    # Find and delete disk images in common locations
    commands.append(f"echo 'Searching for disk images...'")
    disk_locations = [
        f"/data/vm-images/{vm_name}.img",
        f"/data/vm-images/{vm_name}.qcow2",
        f"/home/user/{vm_name}.img",
        f"/home/user/{vm_name}.qcow2"
    ]

    for disk_path in disk_locations:
        commands.append(f"if [ -f {disk_path} ]; then sudo rm -f {disk_path} && echo 'Deleted: {disk_path}' || echo 'Failed to delete: {disk_path}'; fi")

    # Also search for any other disk files with this VM name (including NVRAM files)
    commands.append(f"echo 'Searching for additional VM files...'")
    commands.append(f"find /data/vm-images /home/user /var/lib/libvirt/qemu/nvram -maxdepth 2 -name '{vm_name}*' -type f 2>/dev/null | while read file; do sudo rm -f \"$file\" && echo \"Deleted: $file\" || echo \"Failed to delete: $file\"; done")

    # Verify no processes are still running
    commands.append(f"if pgrep -f '{vm_name}' &>/dev/null; then echo 'WARNING: Processes still running for {vm_name}'; else echo 'No processes found'; fi")

    # Remove the entry from the master config so it stays in sync with reality
    commands.append(f"bash {shlex.quote(VM_CONFIG_MANAGER)} remove-vm {shlex.quote(vm_name)} 2>&1 || echo 'Note: no master config entry to remove'")

    # Final verification
    commands.append(f"echo '=== Deletion Summary ==='")
    commands.append(f"echo 'VM Name: {vm_name}'")
    commands.append(f"virsh list --all 2>/dev/null | grep -q '{vm_name}' && echo 'Status: STILL IN LIBVIRT' || echo 'Status: Removed from libvirt'")
    commands.append(f"find /data/vm-images /home/user -maxdepth 2 -name '{vm_name}*' -type f 2>/dev/null | head -1 | grep -q . && echo 'Disk: STILL EXISTS' || echo 'Disk: Deleted'")
    commands.append(f"echo 'VM {vm_name} deletion completed'")

    # Combine all commands with proper error handling
    cmd = " && ".join(commands)

    description = f"Deleting VM: {vm_name}"

    # Use async operation tracking
    operation_id = run_command_async(
        get_next_operation_id(),
        cmd,
        description
    )

    return jsonify({
        'success': True,
        'operation_id': operation_id
    })


@app.route('/api/terminal', methods=['POST'])
def open_terminal():
    """Open a host terminal emulator on the local X display, starting in $HOME.

    Detects the first available terminal emulator and launches it detached so
    it keeps running independently of this request. Requires an X session
    (the Flask host must have access to DISPLAY).
    """
    import shutil

    home = os.path.expanduser('~')

    # Preserve X11 environment so the terminal opens on the host display.
    env = os.environ.copy()
    if 'DISPLAY' not in env:
        env['DISPLAY'] = ':0'
    if 'XAUTHORITY' not in env and os.path.exists(os.path.join(home, '.Xauthority')):
        env['XAUTHORITY'] = os.path.join(home, '.Xauthority')

    # Candidate terminal emulators and the argv used to force $HOME as the
    # working directory. Tried in order; the first one installed is used.
    candidates = [
        ('gnome-terminal',  ['gnome-terminal', f'--working-directory={home}']),
        ('konsole',         ['konsole', '--workdir', home]),
        ('xfce4-terminal',  ['xfce4-terminal', f'--working-directory={home}']),
        ('mate-terminal',   ['mate-terminal', f'--working-directory={home}']),
        ('tilix',           ['tilix', '-w', home]),
        ('terminator',      ['terminator', '--working-directory', home]),
        ('xterm',           ['xterm']),
        ('x-terminal-emulator', ['x-terminal-emulator']),
    ]

    for binary, argv in candidates:
        if shutil.which(binary):
            try:
                subprocess.Popen(
                    argv,
                    cwd=home,
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                return jsonify({'success': True, 'terminal': binary})
            except Exception as e:
                return jsonify({'success': False,
                                'error': f'Failed to launch {binary}: {e}'}), 500

    return jsonify({'success': False,
                    'error': 'No terminal emulator found on host '
                             '(tried gnome-terminal, konsole, xfce4-terminal, '
                             'xterm, and others).'}), 404


@app.route('/api/displays')
def get_displays():
    """Return connected displays from xrandr --listmonitors"""
    monitors = []
    try:
        env = os.environ.copy()
        if 'DISPLAY' not in env:
            env['DISPLAY'] = ':0'
        xr = subprocess.run(
            'xrandr --listmonitors 2>/dev/null',
            shell=True, capture_output=True, text=True, timeout=5, env=env
        )
        for line in xr.stdout.splitlines():
            line = line.strip()
            if not line or line.lower().startswith('monitors:'):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            display_name = parts[-1]
            res = ''
            for p in parts:
                if 'x' in p and '/' in p:
                    try:
                        pw = p.split('x')[0].split('+')[0].split('/')[0]
                        ph = p.split('x')[1].split('+')[0].split('/')[0]
                        res = f"{pw}x{ph}"
                    except Exception:
                        pass
                    break
            monitors.append({'name': display_name, 'resolution': res, 'primary': '*' in line})
    except Exception:
        pass
    return jsonify({'monitors': monitors})


@app.route('/api/sriov/scheduling')
def get_sriov_scheduling():
    """Read EXEC_QUANTUM and PREEMPT_TIMEOUT for PF and VFs from sysfs"""
    import glob as _glob

    def _read(path, default='N/A'):
        try:
            with open(path) as f:
                return f.read().strip() or default
        except Exception:
            return default

    card_path = None
    for _p in _glob.glob('/sys/class/drm/card*/prelim_iov'):
        card_path = os.path.dirname(_p)
        break

    if not card_path:
        return jsonify({'error': 'Intel SR-IOV sysfs (prelim_iov) not found', 'pf': {}, 'vfs': []})

    iov_path = os.path.join(card_path, 'prelim_iov')
    pf_gt    = os.path.join(iov_path, 'pf', 'gt')
    result   = {
        'card': os.path.basename(card_path),
        'pf': {
            'exec_quantum':    _read(os.path.join(pf_gt, 'exec_quantum_ms')),
            'preempt_timeout': _read(os.path.join(pf_gt, 'preempt_timeout_us')),
        },
        'vfs': []
    }
    for vf_idx in range(1, 8):
        if not os.path.isdir(os.path.join(iov_path, f'vf{vf_idx}')):
            break
        vf_gt = os.path.join(iov_path, f'vf{vf_idx}', 'gt')
        result['vfs'].append({
            'id':              vf_idx,
            'exec_quantum':    _read(os.path.join(vf_gt, 'exec_quantum_ms')),
            'preempt_timeout': _read(os.path.join(vf_gt, 'preempt_timeout_us')),
        })
    return jsonify(result)


@app.route('/api/sriov/scheduling', methods=['POST'])
def set_sriov_scheduling():
    """Write PF/VF scheduling values into the selected vGPU profile XML, then re-provision SR-IOV."""
    import xml.etree.ElementTree as ET

    data = request.json or {}
    profile   = data.get('profile', '')
    scheduler = data.get('scheduler', '')
    num_vfs   = data.get('num_vfs', 2)
    ecc_mode  = data.get('ecc_mode', 'off')
    pf_data   = data.get('pf', {})
    vf_data   = data.get('vf', {})

    if not profile or not os.path.exists(profile):
        return jsonify({'success': False, 'error': 'Valid vGPU profile not selected'})

    num_vfs, err = validate_num_vfs(num_vfs)
    if err:
        return jsonify({'success': False, 'error': err}), 400

    # Same tier resolution as provisioning: the VF scheduling block is keyed by
    # the tier's VFCount, not by the value the user typed.
    tier, err = resolve_profile_tier(profile, num_vfs)
    if err:
        return jsonify({'success': False, 'error': err, 'undefined_tier': True}), 400
    num_vfs = tier['vf_count']

    try:
        tree = ET.parse(profile)
        root = tree.getroot()
        sched_profiles = root.find('.//vGPUScheduler/Profile')
        if sched_profiles is None:
            return jsonify({'success': False, 'error': 'No vGPUScheduler profile in XML'})

        # Default scheduler from XML if none chosen
        if not scheduler:
            scheduler = (root.findtext('.//vGPUScheduler/Default') or '').strip()

        sched_el = sched_profiles.find(scheduler) if scheduler else None
        if sched_el is None:
            sched_el = next(iter(sched_profiles), None)
        if sched_el is None:
            return jsonify({'success': False, 'error': 'Scheduler profile not found in XML'})

        ts = sched_el.find('GPUTimeSlicing')
        if ts is None:
            return jsonify({'success': False, 'error': 'GPUTimeSlicing block not found'})

        def set_text(parent, tag, val):
            if val in (None, ''):
                return
            el = parent.find(tag)
            if el is None:
                el = ET.SubElement(parent, tag)
            el.text = str(val)

        set_text(ts, 'PFExecutionQuantum',  pf_data.get('exec_quantum'))
        set_text(ts, 'PFPreemptionTimeout', pf_data.get('preempt_timeout'))

        # Write VF values into the block matching the selected VF count
        for vf in ts.findall('VFAttributes/VF'):
            if vf.get('VFCount') == str(num_vfs):
                set_text(vf, 'ExecutionQuantum',  vf_data.get('exec_quantum'))
                set_text(vf, 'PreemptionTimeout', vf_data.get('preempt_timeout'))

        tree.write(profile, encoding='utf-8', xml_declaration=True)
    except Exception as e:
        return jsonify({'success': False, 'error': f'Failed to update profile XML: {e}'})

    # Re-provision SR-IOV with the updated profile
    cmd = f"sudo {PROVISION_SCRIPT} -n {int(num_vfs)} -c {shlex.quote(profile)}"
    if scheduler:
        cmd += f" -s {shlex.quote(scheduler)}"
    if ecc_mode:
        cmd += f" -e {shlex.quote(ecc_mode)}"

    operation_id = run_command_async(
        get_next_operation_id(),
        cmd,
        'Updating scheduling config and re-provisioning SR-IOV'
    )
    return jsonify({'success': True, 'operation_id': operation_id})


if __name__ == '__main__':
    # Create templates directory if it doesn't exist
    os.makedirs('templates', exist_ok=True)
    os.makedirs('static', exist_ok=True)

    # Ensure DISPLAY is set for X11 GUI applications
    if 'DISPLAY' not in os.environ:
        os.environ['DISPLAY'] = ':0'

    # Allow root to access X display for QEMU windows
    subprocess.run("xhost +local:root > /dev/null 2>&1", shell=True)

    print(f"SR-IOV VM Manager GUI starting with DISPLAY={os.environ.get('DISPLAY')}")
    print(f"X authorization: Allowed root access via xhost")

    # init-config is idempotent (no-op once the file exists), so it's safe to
    # call unconditionally even if the debug reloader re-execs this block.
    ensure_master_config_ready()

    # Run the Flask app
    app.run(host='0.0.0.0', port=5000, debug=True, threaded=True)
