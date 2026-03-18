# ECG GFX SR-IOV Toolkit Scripts

This directory contains the VM lifecycle and SR-IOV provisioning scripts used by the toolkit.

## Script Index

- `create-vm-ubuntu.sh`: Create/install an Ubuntu VM image (or boot an existing one)
- `create-vm-win.sh`: Create/install a Windows VM image
- `provision-sriov.sh`: Enable/disable SR-IOV and apply vGPU resource profiles
- `launch-vm.sh`: Launch VMs from XML configuration

## Prerequisites

- Linux host with KVM/QEMU support
- Intel GPU platform with SR-IOV capability (for VF workflows)
- `xmllint` (for XML-based scripts)
- `sudo` access for provisioning/host setup tasks
- OVMF firmware available (for UEFI VM boot)

## 1) Ubuntu VM Creation

Script: `scripts/create-vm-ubuntu.sh`

Purpose:
- Creates a new Ubuntu VM from local ISO or auto-download URL
- Supports unattended install flow and optional post-boot SR-IOV setup
- Can also boot an existing image (`--vm-image` mode)

Common options:
- `-h, --help`: Show help
- `-i, --iso-path FILE`: Ubuntu installer ISO path (optional if using download URL/default)
- `--download_url URL`: ISO URL (default points to Ubuntu 24.04.4 desktop)
- `-o, --output-dir DIR`: Output directory for images/downloads (default: `./vm_images`)
- `-n, --vm-name NAME`: VM name/image prefix (default: `ubuntu24_1`)
- `-s, --vm-size SIZE`: Disk size (default: `50G`)
- `-m, --memory MB`: Memory in MB (default variable: `8192`)
- `-c, --vcpus NUM`: vCPU count (default: `4`)
- `--vm-username NAME`: Guest username (default: `user`)
- `--vm-password PASS`: Guest password (default: `user1234`)
- `--vm-image PATH`: Existing image path (required for direct boot or `--force-install`)
- `--force-install`: Reinstall using provided `--vm-image`
- `--vm-setup`: Run `installer/install-host.sh virtualization --automated` inside guest
- `--vm-reboot`: Reboot after `--vm-setup` (otherwise guest is shut down)
- `--proxy URL`: Proxy pass-through for guest setup/downloads

Examples:
```bash
# Simplest flow (uses defaults and auto-downloads Ubuntu ISO)
./scripts/create-vm-ubuntu.sh

# Local ISO with defaults
./scripts/create-vm-ubuntu.sh -i ./ubuntu-24.04.4-desktop-amd64.iso

# Local ISO + provisioning in guest + reboot
./scripts/create-vm-ubuntu.sh \
  -i /path/to/ubuntu-24.04.4-desktop-amd64.iso \
  --vm-username myuser --vm-password MyPass123 \
  --vm-setup --vm-reboot

# Boot existing image only
./scripts/create-vm-ubuntu.sh --vm-image /path/to/ubuntu.img
```

## 2) Windows VM Creation

Script: `scripts/create-vm-win.sh`

Purpose:
- Creates a Windows VM disk and boots Windows installer ISO with UEFI + TPM
- Supports automatic boot-key press for installer media via QMP

Common options:
- `-h, --help`: Show help
- `-i, --iso-path FILE`: Windows installer ISO path (required)
- `-n, --vm-name NAME`: VM name (default: `win11_1`)
- `-o, --output-dir DIR`: Output directory (default: `./vm_images`)
- `-s, --vm-size SIZE`: Disk size (default: `100G`)
- `-m, --memory MB`: Memory in MB (default: `4096`)
- `-c, --vcpus NUM`: vCPU count (default: `4`)
- `--auto-press-boot-key`: Send keypress automatically at boot prompt
- `--os-variant NAME`: Variant label (default: `win11`)

Examples:
```bash
# Basic install
./scripts/create-vm-win.sh -i /path/to/windows.iso

# Higher memory/CPU
./scripts/create-vm-win.sh -i /path/to/windows.iso -m 8192 -c 8
```

## 3) SR-IOV Provisioning

Script: `scripts/provision-sriov.sh`

Purpose:
- Enables/disables GPU SR-IOV VFs
- Applies resource and scheduler settings from XML profile

Common options:
- `-h, --help`: Show help
- `-n, --num-vfs NUM`: Number of VFs to enable (`1`, `2`, `3`, or `4`)
- `-s, --scheduler NAME`: Scheduler profile (default from XML)
- `-e, --ecc MODE`: ECC mode `on|off` (default: `off`)
- `-c, --config FILE`: Profile XML file
- `--pci-device DEVICE`: Explicit PCI device (auto-detected if omitted)
- `--disable`: Disable SR-IOV and remove VFs

Examples:
```bash
# Enable 4 VFs
sudo ./scripts/provision-sriov.sh -n 4

# Enable 2 VFs with custom file reading from xml
sudo ./scripts/provision-sriov.sh -n 2 -c ../config/vgpu-profile/bmg-idv-config.xml

# Disable SR-IOV
sudo ./scripts/provision-sriov.sh --disable
```

Profile details:
- `config/vgpu-profile/README.md`

## 4) VM Launch From XML

Script: `scripts/launch-vm.sh`

Purpose:
- Launches one or many VMs defined in XML
- Supports launching all VMs, first N VMs, or a specific VM ID
- Supports dynamic/tap or localhost/user networking modes

Common options:
- `-h, --help`: Show help
- `-c, --config FILE`: VM XML config file (required)
- `-n, --num-vms NUM`: Launch first `NUM` VMs
- `-d, --vm-id ID`: Launch only VM with specified ID
- `--network MODE`: `localhost` (default) or `dynamic`

Examples:
```bash
# Launch all VMs from config
./scripts/launch-vm.sh -c config/vm-config/bmg-idv-config.xml

# Launch only VM ID 3
./scripts/launch-vm.sh -c config/vm-config/bmg-idv-config.xml -d 3

# Launch one VM in dynamic networking mode
./scripts/launch-vm.sh -c config/vm-config/bmg-idv-config.xml -n 1 --network dynamic
```

VM config details:
- `config/vm-config/README.md`

## Typical End-to-End Flow

```bash
# 1) Create VM image (Ubuntu or Windows)
./scripts/create-vm-ubuntu.sh
# or
./scripts/create-vm-win.sh -i /path/to/windows.iso

# 2) Provision SR-IOV on host
sudo ./scripts/provision-sriov.sh -n 4

# 3) Launch VM(s) from XML
./scripts/launch-vm.sh -c config/vm-config/bmg-idv-config.xml -n 1
```

## Verification Utilities

SR-IOV readback/validation scripts are in `test-suite/`:
- `test-suite/read-sriov-resources.sh`
- `test-suite/validate-environment.sh`

## License

See `../license.md`.
