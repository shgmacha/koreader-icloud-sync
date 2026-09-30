#!/bin/bash
# Stops and removes the bridge login agent. Leaves your iCloud folder and config alone.
set -euo pipefail
LABEL="com.koreader.icloudbridge"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/.local/share/koreader-icloud-bridge"
rm -rf "$HOME/Applications/KOReader iCloud Bridge.app"
echo "Bridge removed. Config kept at ~/.config/koreader-icloud-bridge (delete it to reset the token)."
echo "You can also remove 'KOReader iCloud Bridge' from System Settings → Privacy & Security → Full Disk Access."
