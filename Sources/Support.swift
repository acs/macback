import AppKit
import Darwin
import Foundation

enum AppInfo {
    static let name = "MacBack"
    static let bundleID = "com.alvaro.MacBack"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }
}

// MARK: - Logging

enum Log {
    static var fileURL: URL {
        URL.logsDirectory.appendingPathComponent("\(AppInfo.name).log")
    }

    private static let queue = DispatchQueue(label: "\(AppInfo.bundleID).log")

    static func write(_ message: String) {
        queue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? Int, size > 1_000_000 {
                let archive = fileURL.appendingPathExtension("1")
                try? fm.removeItem(at: archive)
                try? fm.moveItem(at: fileURL, to: archive)
            }

            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: data)
            } else if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}

// MARK: - Single instance

enum SingleInstance {
    private static var descriptor: Int32 = -1

    /// Takes an exclusive per-user lock. Returns false when another copy is already running.
    static func acquire() -> Bool {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppInfo.name)-\(getuid()).lock").path
        descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return true }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        close(descriptor)
        descriptor = -1
        return false
    }
}

// MARK: - Locations

extension URL {
    static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
    }

    static var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }
}
