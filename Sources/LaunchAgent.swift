import Darwin
import Foundation

enum LaunchAgentError: LocalizedError {
    case missingExecutable
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "Could not determine the path of the MacBack executable."
        case .launchctlFailed(let details):
            return details
        }
    }
}

/// Installs a per-user LaunchAgent (in ~/Library/LaunchAgents) that starts MacBack
/// at login with the `--login` flag. Using an agent instead of a system daemon is
/// intentional: macOS only allows changing a user's wallpaper inside a logged-in
/// GUI session.
enum LaunchAgent {
    static let label = "\(AppInfo.bundleID).agent"

    static var plistURL: URL {
        URL.launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func install(executable: URL, runningFromAgent: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: URL.launchAgentsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: URL.logsDirectory, withIntermediateDirectories: true)

        let launchdLog = URL.logsDirectory.appendingPathComponent("\(AppInfo.name).launchd.log").path

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--login"],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "StandardOutPath": launchdLog,
            "StandardErrorPath": launchdLog,
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        // When the app itself is the running agent, booting the service out would kill
        // the process the user is looking at. The loaded service is enough until logout;
        // the plist on disk decides whether it starts at the next login.
        if runningFromAgent, isLoaded {
            return
        }

        bootout()
        try bootstrapWithRetry()
    }

    static func uninstall(runningFromAgent: Bool) throws {
        if !runningFromAgent {
            bootout()
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static var domain: String { "gui/\(getuid())" }

    private static var isLoaded: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "\(domain)/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func bootout() {
        _ = try? launchctl(["bootout", "\(domain)/\(label)"])
    }

    private static func bootstrapWithRetry() throws {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                try launchctl(["enable", "\(domain)/\(label)"])
                try launchctl(["bootstrap", domain, plistURL.path])
                return
            } catch {
                lastError = error
                usleep(150_000)
            }
        }
        throw lastError ?? LaunchAgentError.launchctlFailed("Could not load the login item.")
    }

    private static func launchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let command = arguments.joined(separator: " ")
            let details = output.isEmpty ? "exit status \(process.terminationStatus)" : output
            throw LaunchAgentError.launchctlFailed("launchctl \(command) failed: \(details)")
        }
    }
}
