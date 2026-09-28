#!/bin/bash
# SPDX-License-Identifier: MIT
# VM Manager Web UI Startup Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$(dirname "$SCRIPT_DIR")"  # Parent directory (ui/)
cd "$UI_DIR"

# Check if Python3 is installed
if ! command -v python3 &> /dev/null; then
    echo "Error: Python 3 is not installed"
    exit 1
fi

# Check if Flask is installed
if ! python3 -c "import flask" &> /dev/null; then
    echo "Flask is not installed. Installing dependencies..."
    pip3 install -r requirements.txt
fi

# Create directories if they don't exist
mkdir -p templates static

echo "========================================"
echo "  Starting SR-IOV VM Manager"
echo "========================================"
echo ""
echo "Access the UI at: http://localhost:5000"
echo ""
echo "Press Ctrl+C to stop the server"
echo ""

# Start the Flask app
python3 app.py
