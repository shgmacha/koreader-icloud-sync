#!/bin/bash
# Installs the KOReader iCloud bridge as a login agent.
# Re-running is safe: keeps the existing token, refreshes the script and agent.
set -euo pipefail

LABEL="com.koreader.icloudbridge"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON="/usr/bin/python3"
SYNC_ROOT="${SYNC_ROOT:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/KOReader}"
PORT="${PORT:-8765}"
CONFIG_DIR="$HOME/.config/koreader-icloud-bridge"
CONFIG="$CONFIG_DIR/config.json"
APP_DIR="$HOME/.local/share/koreader-icloud-bridge"
SCRIPT="$APP_DIR/icloud_bridge.py"
LOG="$HOME/Library/Logs/koreader-icloud-bridge.log"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 7)' \
  || { echo "Need $PYTHON 3.7+ (install Xcode Command Line Tools)"; exit 1; }

# /usr/bin/python3 is a shim that re-launches the real interpreter; run that directly.
REAL_PYTHON="$("$PYTHON" -c 'import os, sys
app = os.path.join(sys.base_prefix, "Resources/Python.app/Contents/MacOS/Python")
print(app if os.access(app, os.X_OK) else os.path.realpath(sys.executable))')"

# Full Disk Access is granted to this small launcher app, which spawns Python.
BRIDGE_APP="$HOME/Applications/KOReader iCloud Bridge.app"
LAUNCHER="$BRIDGE_APP/Contents/MacOS/koreader-icloud-bridge"

mkdir -p "$SYNC_ROOT" "$CONFIG_DIR" "$APP_DIR" "$(dirname "$PLIST")" "$(dirname "$LOG")"

if [[ -f "$CONFIG" ]]; then
  echo "Keeping existing config: $CONFIG"
else
  TOKEN="$(openssl rand -hex 16)"
  SYNC_ROOT="$SYNC_ROOT" PORT="$PORT" TOKEN="$TOKEN" "$PYTHON" - "$CONFIG" <<'EOF'
import json, os, sys
cfg = {"root": os.environ["SYNC_ROOT"], "port": int(os.environ["PORT"]),
       "bind": "0.0.0.0", "token": os.environ["TOKEN"]}
with open(sys.argv[1], "w") as f:
    json.dump(cfg, f, indent=2)
EOF
  chmod 600 "$CONFIG"
fi

cp "$SRC_DIR/icloud_bridge.py" "$SCRIPT"

# Build the launcher app only when missing or changed: rebuilding changes its
# signature, and macOS would then forget the Full Disk Access grant.
if [[ ! -x "$LAUNCHER" || "$SRC_DIR/launcher/main.c" -nt "$LAUNCHER" ]]; then
  echo "Building $BRIDGE_APP"
  mkdir -p "$BRIDGE_APP/Contents/MacOS"
  cat > "$BRIDGE_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.koreader.icloudbridge</string>
    <key>CFBundleName</key><string>KOReader iCloud Bridge</string>
    <key>CFBundleExecutable</key><string>koreader-icloud-bridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
  clang -O2 -o "$LAUNCHER" "$SRC_DIR/launcher/main.c"
  codesign --force --sign - --identifier com.koreader.icloudbridge "$BRIDGE_APP"
fi

sed -e "s|__LAUNCHER__|$LAUNCHER|" -e "s|__PYTHON__|$REAL_PYTHON|" -e "s|__SCRIPT__|$SCRIPT|" \
    -e "s|__CONFIG__|$CONFIG|" -e "s|__LOG__|$LOG|g" \
    "$SRC_DIR/$LABEL.plist" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
LOG_START=$(( $(wc -c < "$LOG" 2>/dev/null || echo 0) + 1 ))
launchctl bootstrap "gui/$(id -u)" "$PLIST"

read_cfg() { "$PYTHON" -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$CONFIG" "$1"; }
PORT="$(read_cfg port)"
TOKEN="$(read_cfg token)"

# Wait for the server, then prove it can actually read the iCloud folder.
for _ in $(seq 1 20); do
  curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.5
done
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Sync-Token: $TOKEN" "http://127.0.0.1:$PORT/manifest" || true)"

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '<your-mac-ip>')"

echo
if [[ "$STATUS" == "200" ]]; then
  echo "✅ Bridge running and can read: $SYNC_ROOT"
else
  echo "⚠️  Bridge answered /manifest with HTTP $STATUS. Check $LOG"
  if tail -c +"$LOG_START" "$LOG" 2>/dev/null | grep -q "Operation not permitted"; then
    echo "   macOS is blocking background access to iCloud Drive. To allow it:"
    echo "   1. In the Full Disk Access list that just opened, click +"
    echo "   2. Press ⌘⇧G, paste  ~/Applications  and choose 'KOReader iCloud Bridge'"
    echo "      (or drag it in from the Finder window that just opened)"
    echo "   3. Make sure its switch is on, then run this script again."
    open -R "$BRIDGE_APP" 2>/dev/null || true
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
  fi
fi
echo
echo "Enter these in KOReader → Tools → iCloud Sync:"
echo "   Server address:  $IP:$PORT"
echo "   Token:           $TOKEN"
echo
echo "Tip: reserve $IP for this Mac in your router so the address doesn't change."
