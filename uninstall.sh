#!/bin/bash
# Stops MacBack, removes the login item and deletes the installed app.
set -euo pipefail

for APP in "/Applications/MacBack.app" "$HOME/Applications/MacBack.app"; do
	if [ -d "$APP" ]; then
		echo "==> Removing $APP"
		"$APP/Contents/MacOS/MacBack" --uninstall-agent || true
		pkill -f "$APP/Contents/MacOS/MacBack" 2>/dev/null || true
		sleep 0.5
		rm -rf "$APP"
	fi
done

echo "MacBack removed."
echo "Its preferences are still stored under com.alvaro.MacBack;"
echo "delete them with: defaults delete com.alvaro.MacBack"
