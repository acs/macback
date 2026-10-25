import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: Settings

    @Published var delaySeconds: Int {
        didSet { defaults.set(delaySeconds, forKey: Keys.delaySeconds) }
    }

    @Published var changeOnWake: Bool {
        didSet { defaults.set(changeOnWake, forKey: Keys.changeOnWake) }
    }

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var statusText: String = "Ready."
    @Published private(set) var lastRestoreAt: Date?
    @Published private(set) var lastRestoreName: String?
    @Published private(set) var lastErrorText: String?
    @Published private(set) var rememberedSummary: String?
    @Published private(set) var rememberedCapturedAt: Date?

    // MARK: State

    private enum Keys {
        static let delaySeconds = "delaySeconds"
        static let changeOnWake = "changeOnWake"
        static let lastRestoreAt = "lastRestoreAt"
        static let lastRestoreName = "lastRestoreName"
        // Keys written by earlier versions, read for a smooth upgrade.
        static let legacyLastAppliedAt = "lastAppliedAt"
        static let legacyLastAppliedName = "lastAppliedName"
    }

    private let defaults: UserDefaults
    private var pendingRestore: Task<Void, Never>?
    private var restoreInProgress = false
    private var rememberingTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        delaySeconds = Self.intValue(defaults, Keys.delaySeconds, fallback: 30)
        changeOnWake = Self.boolValue(defaults, Keys.changeOnWake, fallback: false)
        launchAtLogin = LaunchAgent.isInstalled
        lastRestoreAt = (defaults.object(forKey: Keys.lastRestoreAt) as? Date)
            ?? (defaults.object(forKey: Keys.legacyLastAppliedAt) as? Date)
        lastRestoreName = defaults.string(forKey: Keys.lastRestoreName)
            ?? defaults.string(forKey: Keys.legacyLastAppliedName)

        let snapshot = SystemWallpaper.loadSnapshot()
        rememberedSummary = snapshot?.summary
        rememberedCapturedAt = snapshot?.capturedAt
    }

    var hasRememberedWallpaper: Bool {
        SystemWallpaper.loadSnapshot() != nil
    }

    // MARK: Restoring

    /// Restores the remembered wallpaper now. Works for still images, dynamic
    /// wallpapers and aerial videos alike: the saved copy of macOS's wallpaper
    /// store is written back and macOS's wallpaper engine re-applies the exact
    /// choice, which can make the desktop redraw once.
    func restoreNow(reason: String = "manual") {
        guard let snapshot = SystemWallpaper.loadSnapshot() else {
            statusText = "No wallpaper remembered yet. Set your wallpaper in System Settings; MacBack will pick it up automatically."
            Log.write("Nothing to restore yet [\(reason)]: no snapshot exists.")
            return
        }

        guard !restoreInProgress else {
            statusText = "A wallpaper restore is already in progress."
            return
        }

        restoreInProgress = true
        statusText = "Restoring \(snapshot.summary)…"
        Log.write("Restoring wallpaper '\(snapshot.summary)' (provider \(snapshot.provider)) [\(reason)]")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try SystemWallpaper.restoreSnapshot()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.restoreInProgress = false
                    switch result {
                    case .restored:
                        self.finishRestore(name: snapshot.summary, reason: reason)
                    case .alreadyCurrent:
                        self.lastErrorText = nil
                        self.statusText = "\(snapshot.summary) is already showing."
                        Log.write("Remembered wallpaper '\(snapshot.summary)' already current [\(reason)]")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.restoreInProgress = false
                    self.lastErrorText = error.localizedDescription
                    self.statusText = "Could not restore the wallpaper: \(error.localizedDescription)"
                    Log.write("ERROR [\(reason)]: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finishRestore(name: String, reason: String) {
        let now = Date()
        lastRestoreAt = now
        lastRestoreName = name
        lastErrorText = nil
        statusText = "Restored \(name)."
        defaults.set(now, forKey: Keys.lastRestoreAt)
        defaults.set(name, forKey: Keys.lastRestoreName)
        Log.write("Restored wallpaper '\(name)' [\(reason)]")
    }

    /// Schedules a restore after `seconds`. Cancels any pending restore first.
    func scheduleRestore(after seconds: Int, reason: String) {
        pendingRestore?.cancel()

        let delay = min(max(0, seconds), 7 * 24 * 60 * 60)
        if delay > 0 {
            statusText = "Restore scheduled in \(Self.durationText(delay)) (\(reason))."
        } else {
            statusText = "Restoring wallpaper now (\(reason))."
        }
        Log.write("Scheduling wallpaper restore in \(delay)s [\(reason)]")

        pendingRestore = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.restoreNow(reason: reason)
        }
    }

    // MARK: Automatic remembering

    /// Watches the wallpaper for MacBack's whole lifetime and automatically
    /// remembers the current wallpaper while it does not look company-managed.
    /// This keeps the snapshot current with no manual step: whenever a personal
    /// wallpaper is set in System Settings, MacBack picks it up within seconds
    /// and that is the wallpaper it restores after login.
    func startRemembering() {
        guard rememberingTask == nil else { return }

        rememberingTask = Task { [weak self] in
            // Give login-time wallpaper changes a moment to settle before the
            // first look, so a policy wallpaper applied at login is not caught
            // mid-flight.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while !Task.isCancelled {
                self?.refreshRememberedWallpaper(reason: "automatic")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// Looks at the current wallpaper. If it is not company-managed and differs
    /// from the remembered snapshot, saves it as the new snapshot.
    func refreshRememberedWallpaper(reason: String) {
        guard !restoreInProgress else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let changed = try SystemWallpaper.rememberIfChanged()
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let snapshot = changed else { return }
                    self.rememberedSummary = snapshot.summary
                    self.rememberedCapturedAt = snapshot.capturedAt
                    self.lastErrorText = nil
                    self.statusText = "Remembered \(snapshot.summary)."
                    Log.write("Remembered wallpaper '\(snapshot.summary)' (provider \(snapshot.provider)) [\(reason)]")
                }
            } catch {
                // Transient failures (a store that is momentarily being
                // rewritten, no display, …) are not worth surfacing; try again
                // on the next tick.
                DispatchQueue.main.async { [weak self] in
                    self?.lastErrorText = nil
                }
                Log.write("Wallpaper check failed (\(error.localizedDescription)) [\(reason)]")
            }
        }
    }

    /// Manually snaps the current wallpaper as the remembered snapshot, even if
    /// it looks company-managed (for testing or as an escape hatch).
    func rememberCurrentNow() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            statusText = "No display is available right now."
            return
        }

        do {
            let snapshot = try SystemWallpaper.rememberCurrent(for: screen)
            rememberedSummary = snapshot.summary
            rememberedCapturedAt = snapshot.capturedAt
            lastErrorText = nil
            if snapshot.looksManaged {
                statusText = "Remembered \(snapshot.summary). This looks company-managed; set a personal wallpaper instead."
                Log.write("WARNING: Remembered wallpaper looks company-managed: \(snapshot.summary) (provider \(snapshot.provider))")
            } else {
                statusText = "Remembered \(snapshot.summary)."
                Log.write("Remembered wallpaper '\(snapshot.summary)' (provider \(snapshot.provider)) [manual]")
            }
        } catch {
            lastErrorText = error.localizedDescription
            statusText = "Could not remember the wallpaper: \(error.localizedDescription)"
            Log.write("ERROR remembering wallpaper: \(error.localizedDescription)")
        }
    }

    // MARK: Login item

    func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAgent.isInstalled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let runningFromAgent = CommandLine.arguments.contains("--login")
        do {
            if enabled {
                guard let executable = Bundle.main.executableURL else {
                    throw LaunchAgentError.missingExecutable
                }
                try LaunchAgent.install(executable: executable, runningFromAgent: runningFromAgent)
                statusText = "MacBack will start at login and restore the wallpaper after \(Self.durationText(delaySeconds))."
            } else {
                try LaunchAgent.uninstall(runningFromAgent: runningFromAgent)
                statusText = "MacBack will no longer start at login."
            }
            launchAtLogin = LaunchAgent.isInstalled
            lastErrorText = nil
            Log.write("Login item \(launchAtLogin ? "installed" : "removed").")
        } catch {
            launchAtLogin = LaunchAgent.isInstalled
            lastErrorText = error.localizedDescription
            statusText = "Could not update the login item: \(error.localizedDescription)"
            Log.write("ERROR updating login item: \(error.localizedDescription)")
        }
    }

    /// Opens the system Wallpaper pane so the user can pick a personal
    /// wallpaper there; MacBack remembers it automatically.
    func openWallpaperSettings() {
        let deepLink = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")
        if let deepLink, NSWorkspace.shared.open(deepLink) {
            Log.write("Opened System Settings > Wallpaper.")
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        Log.write("Opened System Settings (Wallpaper deep link unavailable).")
    }

    // MARK: Helpers

    static func durationText(_ seconds: Int) -> String {
        if seconds <= 0 { return "0 s" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if secs > 0, hours == 0 { parts.append("\(secs) s") }
        return parts.isEmpty ? "0 s" : parts.joined(separator: " ")
    }

    private static func intValue(_ defaults: UserDefaults, _ key: String, fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    private static func boolValue(_ defaults: UserDefaults, _ key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
