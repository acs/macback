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

A menu-bar app that remembers your personal wallpaper and puts it back
automatically whenever your company's wallpaper shows up (at login, after
waking, or any other time).

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
4. Click the arrow icon in the menu bar:
   - "Set User Wallpaper" restores your personal wallpaper; "Set Corporate
     Wallpaper" restores the company one. Both are saved automatically while
     they are active, so both menu entries work out of the box.
   - In Settings… switch on "Start MacBack at login" and use
     "Open Wallpaper Settings…" if you want to change your wallpaper. That is
     all the settings there are — watching and restoring are automatic.
5. Move MacBack into Applications BEFORE enabling "Start MacBack at login":
   the login item remembers the app's current location.

MacBack reacts to what macOS actually shows: as soon as the company wallpaper
appears (at login or any other time), it puts your wallpaper back, within a few
seconds. Company wallpapers (Hexnode/MDM paths) are saved into their own slot,
never over your own.

If the corporate wallpaper comes back while you are working, choose
"Set User Wallpaper" from the menu-bar menu.

Requires macOS 14 or later. Universal binary (Apple silicon and Intel).

Notes
-----

- Preferences: com.alvaro.MacBack
- Log: ~/Library/Logs/MacBack.log
- Remembered user snapshot: ~/Library/Application Support/MacBack/WallpaperSnapshot.plist
- Remembered corporate snapshot: ~/Library/Application Support/MacBack/CorporateWallpaperSnapshot.plist
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
