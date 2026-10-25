import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: Settings

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var statusText: String = "Ready."
    @Published private(set) var lastRestoreAt: Date?
    @Published private(set) var lastRestoreName: String?
    @Published private(set) var lastErrorText: String?
    @Published private(set) var rememberedSummary: String?
    @Published private(set) var rememberedCapturedAt: Date?
    @Published private(set) var corporateSummary: String?
    @Published private(set) var corporateCapturedAt: Date?

    // MARK: State

    private enum Keys {
        static let lastRestoreAt = "lastRestoreAt"
        static let lastRestoreName = "lastRestoreName"
        // Keys written by earlier versions, read for a smooth upgrade.
        static let legacyLastAppliedAt = "lastAppliedAt"
        static let legacyLastAppliedName = "lastAppliedName"
        static let legacyDelaySeconds = "delaySeconds"
        static let legacyChangeOnWake = "changeOnWake"
    }

    /// Minimum time between two automatic restores, so an aggressive corporate
    /// policy cannot make MacBack restart the wallpaper engine in a tight loop.
    static let autoRestoreCooldown: TimeInterval = 60

    private let defaults: UserDefaults
    private var restoreInProgress = false
    /// Latest kind requested while a restore is running; run right after.
    private var pendingKind: SnapshotKind?
    private var lastAutoRestoreAt: Date?
    private var rememberingTask: Task<Void, Never>?

    /// Set when the user deliberately restores the corporate wallpaper; the
    /// watcher stops auto-restoring until the user wallpaper is showing again.
    private var suppressAutoRestore: Bool {
        get { defaults.bool(forKey: SystemWallpaper.suppressAutoRestoreDefaultsKey) }
        set { defaults.set(newValue, forKey: SystemWallpaper.suppressAutoRestoreDefaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        launchAtLogin = LaunchAgent.isInstalled
        lastRestoreAt = (defaults.object(forKey: Keys.lastRestoreAt) as? Date)
            ?? (defaults.object(forKey: Keys.legacyLastAppliedAt) as? Date)
        lastRestoreName = defaults.string(forKey: Keys.lastRestoreName)
            ?? defaults.string(forKey: Keys.legacyLastAppliedName)

        // Timing settings are gone; reactive watching replaced them.
        defaults.removeObject(forKey: Keys.legacyDelaySeconds)
        defaults.removeObject(forKey: Keys.legacyChangeOnWake)

        let snapshot = SystemWallpaper.loadSnapshot(kind: .user)
        rememberedSummary = snapshot?.summary
        rememberedCapturedAt = snapshot?.capturedAt
        let corporate = SystemWallpaper.loadSnapshot(kind: .corporate)
        corporateSummary = corporate?.summary
        corporateCapturedAt = corporate?.capturedAt
    }

    var hasRememberedWallpaper: Bool {
        SystemWallpaper.loadSnapshot(kind: .user) != nil
    }

    // MARK: Restoring

    /// Restores the remembered wallpaper of the given kind now. Works for
    /// still images, dynamic wallpapers and aerial videos alike: the saved copy
    /// of macOS's wallpaper store is written back and macOS's wallpaper engine
    /// re-applies the exact choice, which can make the desktop redraw once.
    func restoreNow(kind: SnapshotKind = .user, reason: String = "manual") {
        if restoreInProgress {
            // A restore usually takes a couple of seconds. When the user
            // switches quickly between the two wallpapers, don't swallow the
            // click: queue the latest kind and run it when the current
            // restore finishes.
            if pendingKind != kind {
                Log.write("Restore of \(kind.title) wallpaper queued [\(reason)]; one already in progress.")
                pendingKind = kind
            }
            return
        }
        runRestore(kind: kind, reason: reason)
    }

    private func runRestore(kind: SnapshotKind, reason: String) {
        guard let snapshot = SystemWallpaper.loadSnapshot(kind: kind) else {
            statusText = "No \(kind.title) wallpaper remembered yet. Set it in System Settings; MacBack saves it automatically."
            Log.write("Nothing to restore yet [\(reason)]: no \(kind.title) snapshot exists.")
            return
        }

        restoreInProgress = true
        statusText = "Restoring \(kind.title) wallpaper \(snapshot.summary)…"
        Log.write("Restoring \(kind.title) wallpaper '\(snapshot.summary)' (provider \(snapshot.provider)) [\(reason)]")

        if kind == .corporate {
            // The user asked for the corporate wallpaper on purpose; the
            // watcher must not undo that until the user wallpaper shows again.
            suppressAutoRestore = true
            Log.write("Paused automatic restore until the user wallpaper is showing again.")
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: SystemWallpaperRestoreResult?
            var failure: Error?

            // A fast WallpaperAgent respawn can rewrite the store right under
            // a restore, which makes one attempt fail transiently; retrying
            // after a short pause is enough. This mirrors what the user would
            // otherwise do by hand.
            let maxAttempts = 3
            for attempt in 1...maxAttempts {
                do {
                    result = try SystemWallpaper.restoreSnapshot(kind: kind)
                    failure = nil
                    break
                } catch {
                    failure = error
                    Log.write("Restore attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)"
                        + (attempt < maxAttempts ? "; retrying in 2 s." : "; giving up."))
                    if attempt < maxAttempts { Thread.sleep(forTimeInterval: 2) }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.restoreInProgress = false
                switch (result, failure) {
                case (let result?, _):
                    self.lastErrorText = nil
                    switch result {
                    case .restored:
                        self.finishRestore(kind: kind, name: snapshot.summary, reason: reason)
                    case .alreadyCurrent:
                        self.statusText = "\(kind.title.capitalized) wallpaper \(snapshot.summary) is already showing."
                        Log.write("\(kind.title.capitalized) wallpaper '\(snapshot.summary)' already current [\(reason)]")
                    }
                case (nil, let failure?):
                    self.lastErrorText = failure.localizedDescription
                    self.statusText = "Could not restore the \(kind.title) wallpaper: \(failure.localizedDescription)"
                    Log.write("ERROR [\(reason)]: \(failure.localizedDescription)")
                case (nil, nil):
                    break
                }

                if let pending = self.pendingKind {
                    self.pendingKind = nil
                    self.runRestore(kind: pending, reason: reason)
                }
            }
        }
    }

    private func finishRestore(kind: SnapshotKind, name: String, reason: String) {
        let now = Date()
        lastRestoreAt = now
        lastRestoreName = name
        lastErrorText = nil
        statusText = "Restored \(kind.title) wallpaper \(name)."
        defaults.set(now, forKey: Keys.lastRestoreAt)
        defaults.set(name, forKey: Keys.lastRestoreName)
        Log.write("Restored \(kind.title) wallpaper '\(name)' [\(reason)]")
    }

    /// Restores the saved user wallpaper if the company wallpaper is showing.
    /// Runs at most once per cooldown period and pauses while the user has
    /// deliberately chosen the corporate wallpaper.
    private func maybeAutoRestore(reason: String) {
        guard !restoreInProgress else { return }
        guard !suppressAutoRestore else { return }
        if let last = lastAutoRestoreAt,
           Date().timeIntervalSince(last) < Self.autoRestoreCooldown {
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let needed = SystemWallpaper.wallpaperNeedsRestore()
            DispatchQueue.main.async { [weak self] in
                guard needed, let self else { return }
                Log.write("Company wallpaper detected; restoring the user wallpaper.")
                self.lastAutoRestoreAt = Date()
                self.restoreNow(kind: .user, reason: reason)
            }
        }
    }

    // MARK: Automatic watching

    /// Watches the wallpaper for MacBack's whole lifetime. Each tick:
    /// - remembers the current wallpaper into its matching slot (user or
    ///   corporate), and
    /// - restores the user wallpaper whenever the company wallpaper is showing,
    ///   unless the user deliberately chose it (suppressed) or a restore just
    ///   happened (cooldown).
    func startRemembering() {
        guard rememberingTask == nil else { return }

        rememberingTask = Task { [weak self] in
            // Give login-time wallpaper changes a moment to settle before the
            // first look, so a policy wallpaper applied at login is not caught
            // mid-flight.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while !Task.isCancelled {
                self?.refreshRememberedWallpaper(reason: "automatic")
                self?.maybeAutoRestore(reason: "automatic")
                self?.rearmSuppressionIfNeeded()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// Clears the deliberate-corporate suppression once the user wallpaper is
    /// showing again.
    private func rearmSuppressionIfNeeded() {
        guard suppressAutoRestore else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let userWallpaperShowing = SystemWallpaper.isWallpaperCurrent(kind: .user)
            DispatchQueue.main.async {
                guard let self, userWallpaperShowing, self.suppressAutoRestore else { return }
                self.suppressAutoRestore = false
                Log.write("User wallpaper is showing again; automatic restore re-armed.")
            }
        }
    }

    /// Looks at the current wallpaper. If it differs from the snapshot in its
    /// matching slot (user or corporate), saves it there.
    func refreshRememberedWallpaper(reason: String) {
        guard !restoreInProgress else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let changed = try SystemWallpaper.rememberIfChanged()
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let change = changed else { return }
                    self.applyRememberedChange(kind: change.kind, snapshot: change.snapshot)
                    self.statusText = "Remembered \(change.kind.title) wallpaper \(change.snapshot.summary)."
                    Log.write("Remembered \(change.kind.title) wallpaper '\(change.snapshot.summary)' (provider \(change.snapshot.provider)) [\(reason)]")
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

    private func applyRememberedChange(kind: SnapshotKind, snapshot: WallpaperSnapshot) {
        switch kind {
        case .user:
            rememberedSummary = snapshot.summary
            rememberedCapturedAt = snapshot.capturedAt
        case .corporate:
            corporateSummary = snapshot.summary
            corporateCapturedAt = snapshot.capturedAt
        }
        lastErrorText = nil
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
                statusText = "MacBack will start at login and keep your wallpaper in place."
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
}
