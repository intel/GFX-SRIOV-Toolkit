# Graphics SR-IOV Toolkit

## Introduction

Toolkit for Intel GPU SR-IOV VM creation, provisioning, launch, and GPU resource inspection.

This repository provides a practical workflow for running GPU-accelerated virtual machines on Intel graphics hardware with SR-IOV:

1. Create or prepare VM images
2. Enable GPU SR-IOV VFs and apply GPU resource and scheduler policies.
3. Launch VMs from XML configuration

## License

See [license.md](license.md) (MIT).

## Supported Platforms
- [Intel(R) Xeon Emerald Rapids](https://www.intel.com/content/www/us/en/ark/products/codename/130707/products-formerly-emerald-rapids.html)
- [Intel(R) Arc(TM) Pro B60 Discrete GPU](https://www.intel.com/content/www/us/en/products/sku/243916/intel-arc-pro-b60-graphics/specifications.html)

## Supported Host Operating System

- Ubuntu 24.04.4 LTS

## Supported Guest Operating System

- Ubuntu 24.04.4 LTS
- Windows 11 Enterprise, version 24H2

## Prerequisites

- Host system is set up using the installer below: https://github.com/intel/edge-gfx-linux-installer

## Repository Layout

- `scripts/create-vm.sh`: create VM image and boot installer ISO
- `scripts/provision-sriov.sh`: configure SR-IOV VFs and GPU resource partitioning
- `scripts/launch-vm.sh`: launch VMs from pre-configured XML configuration file
- `scripts/read-sriov-resources.sh`: inspect PF/VF allocations from debugfs
- `config/vgpu-profile/`: SR-IOV profile XML (`bmg-idv-profile.xml`)
- `config/vm-config/`: VM launch XML (`bmg-idv-config.xml`)


## Quick Start

Typical end-to-end flow:

```bash
# 1) Create or prepare guest image
#Ubuntu VM Creation:
sudo ./scripts/create-vm-ubuntu.sh
#Windows VM Creation:
sudo ./scripts/create-vm-win.sh -i <path-to-win.iso>

# 2) Enable SR-IOV with a VF count/profile
sudo ./scripts/provision-sriov.sh -n 4

# 3) Launch VMs from XML config
#Launch Ubuntu VM
./scripts/launch-vm.sh -n 1 -d 3 -c config/vm-config/bmg-idv-config.xml
#Launch Windows VM
./scripts/launch-vm.sh -n 1 -d 1 -c config/vm-config/bmg-idv-config.xml
```

Step references for detailed documentation:

- Step 1 (Create VM): [scripts/README.md](scripts/README.md)
- Step 2 (Provision SR-IOV and scheduler/resource policy): [config/vgpu-profile/README.md](config/vgpu-profile/README.md)
- Step 3 (Launch VM and runtime options): [scripts/README.md](scripts/README.md)
- Step 4 (Read applied PF/VF resources): [scripts/README.md](scripts/README.md)

Configuration schema references:

- vGPU profile XMLs: [config/vgpu-profile/README.md](config/vgpu-profile/README.md)
- VM XML definitions: [config/vm-config/README.md](config/vm-config/README.md)

## Validation

Validation is available as an executable script in `test-suite/validate-environment.sh`.

Step 4 verification (read back applied PF/VF resource values):

```bash
sudo ./test-suite/read-sriov-resources.sh
```

Run pre-flight validation:

```bash
sudo ./test-suite/validate-environment.sh
```
