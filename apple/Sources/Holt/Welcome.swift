import AppKit
import SwiftUI

/// First launch: what Holt does, and the permissions it needs, each checked off live.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private let settings: SettingsModel
    private let openDevices: () -> Void
    private var window: NSWindow?
    private var timer: Timer?

    init(settings: SettingsModel, openDevices: @escaping () -> Void) {
        self.settings = settings
        self.openDevices = openDevices
    }

    func show() {
        if window == nil {
            let view = WelcomeView(model: settings, openDevices: openDevices) { [weak self] in self?.window?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        settings.refreshPermissions()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings.refreshPermissions() }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        Prefs.onboarded = true
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: SettingsModel
    let openDevices: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Skip().frame(width: 128, height: 128)
            Text("Welcome to Holt")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .padding(.top, 14)
            Text("Holt keeps everything you copy. Press \(model.shortcut.display) to find it again.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(
                    title: "See what you copy",
                    detail: "Set Holt to Always Allow in Paste from Other Apps.",
                    granted: model.clipboardAllowed,
                    button: "Open Settings",
                    action: Permissions.openClipboardSettings
                )
                Divider()
                PermissionRow(
                    title: "Paste for you",
                    detail: "Optional. Without it, Holt copies the clip and you press ⌘V.",
                    granted: model.autoPasteAllowed,
                    button: "Allow",
                    action: Permissions.requestAutoPaste
                )
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: model.launchAtLogin ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(model.launchAtLogin ? Brand.river : Color.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login")
                        Text("So Holt never misses a copy after a restart.").font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $model.launchAtLogin).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync with your other Mac")
                        Text("Optional. Pair it once and your copies show up on both.").font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Pair…", action: openDevices)
                }
            }
            .padding(18)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 24)

            Button(action: done) {
                Text("Start using Holt").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 22)
        }
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 500)
        .tint(Brand.river)
    }
}
