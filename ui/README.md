# VM Manager Web UI

A web-based user interface for managing Intel GPU SR-IOV virtual machines. This tool provides an easy-to-use interface for provisioning SR-IOV, creating VMs, and launching them via either direct QEMU or libvirt.

## Features

- 🔧 **SR-IOV Provisioning**: Configure Intel GPU SR-IOV Virtual Functions with customizable profiles
- 📦 **VM Creation**: Create Ubuntu and Windows VMs with custom specifications, with automatic name suggestions (e.g. `ubuntu-guest` → `ubuntu-guest2`) and duplicate-name prevention
- ▶️ **VM Lifecycle Controls**: Start, Pause, Resume, Reboot, Stop, and Delete VMs
  - ⚠️ Clone and Hibernate are currently disabled (stubbed in the UI, not yet supported)
- 🗂️ **VM Config Manager**: Add, update, and remove VM entries in the master config (`Configure` tab), regenerate MAC addresses, and rebuild the config from the template
- 📊 **Real-time Monitoring**: Live status updates for SR-IOV and running VMs, including display mode and SPICE port for active VMs
- 📋 **Operations Log**: Track all operations with live output streaming
- 🖥️ **Host Terminal**: Open a terminal emulator on the host directly from the UI
- 🎨 **Modern UI**: Clean, responsive interface
- ⚙️ **VM Configuration**: Configure VMs through GUI (basic and advanced XML editing)

## Quick Start

```bash

# Install dependencies
./utils/check-install.sh

# Start the web UI
./utils/start.sh

```

Access at: **http://localhost:5000**

```bash
# Stop the web UI
./utils/stop.sh

```

### Prerequisites

- **Root / passwordless sudo** is required for most operations (SR-IOV provisioning, QEMU/virsh control, disk deletion). `check-install.sh` checks for this.
- For VM GUI windows to appear, **DISPLAY/XAUTHORITY must be forwarded** to the backend process, and `xhost +local:root` must be run beforehand on the host X session.
- The server binds to `0.0.0.0:5000` with Flask `debug=True` by default — only run this on a trusted/isolated network, since the Werkzeug debugger can allow remote code execution if reachable externally.

## Directory Structure

```
ui/
├── app.py                      # Flask backend API server
├── requirements.txt            # Python dependencies
├── README.md                   # This file
├── templates/
│   └── index.html              # Frontend web UI
└── utils/
    ├── start.sh                # Start the web UI
    ├── stop.sh                 # Stop the web UI
    └── check-install.sh        # Verify installation

```

## Configuration

The UI automatically detects toolkit scripts from the parent directory. No manual path configuration needed.

**Port**: Default 5000 (change in `app.py`, in the `app.run(...)` call, if needed)

## Troubleshooting

Incase of python environment issues, create a virtual environment and activate it:

```bash
python3 -m venv venv
source venv/bin/activate
```

Common issues:
- **SR-IOV fails**: Check debugfs is mounted, Intel GPU detected
- **VM creation fails**: Check disk space and ISO paths
- **Can't access UI**: Check port 5000 is not in use, firewall allows it
- **VM starts but no window appears**: DISPLAY/XAUTHORITY isn't forwarded to the backend, or `xhost +local:root` wasn't run
- **Clone / Hibernate buttons do nothing**: intentionally disabled for now, not a bug
- **"Device or resource busy" when creating a second VM**: another VM is already using that GPU virtual function; check `num_vfs` and how many VFs are already claimed

