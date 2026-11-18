#!/bin/bash
set -euo pipefail

echo "Uninstalling CallTone Mac..."
if [ -d "/Applications/CallTone Mac.app" ]; then
    rm -rf "/Applications/CallTone Mac.app"
    echo "Removed /Applications/CallTone Mac.app"
else
    echo "/Applications/CallTone Mac.app not found."
fi

echo ""
echo "Note: Your personal ringtone files in ~/Library/Application Support/CallTone/Ringtones were preserved."
echo "To remove app settings and ringtones completely, run:"
echo "  rm -rf \"$HOME/Library/Application Support/CallTone\""
