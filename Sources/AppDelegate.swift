import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let commandLineFlags = [
            "--install-agent", "--uninstall-agent", "--apply",
            "--print-system-wallpaper", "--remember-current", "--restore-remembered",
        ]
        if arguments.contains(where: commandLineFlags.contains) {
            exit(runCommandLine(arguments))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstance.acquire() else {
            Log.write("Another MacBack instance is already running; activating it and exiting.")
            NSRunningApplication
                .runningApplications(withBundleIdentifier: AppInfo.bundleID)
                .first?
                .activate()
            exit(0)
        }

        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        installStatusItem()

        let model = AppModel.shared
        model.refreshLaunchAtLogin()

        let isLoginLaunch = CommandLine.arguments.contains("--login")
        Log.write("Started (login=\(isLoginLaunch), delay=\(model.delaySeconds)s, loginItem=\(model.launchAtLogin))")

        if isLoginLaunch {
            model.scheduleRestore(after: model.delaySeconds, reason: "login")
        }

        // Keep the remembered wallpaper current automatically.
        model.startRemembering()

        if !model.hasRememberedWallpaper {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowController.shared.show()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let model = AppModel.shared
                // First make sure the snapshot tracks any change the user made
                // before sleeping, then optionally restore.
                model.refreshRememberedWallpaper(reason: "wake")
                guard model.changeOnWake else { return }
                Log.write("Woke from sleep; scheduling wallpaper restore in \(model.delaySeconds)s.")
                model.scheduleRestore(after: model.delaySeconds, reason: "wake")
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "arrow.uturn.backward.circle",
                accessibilityDescription: "MacBack"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "MacBack"
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        Log.write("Status item installed (button available: \(item.button != nil)).")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        let model = AppModel.shared

        let restore = NSMenuItem(
            title: "Restore Wallpaper Now",
            action: #selector(restoreWallpaperNow),
            keyEquivalent: "r"
        )
        restore.target = self
        menu.addItem(restore)

        let remember = NSMenuItem(
            title: "Remember Current Wallpaper",
            action: #selector(rememberCurrentWallpaper),
            keyEquivalent: ""
        )
        remember.target = self
        menu.addItem(remember)

        if let remembered = model.rememberedSummary {
            let line = NSMenuItem(
                title: "Remembered: \(remembered)",
                action: nil,
                keyEquivalent: ""
            )
            line.isEnabled = false
            line.indentationLevel = 1
            menu.addItem(line)
        }

        if let name = model.lastRestoreName, let date = model.lastRestoreAt {
            let last = NSMenuItem(
                title: "Last restore: \(name), \(date.formatted(date: .omitted, time: .shortened))",
                action: nil,
                keyEquivalent: ""
            )
            last.isEnabled = false
            last.indentationLevel = 1
            menu.addItem(last)
        }

        menu.addItem(.separator())

        let wallpaperSettings = NSMenuItem(
            title: "Open Wallpaper Settings…",
            action: #selector(openWallpaperSettings),
            keyEquivalent: ""
        )
        wallpaperSettings.target = self
        menu.addItem(wallpaperSettings)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let log = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit MacBack",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    // MARK: Actions

    @objc private func restoreWallpaperNow() {
        AppModel.shared.restoreNow(reason: "menu")
    }

    @objc private func rememberCurrentWallpaper() {
        AppModel.shared.rememberCurrentNow()
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openWallpaperSettings() {
        AppModel.shared.openWallpaperSettings()
    }

    @objc private func openLog() {
        Log.reveal()
    }

    // MARK: Main menu

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: AppInfo.name, action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MacBack", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: Command line

    private func runCommandLine(_ arguments: [String]) -> Int32 {
        if arguments.contains("--print-system-wallpaper") {
            let screens = NSScreen.screens
            if screens.isEmpty {
                print("No displays reported.")
            }
            for (index, screen) in screens.enumerated() {
                do {
                    let choice = try SystemWallpaper.currentChoice(for: screen)
                    let image = choice.imageURL?.path ?? ""
                    let managed = isManagedFlag(choice)
                    print("display \(index) (\(screen.localizedName)): \(choice.provider) | \(choice.summary)\(managed ? " [managed]" : "") | \(image)")
                } catch {
                    print("display \(index) (\(screen.localizedName)): error: \(error.localizedDescription)")
                }
            }
            return 0
        }

        if arguments.contains("--remember-current") {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                print("error: no display is available.")
                return 1
            }
            do {
                let snapshot = try SystemWallpaper.rememberCurrent(for: screen)
                print("Remembered \(snapshot.summary) (provider \(snapshot.provider))")
                if snapshot.looksManaged {
                    print("warning: this looks like a company-managed wallpaper.")
                }
                return 0
            } catch {
                print("error: \(error.localizedDescription)")
                return 1
            }
        }

        // --restore-remembered and --apply both restore synchronously: the CLI
        // process must not exit before the wallpaper store is committed.
        if arguments.contains("--restore-remembered") || arguments.contains("--apply") {
            guard let snapshot = SystemWallpaper.loadSnapshot() else {
                print("error: \(SystemWallpaperError.snapshotMissing.localizedDescription)")
                return 1
            }
            do {
                switch try SystemWallpaper.restoreSnapshot() {
                case .restored:
                    print("Restored \(snapshot.summary).")
                case .alreadyCurrent:
                    print("\(snapshot.summary) is already current.")
                }
                return 0
            } catch {
                print("error: \(error.localizedDescription)")
                return 1
            }
        }

        if arguments.contains("--install-agent") {
            guard let executable = Bundle.main.executableURL else {
                print("error: cannot locate the MacBack executable.")
                return 1
            }
            do {
                try LaunchAgent.install(executable: executable, runningFromAgent: false)
                print("Installed login item at \(LaunchAgent.plistURL.path)")
                print("MacBack will start at login and restore the wallpaper after \(AppModel.shared.delaySeconds) s.")
                return 0
            } catch {
                print("error: \(error.localizedDescription)")
                return 1
            }
        }

        if arguments.contains("--uninstall-agent") {
            do {
                try LaunchAgent.uninstall(runningFromAgent: false)
                print("Removed MacBack login item.")
                return 0
            } catch {
                print("error: \(error.localizedDescription)")
                return 1
            }
        }

        return 0
    }

    private func isManagedFlag(_ choice: SystemWallpaper.Choice) -> Bool {
        let provider = choice.provider.lowercased()
        return provider.contains("hexnode") || provider.contains("mdm")
    }
}
