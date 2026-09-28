#!/bin/bash
# Stop Flask app

echo "Stopping SR-IOV VM Manager..."

# Find and kill Flask processes
pkill -f "python3 app.py" || pkill -f "flask run"

# Wait a moment
sleep 1

# Check if any are still running
if pgrep -f "python3 app.py" > /dev/null || pgrep -f "flask run" > /dev/null; then
    echo "Force stopping remaining processes..."
    pkill -9 -f "python3 app.py"
    pkill -9 -f "flask run"
fi

# Verify
if pgrep -f "python3 app.py" > /dev/null || pgrep -f "flask run" > /dev/null; then
    echo "Failed to stop Flask app"
    exit 1
else
    echo "SR-IOV VM Manager stopped successfully"
fi

