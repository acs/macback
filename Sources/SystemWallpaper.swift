import AppKit
import CoreGraphics
import Foundation

/// A saved copy of macOS's wallpaper store. Restoring the store brings back the
/// exact wallpaper choice, including aerial videos and dynamic wallpapers that
/// `NSWorkspace` cannot apply by itself.
struct WallpaperSnapshot: Codable {
    var version: Int
    var capturedAt: Date
    var storeData: Data
    var displayUUID: String
    var provider: String
    var configuration: Data
    var summary: String
    var imagePath: String?
    var looksManaged: Bool
}

enum SystemWallpaperError: LocalizedError {
    case storeUnreadable(String)
    case noWallpaperFound
    case displayNotFound
    case snapshotMissing
    case backupFailed(String)
    case agentRestartFailed
    case restoreRejected

    var errorDescription: String? {
        switch self {
        case .storeUnreadable(let path):
            return "macOS's wallpaper store could not be read at \(path)."
        case .noWallpaperFound:
            return "macOS did not report a wallpaper choice for this display."
        case .displayNotFound:
            return "Could not identify the current display."
        case .snapshotMissing:
            return "No wallpaper of this kind is remembered yet. Show it in System Settings; MacBack saves it automatically."
        case .backupFailed(let reason):
            return "Could not back up the current wallpaper store: \(reason)"
        case .agentRestartFailed:
            return "macOS's wallpaper engine did not restart."
        case .restoreRejected:
            return "macOS rejected the remembered wallpaper and kept the current one. Set the wallpaper in System Settings and remember it again."
        }
    }
}

enum SystemWallpaperRestoreResult {
    case restored
    case alreadyCurrent
}

/// Which wallpaper slot a snapshot belongs to. The user wallpaper is the
/// personal one; the corporate wallpaper is the company-managed one. Both are
/// saved automatically as the watcher sees them.
enum SnapshotKind: String {
    case user
    case corporate

    var title: String {
        switch self {
        case .user: return "user"
        case .corporate: return "corporate"
        }
    }
}

/// Reads and restores `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`.
///
/// This is not a documented Apple interface. Restoring a remembered wallpaper
/// writes the saved store back and restarts WallpaperAgent, which is what makes
/// it work for every wallpaper kind — still images, dynamic wallpapers and
/// aerial videos — without Apple-supported APIs to read the store.
enum SystemWallpaper {
    struct Choice {
        let provider: String
        let configuration: Data
        let imageURL: URL?
        let summary: String
        let sectionPath: String
        let lastSet: Date?
        let lastUse: Date?
    }

    // MARK: Locations

