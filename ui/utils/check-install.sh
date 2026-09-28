#!/bin/bash
# SPDX-License-Identifier: MIT
# VM Manager Installation Checker

echo "========================================"
echo "  VM Manager Installation Checker"
echo "========================================"
echo ""

ERRORS=0

# Check Python3
echo -n "Checking Python 3... "
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
    echo "✓ Found (version $PYTHON_VERSION)"
else
    echo "✗ Not found"
    ((ERRORS++))
fi

# Check pip3
echo -n "Checking pip3... "
if command -v pip3 &> /dev/null; then
    echo "✓ Found"
else
    echo "✗ Not found"
    ((ERRORS++))
fi

# Check Flask
echo -n "Checking Flask... "
if python3 -c "import flask" &> /dev/null; then
    FLASK_VERSION=$(python3 -c "import flask; print(flask.__version__)" 2>&1)
    echo "✓ Installed (version $FLASK_VERSION)"
else
    echo "✗ Not installed"
    echo "  → Run: pip3 install -r requirements.txt"
    ((ERRORS++))
fi

echo ""

echo "Checking system requirements..."

# Check if running as root for certain operations
echo -n "  sudo access... "
if sudo -n true 2>/dev/null; then
    echo "✓ Available"
else
    echo "⚠ Requires password (normal for security)"
fi

# Check for Intel GPU
echo -n "  Intel GPU... "
if lspci | grep -i "VGA.*Intel" &> /dev/null; then
    GPU_INFO=$(lspci | grep -i "VGA.*Intel" | cut -d: -f3)
    echo "✓ Found:$GPU_INFO"
else
    echo "⚠ Not detected (SR-IOV features may not work)"
fi

# Check for SR-IOV support
echo -n "  SR-IOV support... "
if ls /sys/bus/pci/devices/*/sriov_totalvfs &> /dev/null; then
    SRIOV_DEVS=$(find /sys/bus/pci/devices -maxdepth 2 -name sriov_totalvfs 2>/dev/null | wc -l)
    echo "✓ Available on $SRIOV_DEVS device(s)"
else
    echo "⚠ Not detected"
fi

# Check debugfs
echo -n "  debugfs mounted... "
if mount | grep debugfs &> /dev/null; then
    echo "✓ Yes"
else
    echo "⚠ No (required for SR-IOV)"
    echo "  → Run: sudo mount -t debugfs none /sys/kernel/debug"
fi

# Check libvirt (optional)
echo -n "  libvirt/virsh... "
if command -v virsh &> /dev/null; then
    echo "✓ Installed"
else
    echo "○ Not installed (optional, needed for libvirt launch method)"
fi

# Check qemu
echo -n "  qemu-system-x86_64... "
if command -v qemu-system-x86_64 &> /dev/null; then
    echo "✓ Installed"
else
    echo "○ Not installed (needed for VM launch)"
fi

echo ""
echo "========================================"

if [ "$ERRORS" -eq 0 ]; then
    echo "✓ All checks passed!"
    echo ""
    echo "Ready to start VM Manager:"
    echo "  ./start.sh"
    echo ""
    echo "Or install as service:"
    echo "  sudo ./install-service.sh"
else
    echo "✗ Found $ERRORS error(s)"
    echo ""
    echo "Please fix the errors above before running VM Manager."
    echo ""
    echo "To install missing Python dependencies:"
    echo "  pip3 install -r requirements.txt"
fi

echo "========================================"
