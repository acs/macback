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
                LabeledContent("Delay after login") {
                    HStack(spacing: 8) {
                        TextField("Seconds", value: $model.delaySeconds, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 76)
                        Text("seconds")
                            .foregroundStyle(.secondary)
                        Stepper(
                            "Delay",
                            value: $model.delaySeconds,
                            in: 0...86_400,
                            step: 5
                        )
                        .labelsHidden()
                    }
                }

                Text("MacBack waits \(AppModel.durationText(model.delaySeconds)) after you log in, then restores your wallpaper. This is the earliest point macOS lets an app touch your desktop.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Restore again after waking from sleep", isOn: $model.changeOnWake)
                Toggle("Start MacBack at login", isOn: launchBinding)
            } header: {
                Text("Timing")
            }

            Section {
                LabeledContent("Remembered wallpaper") {
                    Text(model.rememberedSummary ?? "None yet")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let date = model.rememberedCapturedAt {
                    LabeledContent("Captured") {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Your wallpaper is remembered automatically while it is active and does not look company-managed — no button needed. Set your wallpaper in System Settings; MacBack notices it within seconds and restores it after login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("Restore Wallpaper Now") {
                        model.restoreNow(reason: "manual")
                    }
                    .keyboardShortcut("r")

                    Button("Remember Current Wallpaper") {
                        model.rememberCurrentNow()
                    }

                    Button("Open Wallpaper Settings…") {
                        model.openWallpaperSettings()
                    }
                }

                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(model.lastErrorText == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Reveal Log") {
                    Log.reveal()
                }
                .buttonStyle(.link)
            } header: {
                Text("Status")
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
