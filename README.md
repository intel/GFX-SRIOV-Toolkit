# Graphics SR-IOV Toolkit

## Introduction

The Graphics SR-IOV Toolkit provides a structured workflow for enabling and managing GPU virtualization on Intel® platforms using SR-IOV. It facilitates virtual machine creation, GPU resource provisioning, and runtime management to support GPU-accelerated workloads.
The toolkit includes automation scripts for configuring SR-IOV virtual functions, applying resource and scheduling policies, and launching virtual machines from predefined configurations—enabling consistent and reproducible deployment of graphics virtualization environments

## License

See [license.md](license.md) (MIT).

## Supported Platforms

| Platforms | Milestone Release | DKMS support | Kernel Support |
| --- | --- | --- | --- |
| Intel® Alder Lake | No | Yes | *v6.18 |
| Intel® Raptor Lake | No | Yes | *v6.18 |
| Intel® Meteor Lake | Yes | Yes | v6.18 |
| Intel® Amston Lake | Yes | Yes | v6.18 |
| Intel® Twinlake | No | Yes | *v6.18 |
| Intel® Bartlett Lake | Yes | Yes | v6.18 |
| Intel® Arrow Lake | Yes | Yes | v6.18 |
| Intel® Panther Lake | Yes | No | v6.18 |
| Intel® Wildcat Lake | Yes | No | v6.18 |
| Intel® Xeon Emerald Rapid + Intel® Arc™ Pro B60 Discrete GPU | No | No | *v6.18 |
| Intel® Bartlett Lake + Intel® Arc™ Pro B60 Discrete GPU | No | No | *v6.18 |

> **Disclaimer:** All listed platforms are supported. Platforms marked with `*v6.18` and `**without Milestone Release**` have been validated exclusively for GFX SR-IOV functionality and should not be considered as having full platform-level validation.

## Supported Operating Systems

| Role | Operating System |
| --- | --- |
| Host OS | Ubuntu 24.04.4 LTS |
| Guest OS | Ubuntu 24.04.4 LTS |
| Guest OS | Windows 11 Enterprise, version 24H2 |

## Prerequisites

- Host system is set up using the installer below: https://github.com/intel/edge-gfx-linux-installer

## Repository Structure

| Area | Description | Key Files |
| --- | --- | --- |
| **VM Provisioning** | Create and prepare guest virtual machine images | `scripts/create-vm-ubuntu.sh`<br>`scripts/create-vm-win.sh` |
| **SR-IOV Configuration** | Configure Virtual Functions (VFs) and GPU resource allocation | `scripts/provision-sriov.sh`<br>`config/vgpu-profile/` |
| **VM Launch** | Launch and manage VMs directly via QEMU or as libvirt-managed domains (`--virsh`) | `scripts/launch-vm.sh` |
| **Configuration Files** | Defines VM behavior and SR-IOV profiles | `config/vm-config/`<br>`config/vgpu-profile/` |
| **Validation & Debug** | Validate setup and inspect SR-IOV resource allocation | `test-suite/validate-environment.sh`<br>`test-suite/read-sriov-resources.sh` |


## Quick Start Guide

### Step 1: Enable SR-IOV

Enable SR-IOV with a specified number of Virtual Functions (VFs) and default resource profile:

```bash
sudo ./scripts/provision-sriov.sh -n 4
```

### Step 2: Create Virtual Machine

Create a VM image for Ubuntu or Windows:

```bash
# Ubuntu
sudo ./scripts/create-vm-ubuntu.sh

# Windows
sudo ./scripts/create-vm-win.sh -i <path-to-win.iso>
```

### Step 3: Launch Virtual Machine

Launch your VM using the QEMU-based launcher:

```bash
# Ubuntu
./scripts/launch-vm.sh -n 1 -d 3 -c config/vm-config/igpu-idv-config.xml

# Windows
./scripts/launch-vm.sh -n 1 -d 1 -c config/vm-config/igpu-idv-config.xml
```

### Step 4: Verify Resources and Validate Environment (Optional)

Run resource verification and pre-flight environment validation:

```bash
sudo ./test-suite/read-sriov-resources.sh
sudo ./test-suite/validate-environment.sh
```

## Documentation References

- **SR-IOV provisioning & profiles**: [config/vgpu-profile/README.md](config/vgpu-profile/README.md)
- **VM creation & launch options**: [scripts/README.md](scripts/README.md)
- **VM configuration schema**: [config/vm-config/README.md](config/vm-config/README.md)
- **Libvirt launch path**: [scripts/README.md](scripts/README.md)

