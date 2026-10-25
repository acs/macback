import AppKit
import SwiftUI

/// The content of the About window. Small and fixed-size on purpose: the same
/// menu-bar symbol, the app name and version, a one-sentence description and a
/// link to the open-source project. Nothing scrolls.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 64))
                .foregroundStyle(.primary)

            VStack(spacing: 2) {
                Text("MacBack")
                    .font(.title2.weight(.semibold))
                Text("Version \(AppInfo.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("MacBack remembers your personal wallpaper and the company wallpaper and shows the one configured by you.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)

            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/acs/macback")!)
            } label: {
                Text("Released as Open Source")
            }
            .buttonStyle(.link)
        }
        .padding(28)
        .frame(width: 380)
    }
}

@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    func show() {
        Log.write("Opening the About window.")

        if window == nil {
            let hosting = NSHostingController(rootView: AboutView())
            // The window matches the fixed-size SwiftUI content; nothing scrolls.
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "About MacBack"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
