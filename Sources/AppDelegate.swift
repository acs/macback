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
            "--print-system-wallpaper", "--restore-remembered", "--restore-corporate",
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
        Log.write("Started (login=\(isLoginLaunch), loginItem=\(model.launchAtLogin))")

        // Keep the wallpaper snapshots current and react to company-wallpaper
        // changes; no timing configuration anymore.
        model.startRemembering()

        if !model.hasRememberedWallpaper {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowController.shared.show()
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
        let user = NSMenuItem(
            title: "Set User Wallpaper",
            action: #selector(restoreUserWallpaper),
            keyEquivalent: "r"
        )
        user.target = self
        menu.addItem(user)

        let corporate = NSMenuItem(
            title: "Set Corporate Wallpaper",
            action: #selector(restoreCorporateWallpaper),
            keyEquivalent: ""
        )
        corporate.target = self
        menu.addItem(corporate)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit MacBack",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        let about = NSMenuItem(
            title: "About MacBack",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)
    }

    // MARK: Actions

    @objc private func restoreUserWallpaper() {
        AppModel.shared.restoreNow(kind: .user, reason: "menu")
    }

    @objc private func restoreCorporateWallpaper() {
        AppModel.shared.restoreNow(kind: .corporate, reason: "menu")
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }

    /// Shows the small About window: menu-bar symbol, version, a one-line
    /// description and the open-source project link.
    @objc private func showAbout() {
        AboutWindowController.shared.show()
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

        // --restore-remembered / --apply restore the user wallpaper; they are
        // synchronous because the CLI process must not exit before the
        // wallpaper store is committed.
        if arguments.contains("--apply") || arguments.contains("--restore-remembered")
            || arguments.contains("--restore-corporate") {
            let kind: SnapshotKind = arguments.contains("--restore-corporate") ? .corporate : .user
            guard let snapshot = SystemWallpaper.loadSnapshot(kind: kind) else {
                print("error: \(SystemWallpaperError.snapshotMissing.localizedDescription)")
                return 1
            }
            if kind == .corporate {
                // Pause auto-restore until the user wallpaper shows again, same
                // as a menu restore would.
                UserDefaults.standard.set(true, forKey: SystemWallpaper.suppressAutoRestoreDefaultsKey)
            }
            do {
                switch try SystemWallpaper.restoreSnapshot(kind: kind) {
                case .restored:
                    print("Restored \(kind.title) wallpaper \(snapshot.summary).")
                case .alreadyCurrent:
                    print("\(kind.title.capitalized) wallpaper \(snapshot.summary) is already current.")
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
                print("MacBack will start at login and keep your wallpaper in place.")
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
