#!/bin/bash
# Builds, installs to /Applications (or ~/Applications), and enables the login item.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh"

DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
	DEST_DIR="$HOME/Applications"
	mkdir -p "$DEST_DIR"
fi
APP="$DEST_DIR/MacBack.app"

echo "==> Stopping any running copy"
if [ -x "$APP/Contents/MacOS/MacBack" ]; then
	"$APP/Contents/MacOS/MacBack" --uninstall-agent || true
fi
if pgrep -f "$APP/Contents/MacOS/MacBack" >/dev/null 2>&1; then
	pkill -f "$APP/Contents/MacOS/MacBack" || true
	sleep 0.5
fi

echo "==> Installing to $APP"
rm -rf "$APP"
cp -R "$ROOT/build/MacBack.app" "$APP"
codesign --force --sign - --identifier "com.alvaro.MacBack" "$APP" >/dev/null

echo "==> Enabling login item"
if "$APP/Contents/MacOS/MacBack" --install-agent; then
	echo "Done. MacBack lives in the menu bar."
else
	echo "Login item could not be installed. Launching MacBack so you can enable it from Settings." >&2
	open "$APP"
fi

echo "Settings: menu bar icon -> Settings…"
echo "Log:      $HOME/Library/Logs/MacBack.log"