    // Defaults key: set when the user deliberately restores the corporate
    // wallpaper, which pauses auto-restore until the user wallpaper shows again.
    static let suppressAutoRestoreDefaultsKey = "suppressAutoRestore"

    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacBack", isDirectory: true)
    }

    static var snapshotURL: URL {
        supportDirectory.appendingPathComponent("WallpaperSnapshot.plist")
    }

    static var corporateSnapshotURL: URL {
        supportDirectory.appendingPathComponent("CorporateWallpaperSnapshot.plist")
    }

    private static var backupURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("Index.plist.macback-backup")
    }

    // MARK: Public API

    static func displayUUID(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue()
        else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func currentChoice(for screen: NSScreen) throws -> Choice {
        let data = try storeData()
        let store = try parseStore(data)
        guard let displayUUID = displayUUID(for: screen) else {
            throw SystemWallpaperError.displayNotFound
        }
        return try effectiveChoice(in: store, displayUUID: displayUUID)
    }

    private static func rememberCurrent(for screen: NSScreen) throws -> (kind: SnapshotKind, snapshot: WallpaperSnapshot) {
        let data = try storeData()
        let store = try parseStore(data)
        guard let displayUUID = displayUUID(for: screen) else {
            throw SystemWallpaperError.displayNotFound
        }

        let choice = try effectiveChoice(in: store, displayUUID: displayUUID)
        let kind: SnapshotKind = isManaged(choice) ? .corporate : .user

        let snapshot = WallpaperSnapshot(
            version: 1,
            capturedAt: Date(),
            storeData: data,
            displayUUID: displayUUID,
            provider: choice.provider,
            configuration: choice.configuration,
            summary: choice.summary,
            imagePath: choice.imageURL?.path,
            looksManaged: kind == .corporate
        )
        try save(snapshot, kind: kind)
        return (kind, snapshot)
    }

    /// True when the macOS store currently shows exactly the wallpaper saved in
    /// the given slot.
    static func isWallpaperCurrent(kind: SnapshotKind) -> Bool {
        guard let snapshot = loadSnapshot(kind: kind),
              let data = try? Data(contentsOf: storeURL),
              let store = try? parseStore(data)
        else {
            return false
        }
        return matches(snapshot: snapshot, store: store)
    }

    /// True when the wallpaper currently showing is a company-managed one and
    /// the remembered user wallpaper is different — i.e. the user wallpaper
    /// should be restored automatically.
    static func wallpaperNeedsRestore() -> Bool {
        guard loadSnapshot(kind: .user) != nil else { return false }
        guard !isWallpaperCurrent(kind: .user) else { return false }

        guard let data = try? Data(contentsOf: storeURL),
              let store = try? parseStore(data),
              let screen = NSScreen.main ?? NSScreen.screens.first,
              let displayUUID = displayUUID(for: screen),
              let choice = try? effectiveChoice(in: store, displayUUID: displayUUID)
        else {
            return false
        }
        return isManaged(choice)
    }

    /// Saves the current wallpaper into its matching slot (user or corporate)
    /// unless it already matches the snapshot that lives there. Returns the new
    /// snapshot when one was saved, nil when there was nothing to do.
    static func rememberIfChanged(for screen: NSScreen? = nil) throws -> (kind: SnapshotKind, snapshot: WallpaperSnapshot)? {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }

        let data = try storeData()
        let store = try parseStore(data)
        guard let displayUUID = displayUUID(for: screen) else { return nil }
        let choice = try effectiveChoice(in: store, displayUUID: displayUUID)

        // One slot per wallpaper kind, so the corporate wallpaper can never
        // overwrite the user snapshot and vice versa.
        let kind: SnapshotKind = isManaged(choice) ? .corporate : .user

        if let snapshot = loadSnapshot(kind: kind), matches(snapshot: snapshot, store: store) {
            return nil
        }

        return try rememberCurrent(for: screen)
    }

    static func loadSnapshot(kind: SnapshotKind = .user) -> WallpaperSnapshot? {
        let url = snapshotURL(for: kind)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(WallpaperSnapshot.self, from: data)
    }

    static func restoreSnapshot(kind: SnapshotKind = .user) throws -> SystemWallpaperRestoreResult {
        guard let snapshot = loadSnapshot(kind: kind) else {
            throw SystemWallpaperError.snapshotMissing
        }

        _ = try parseStore(snapshot.storeData)

        guard let currentData = try? Data(contentsOf: storeURL), !currentData.isEmpty else {
            throw SystemWallpaperError.storeUnreadable(storeURL.path)
        }

        if let currentStore = try? parseStore(currentData),
           matches(snapshot: snapshot, store: currentStore) {
            return .alreadyCurrent
        }

        do {
            try currentData.write(to: backupURL, options: .atomic)
        } catch {
            throw SystemWallpaperError.backupFailed(error.localizedDescription)
        }

        try snapshot.storeData.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: storeURL.path
        )

        guard restartAgent() else {
            try? currentData.write(to: storeURL, options: .atomic)
            _ = restartAgent()
            throw SystemWallpaperError.agentRestartFailed
        }

        if waitForMatch(snapshot: snapshot, timeout: 10) {
            Log.write("Restored \(kind.title) wallpaper '\(snapshot.summary)' (provider \(snapshot.provider)).")
            return .restored
        }

        // The wallpaper agent rewrote the store or management software put the
        // corporate wallpaper back. Roll back so the user is not left with a
        // half-written store, then report the failure.
        try? currentData.write(to: storeURL, options: .atomic)
        _ = restartAgent()
        Log.write("ERROR: macOS rejected the \(kind.title) wallpaper '\(snapshot.summary)'; rolled the store back.")
        throw SystemWallpaperError.restoreRejected
    }

    // MARK: Store parsing

    private static func storeData() throws -> Data {
        guard let data = try? Data(contentsOf: storeURL) else {
            throw SystemWallpaperError.storeUnreadable(storeURL.path)
        }
        return data
    }

    private static func parseStore(_ data: Data) throws -> [String: Any] {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw SystemWallpaperError.storeUnreadable(storeURL.path)
        }
        return plist
    }

    static func snapshotURL(for kind: SnapshotKind) -> URL {
        kind == .user ? snapshotURL : corporateSnapshotURL
    }

    private static func save(_ snapshot: WallpaperSnapshot, kind: SnapshotKind) throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL(for: kind), options: .atomic)
    }

    private static func effectiveChoice(
        in store: [String: Any],
        displayUUID: String
    ) throws -> Choice {
        // Sections are consulted in the same order the system uses:
        // "Show on all Spaces", the current Space's per-display choice, the
        // current Space's fallback, the legacy top-level display entry, and
        // finally SystemDefault. The top-level `Displays` section can be stale
        // while a per-Space section holds the wallpaper that is actually shown,
        // so it must not win merely because it has a newer timestamp.
        var fallback: Choice?

        func consider(_ section: Any?, path: String) -> Choice? {
            guard let choice = makeChoice(from: section as? [String: Any] ?? [:], path: path) else {
                return nil
            }
            if choice.provider == "default" {
                if fallback == nil { fallback = choice }
                return nil
            }
            return choice
        }

        // "Show on all Spaces" lives in AllSpacesAndDisplays and takes precedence.
        if let all = store["AllSpacesAndDisplays"] as? [String: Any],
           let choice = consider(all["Desktop"], path: "AllSpacesAndDisplays.Desktop") {
            return choice
        }

        // The empty-string Space is the live/current Space section maintained
        // by WallpaperAgent and NSWorkspace.
        if let currentSpace = (store["Spaces"] as? [String: Any])?[""] as? [String: Any] {
            if let displays = currentSpace["Displays"] as? [String: Any],
               let display = displays[displayUUID] as? [String: Any],
               let choice = consider(
                   display["Desktop"],
                   path: "Spaces[].Displays[\(displayUUID)].Desktop"
               ) {
                return choice
            }
            if let fallbackSection = currentSpace["Default"] as? [String: Any],
               let choice = consider(
                   fallbackSection["Desktop"],
                   path: "Spaces[].Default.Desktop"
               ) {
                return choice
            }
        }

        if let displays = store["Displays"] as? [String: Any],
           let display = displays[displayUUID] as? [String: Any],
           let choice = consider(
               display["Desktop"],
               path: "Displays[\(displayUUID)].Desktop"
           ) {
            return choice
        }

        if let systemDefault = store["SystemDefault"] as? [String: Any],
           let choice = consider(
               systemDefault["Desktop"],
               path: "SystemDefault.Desktop"
           ) {
            return choice
        }

        // Last resort for stores that do not have the current-Space alias:
        // pick whichever named Space was changed most recently.
        var candidates: [Choice] = []
        if let spaces = store["Spaces"] as? [String: Any] {
            for (spaceID, value) in spaces where spaceID != "" {
                guard let space = value as? [String: Any] else { continue }

                if let displays = space["Displays"] as? [String: Any],
                   let display = displays[displayUUID] as? [String: Any],
                   let choice = makeChoice(
                       from: display["Desktop"] as? [String: Any] ?? [:],
                       path: "Spaces[\(spaceID)].Displays[\(displayUUID)].Desktop"
                   ),
                   choice.provider != "default" {
                    candidates.append(choice)
                }

                if let fallbackSection = space["Default"] as? [String: Any],
                   let choice = makeChoice(
                       from: fallbackSection["Desktop"] as? [String: Any] ?? [:],
                       path: "Spaces[\(spaceID)].Default.Desktop"
                   ),
                   choice.provider != "default" {
                    candidates.append(choice)
                }
            }
        }

        if let best = candidates.max(by: { lhs, rhs in
            let lhsDate = lhs.lastSet ?? lhs.lastUse ?? .distantPast
            let rhsDate = rhs.lastSet ?? rhs.lastUse ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            let lhsUse = lhs.lastUse ?? .distantPast
            let rhsUse = rhs.lastUse ?? .distantPast
            return lhsUse < rhsUse
        }) {
            return best
        }

        if let fallback {
            return fallback
        }

        throw SystemWallpaperError.noWallpaperFound
    }

    private static func makeChoice(from section: [String: Any], path: String) -> Choice? {
        guard let content = section["Content"] as? [String: Any],
              let choices = content["Choices"] as? [Any],
              let first = choices.first as? [String: Any]
        else {
            return nil
        }

        let provider = first["Provider"] as? String ?? ""
        guard !provider.isEmpty else { return nil }

        let configuration = configurationData(from: first)
        let description = describe(provider: provider, configuration: configuration)

        return Choice(
            provider: provider,
            configuration: configuration,
            imageURL: description.imageURL,
            summary: description.summary,
            sectionPath: path,
            lastSet: section["LastSet"] as? Date,
            lastUse: section["LastUse"] as? Date
        )
    }

    private static func configurationData(from choice: [String: Any]) -> Data {
        if let data = choice["Configuration"] as? Data {
            return data
        }
        if let string = choice["Configuration"] as? String {
            return Data(string.utf8)
        }
        return Data()
    }

    private static func describe(
        provider: String,
        configuration: Data
    ) -> (summary: String, imageURL: URL?) {
        if provider == "com.apple.wallpaper.choice.image" {
            if let url = imageURL(from: configuration) {
                return (url.lastPathComponent, url)
            }
            return ("Image wallpaper", nil)
        }
        if provider.localizedCaseInsensitiveContains("aerials") {
            return ("Aerial wallpaper", nil)
        }
        if provider.localizedCaseInsensitiveContains("dynamic") {
            return ("Dynamic wallpaper", nil)
        }
        if provider.localizedCaseInsensitiveContains("NeptuneOne") {
            return ("macOS default wallpaper", nil)
        }
        if provider == "default" {
            return ("System default wallpaper", nil)
        }
        if provider.localizedCaseInsensitiveContains("photos") {
            return ("Photos wallpaper", nil)
        }
        if provider.localizedCaseInsensitiveContains("screen-saver") {
            return ("Screen saver wallpaper", nil)
        }
        return ("macOS wallpaper", nil)
    }

    private static func imageURL(from configuration: Data) -> URL? {
        guard !configuration.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(
                from: configuration,
                options: [],
                format: nil
              ) as? [String: Any]
        else {
            return nil
        }

        if let url = plist["url"] as? [String: Any], let relative = url["relative"] as? String {
            return URL(string: relative) ?? URL(fileURLWithPath: relative)
        }
        if let relative = plist["url"] as? String {
            return URL(string: relative) ?? URL(fileURLWithPath: relative)
        }
        if let relative = plist["relative"] as? String {
            return URL(string: relative) ?? URL(fileURLWithPath: relative)
        }
        return nil
    }

    private static func isManaged(_ choice: Choice) -> Bool {
        let provider = choice.provider.lowercased()
        return provider.contains("hexnode")
            || provider.contains("mdm")
            || choice.imageURL.map { looksManaged(path: $0.path) } == true
    }

    private static func looksManaged(path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("mdm") || lower.contains("hexnode") || lower.contains("corporate") {
            return true
        }
        if lower.hasPrefix("/library/application support/"),
           !lower.hasPrefix("/library/application support/com.apple") {
            return true
        }
        return false
    }

    private static func matches(snapshot: WallpaperSnapshot, store: [String: Any]) -> Bool {
        guard let choice = try? effectiveChoice(in: store, displayUUID: snapshot.displayUUID) else {
            return false
        }
        guard choice.provider == snapshot.provider else { return false }

        if snapshot.provider == "com.apple.wallpaper.choice.image",
           let savedURL = imageURL(from: snapshot.configuration),
           let currentURL = choice.imageURL {
            return savedURL.standardizedFileURL == currentURL.standardizedFileURL
        }

        return configurationsEqual(snapshot.configuration, choice.configuration)
    }

    private static func configurationsEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        if lhs == rhs { return true }
        guard let left = try? PropertyListSerialization.propertyList(
            from: lhs,
            options: [],
            format: nil
        ) as? NSDictionary,
        let right = try? PropertyListSerialization.propertyList(
            from: rhs,
            options: [],
            format: nil
        ) as? NSDictionary
        else {
            return false
        }
        return left == right
    }

    // MARK: WallpaperAgent

    private static func restartAgent() -> Bool {
        let oldPID = agentPID()

        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["WallpaperAgent"]
        do {
            try kill.run()
            kill.waitUntilExit()
        } catch {
            Log.write("ERROR: Could not run killall WallpaperAgent: \(error.localizedDescription)")
            return false
        }

        if kill.terminationStatus != 0 && oldPID != nil {
            let force = Process()
            force.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            force.arguments = ["-9", "WallpaperAgent"]
            try? force.run()
            force.waitUntilExit()
        }

        // launchd respawns the agent. Wait for a new PID so verification does
        // not read the store before the agent has had a chance to rewrite it.
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            if let pid = agentPID(), pid != oldPID {
                Thread.sleep(forTimeInterval: 1.0)
                return true
            }
        }

        // If the agent was not running when we started, any PID is a success.
        if oldPID == nil, agentPID() != nil {
            Thread.sleep(forTimeInterval: 1.0)
            return true
        }

        return false
    }

    private static func agentPID() -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "WallpaperAgent"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let firstLine = output.split(whereSeparator: { $0.isNewline }).first
        return firstLine.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func waitForMatch(snapshot: WallpaperSnapshot, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastData: Data?
        var stableSince: Date?

        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)

            guard let data = try? Data(contentsOf: storeURL) else { continue }

            if data == lastData {
                if stableSince == nil {
                    stableSince = Date()
                }
                if let stableDate = stableSince, Date().timeIntervalSince(stableDate) >= 0.75 {
                    if let store = try? parseStore(data), matches(snapshot: snapshot, store: store) {
                        return true
                    }
                    // The store is stable but still does not match. Keep
                    // waiting in case the agent is about to rewrite it again.
                    stableSince = nil
                }
            } else {
                lastData = data
                stableSince = nil
            }
        }

        if let data = try? Data(contentsOf: storeURL),
           let store = try? parseStore(data) {
            return matches(snapshot: snapshot, store: store)
        }
        return false
    }
}
