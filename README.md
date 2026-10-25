# MacBack

MacBack remembers your personal wallpaper and the company wallpaper and shows
the one configured by you.

## Install from releases

1. Download the latest [release](https://github.com/acs/macback/releases/latest)
   — `MacBack.dmg` (preferred) or `MacBack.zip`.
2. Drag **MacBack.app** into Applications and open it.
3. The build is ad-hoc signed, so macOS says it cannot verify the developer
   once: open **System Settings → Privacy & Security**, click **Open Anyway**
   next to MacBack and confirm.
4. Pick your personal wallpaper in **System Settings → Wallpaper**. MacBack
   remembers and restores it automatically.
5. Click the arrow icon in the menu bar → **Settings… → Start MacBack at
   login**.

Requires macOS 14 or later. Universal binary (Apple silicon and Intel).

Details on configuration, behaviour and troubleshooting are in
[REFERENCE.md](REFERENCE.md).

## Build & install from source

Requires the Xcode **Command Line Tools** only — no Xcode project:

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
