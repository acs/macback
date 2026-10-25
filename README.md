# MacBack

A tiny macOS menu-bar app that remembers your personal wallpaper and restores
it automatically after your company replaces it — a configurable number of
seconds after login and, optionally, after waking from sleep.

No Xcode project is required — it builds with the Xcode **Command Line Tools** alone.

## The company-wallpaper use case

1. Set your personal wallpaper in **System Settings → Wallpaper**. This can be a
   still image, a dynamic wallpaper, or an aerial video.
2. While MacBack is running, it watches the wallpaper and saves a snapshot of it
   automatically (within a few seconds of a change) as long as it does not look
   company-managed. No button pressing needed — although the menu and the
   settings window have a **Remember Current Wallpaper** action as a fallback.
   Use **Open Wallpaper Settings…** to change it first.
3. At login, your company's management software changes the wallpaper to the
   corporate one. After the configured delay, MacBack restores your wallpaper.
4. If the company changes it again later in the day, choose
   **Restore Wallpaper Now** from the menu-bar menu.

Aerial videos, dynamic wallpapers, and still images are all supported: MacBack
restores the exact choice by writing macOS's own wallpaper store and restarting
its wallpaper engine.

## Why "at login" rather than "at boot"?

macOS only allows a user's wallpaper to be changed from inside that user's logged-in GUI
session. Before login there is no desktop to change. The earliest reliable moment is
therefore login, which is what MacBack hooks into using a per-user LaunchAgent.

## Build & install

```bash
./build.sh      # produces build/MacBack.app
./install.sh    # copies to /Applications (or ~/Applications) and enables login start
```

`install.sh` also signs the app ad-hoc and installs
`~/Library/LaunchAgents/com.alvaro.MacBack.agent.plist` so it starts at login.

To remove everything:

```bash
./uninstall.sh
```

## Configure

Click the arrow icon in the menu bar → **Settings…**

- **Delay after login** – seconds to wait after login before restoring the
  wallpaper. For the company-wallpaper use case, make this long enough for the
  management software to finish (30–60 seconds is a reasonable starting point).
- **Restore again after waking from sleep** – uses the same delay.
- **Start MacBack at login** – installs/removes the LaunchAgent.
- **Restore Wallpaper Now** – restores immediately without waiting.
- **Remember Current Wallpaper** – saves the current system wallpaper choice
  manually (normally unnecessary; it happens automatically).
- **Open Wallpaper Settings…** – opens the system wallpaper pane so you can pick
  your personal wallpaper there.

There is deliberately no wallpaper *selection* in the app: the wallpaper it
restores is simply your own last personal wallpaper as seen while MacBack runs.

## How it works

1. At login, launchd starts `MacBack.app/Contents/MacOS/MacBack --login`.
2. MacBack runs a small watcher that re-reads the system wallpaper store every
   ~10 seconds. Whenever the current wallpaper does not look company-managed
   and differs from the saved snapshot, it snapshots it. This keeps the saved
   wallpaper equal to your latest personal choice, and never overwrites it with
   the corporate one (built-ins from the user home/sidebar are safe; anything
   under `/Library/Application Support` outside `com.apple`, or with
   `Hexnode`/`MDM` in the provider or path, is treated as managed).
3. After the configured delay, MacBack writes the saved store back to
   `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` and
   restarts `WallpaperAgent`. It verifies the result and rolls the previous
   store back if macOS rejects it.
4. It stays in the menu bar so you can restore manually or change settings.

A per-user file lock keeps a second copy from running (for example when the login item
starts while you already launched the app by hand).

### Files and CLI

| Item | Location |
| --- | --- |
| Preferences | `defaults read com.alvaro.MacBack` |
| App log | `~/Library/Logs/MacBack.log` |
| launchd log | `~/Library/Logs/MacBack.launchd.log` |
| Remembered wallpaper snapshot | `~/Library/Application Support/MacBack/WallpaperSnapshot.plist` |
| Store backup made before a restore | `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist.macback-backup` |
| Login item | `~/Library/LaunchAgents/com.alvaro.MacBack.agent.plist` |

Useful command-line flags:

```bash
MacBack.app/Contents/MacOS/MacBack --apply                  # restore the remembered wallpaper now
MacBack.app/Contents/MacOS/MacBack --print-system-wallpaper # show macOS's provider/choice (works for aerials)
MacBack.app/Contents/MacOS/MacBack --remember-current       # save the current system wallpaper manually
MacBack.app/Contents/MacOS/MacBack --restore-remembered     # restore the saved system wallpaper
MacBack.app/Contents/MacOS/MacBack --install-agent          # enable start at login
MacBack.app/Contents/MacOS/MacBack --uninstall-agent        # disable start at login
```

## Distributing to colleagues

```bash
./package.sh
```

creates:

| File | Use |
| --- | --- |
| `dist/MacBack.dmg` | Preferred: open it, drag MacBack into Applications |
| `dist/MacBack.zip` | Alternative if DMG transfer is blocked |
| `dist/SHA256SUMS.txt` | Checksums for the two files above |

Both are universal binaries (Apple silicon and Intel) and require macOS 14+.

The build is **ad-hoc signed**, not notarized by Apple, so each recipient has to
approve it once:

1. Drag MacBack to Applications.
2. Try to open it.
3. System Settings → Privacy & Security → **Open Anyway**, then confirm.
4. Menu-bar icon → Settings… → enable **Start MacBack at login**.

To remove that warning you need an Apple Developer Program membership and a
“Developer ID Application” certificate. Then sign with the hardened runtime,
notarize and staple before packaging:

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" build/MacBack.app
ditto -c -k --keepParent build/MacBack.app /tmp/MacBack-notarize.zip
xcrun notarytool submit /tmp/MacBack-notarize.zip --keychain-profile AC_PASSWORD --wait
xcrun stapler staple build/MacBack.app
SKIP_BUILD=1 ./package.sh
```

Create the `AC_PASSWORD` profile once with
`xcrun notarytool store-credentials AC_PASSWORD`.

## Notes and limitations

- The timer is wall-clock time. If the Mac is asleep when it should fire, it fires when
  the app next gets to run; enable the wake option to also refresh after sleep.
- The restore happens once after login (and once after wake if enabled). If the company
  applies its wallpaper later, use **Restore Wallpaper Now**. Increase the
  delay if the corporate policy usually arrives late.
- If an MDM profile continuously re-applies the corporate wallpaper, the profile wins;
  MacBack can only restore when the profile is not actively overriding it.
- Restoring writes macOS's private wallpaper store and restarts `WallpaperAgent`.
  This is not a documented Apple interface, so a future macOS update could change the
  format. MacBack keeps a backup of the previous store and rolls back if verification
  fails. The desktop may redraw or flash briefly while the engine restarts.
- The automatic watcher never saves a wallpaper it detects as company-managed. In the
  unlikely case that your own wallpaper is misclassified (for example it lives under
  `/Library/Application Support`), use **Remember Current Wallpaper** from the menu to
  save it manually.
- The app is ad-hoc signed for local use.
- Builds are universal (`arm64` + `x86_64`); every Mac needs macOS 14 or later.
- If you change the bundle identifier, update `AppInfo.bundleID` and the LaunchAgent
  label together.
