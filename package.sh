#!/bin/bash
# Builds a universal app and packages it for sharing (DMG + ZIP).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [ "${SKIP_BUILD:-0}" = "1" ]; then
	echo "==> Using existing $ROOT/build/MacBack.app"
else
	"$ROOT/build.sh"
fi

rm -rf "$DIST"
mkdir -p "$DIST" "$STAGE/dmg" "$STAGE/zip/MacBack"

cat > "$STAGE/Read Me.txt" <<'EOF'
MacBack
=======

A menu-bar app that remembers your personal wallpaper and restores it
automatically after your company replaces it (a configurable number of seconds
after login, and optionally after waking from sleep).

Install
-------

1. Drag MacBack.app into the Applications folder.
2. Open MacBack from Applications.
   If macOS says it cannot verify the developer (this ad-hoc build is not
   notarized), open System Settings > Privacy & Security, scroll down, click
   "Open Anyway" next to MacBack and confirm.
3. In System Settings > Wallpaper, pick your personal wallpaper (a still image,
   a dynamic wallpaper or an aerial video). MacBack remembers it automatically
   within a few seconds — there is nothing to configure in the app.
4. Click the arrow icon in the menu bar and choose Settings…:
   - Set the delay. Make it long enough for the corporate policy to finish
     (30–60 seconds is a good start).
   - Switch on "Start MacBack at login".
5. Move MacBack into Applications BEFORE enabling "Start MacBack at login":
   the login item remembers the app's current location.

After login, MacBack waits for the delay and restores your wallpaper. Whenever
it is running, MacBack keeps re-reading your wallpaper as you change it, so the
remembered one is always your latest personal choice. Company wallpapers
(Hexnode/MDM paths) are detected and never remembered over your own.

If the corporate wallpaper comes back while you are working, choose
"Restore Wallpaper Now" from the menu-bar menu.

Requires macOS 14 or later. Universal binary (Apple silicon and Intel).

Notes
-----

- Preferences: com.alvaro.MacBack
- Log: ~/Library/Logs/MacBack.log
- Remembered snapshot: ~/Library/Application Support/MacBack/WallpaperSnapshot.plist
- Restoring writes macOS's wallpaper store back and restarts its wallpaper
  engine; the desktop may redraw once.
- If an MDM profile continuously re-applies the corporate wallpaper, the
  profile wins.
- Quit from the menu-bar icon.
- Uninstall: turn off "Start MacBack at login", quit MacBack, delete it from
  Applications, then optionally run:
  defaults delete com.alvaro.MacBack
EOF

cp -R "$ROOT/build/MacBack.app" "$STAGE/dmg/"
cp "$STAGE/Read Me.txt" "$STAGE/dmg/"
ln -s /Applications "$STAGE/dmg/Applications"

cp -R "$ROOT/build/MacBack.app" "$STAGE/zip/MacBack/"
cp "$STAGE/Read Me.txt" "$STAGE/zip/MacBack/"

echo "==> Creating $DIST/MacBack.dmg"
hdiutil create \
	-volname "MacBack" \
	-srcfolder "$STAGE/dmg" \
	-ov \
	-format UDZO \
	"$DIST/MacBack.dmg" >/dev/null

echo "==> Creating $DIST/MacBack.zip"
ditto -c -k --norsrc --keepParent "$STAGE/zip/MacBack" "$DIST/MacBack.zip"

echo "==> Writing checksums"
(cd "$DIST" && shasum -a 256 MacBack.dmg MacBack.zip > SHA256SUMS.txt)

echo
echo "Share either file:"
echo "  $DIST/MacBack.dmg"
echo "  $DIST/MacBack.zip"
echo
echo "Note: this build is ad-hoc signed, so recipients must use"
echo "System Settings > Privacy & Security > Open Anyway on first launch."
