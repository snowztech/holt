import SwiftUI

struct SettingsView: View {
    let library: Library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showPair = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Your Macs") {
                    if library.devices.isEmpty {
                        Text("No Macs yet.").foregroundStyle(.secondary)
                    }
                    ForEach(library.devices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: "laptopcomputer").foregroundStyle(Brand.river)
                            Text(device.name)
                            Spacer()
                            Circle().fill(device.online ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                            Text(device.online ? "Connected" : "Not connected").font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { library.removeDevice(device) }
                        }
                    }
                    Button("Pair with a Mac", systemImage: "plus") { showPair = true }
                }

                Section {
                    tip(
                        "doc.on.clipboard", "Allow paste",
                        "So sending what you copied never asks first: Settings → Holt → Paste from Other Apps → Allow.",
                        button: "Open Settings"
                    ) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    tip("button.horizontal.top.press", "Action Button", "Settings → Action Button → Shortcut → Send Clipboard to Holt.")
                    tip("switch.2", "Control Center", "Open Control Center, tap +, and add Send Clipboard from Holt.")
                    tip("hand.tap", "Back Tap", "Settings → Accessibility → Touch → Back Tap → Send Clipboard to Holt.")
                    tip("square.and.arrow.up", "Share sheet", "Select text or a link in any app, tap Share, then Holt.")
                } header: {
                    Text("Send faster")
                } footer: {
                    Text("Copy something, then one press sends it to your Mac.")
                }

                Section("About") {
                    LabeledContent(
                        "Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                    Link("Website", destination: URL(string: "https://holt.snowztech.com")!)
                    Link("GitHub", destination: URL(string: "https://github.com/snowztech/holt")!)
                }

                Section {
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                } footer: {
                    Text("Timings for pairing and sending, to help while Holt for iPhone is in testing.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showPair) { PairView(library: library, link: nil) }
        }
    }

    private func tip(_ symbol: String, _ title: String, _ detail: String, button: String? = nil, action: (() -> Void)? = nil)
        -> some View
    {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(Brand.river)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let button, let action {
                    Button(button, action: action).font(.caption.weight(.semibold)).padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The shared log the app, the share sheet and the Control Center button write to.
private struct DiagnosticsView: View {
    @State private var lines: [String] = []

    var body: some View {
        List {
            if lines.isEmpty {
                Text("Nothing logged yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(lines.enumerated().reversed()), id: \.offset) { _, line in
                Text(line).font(.system(.caption, design: .monospaced))
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            Button("Clear") {
                try? FileManager.default.removeItem(at: Core.logFile)
                lines = []
            }
        }
        .task {
            lines = ((try? String(contentsOf: Core.logFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }
}
