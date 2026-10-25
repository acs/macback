import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Start MacBack at login", isOn: launchBinding)

                Text("MacBack watches the wallpaper continuously and puts your wallpaper back whenever the company wallpaper shows up — at login, after waking, or any other time. There is nothing to configure: pointing macOS at your wallpaper is all it needs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Startup")
            }

            Section {
                LabeledContent("User wallpaper") {
                    Text(model.rememberedSummary ?? "None yet")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let date = model.rememberedCapturedAt {
                    LabeledContent("User captured") {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Corporate wallpaper") {
                    Text(model.corporateSummary ?? "None yet")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let date = model.corporateCapturedAt {
                    LabeledContent("Corporate captured") {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Both kinds are remembered automatically while they are active — no button needed. Set your wallpaper in System Settings; MacBack notices it within seconds. Company wallpapers are saved separately, so you can switch between them from the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Status")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Open Wallpaper Settings…") {
                        model.openWallpaperSettings()
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            model.refreshLaunchAtLogin()
        }
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        Log.write("Opening the settings window.")

        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: AppModel.shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "MacBack Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
