import AppKit
import SwiftUI
import HoltCore

extension Device: Identifiable {}

@MainActor
final class DevicesModel: ObservableObject {
    @Published private(set) var code = ""
    @Published private(set) var devices: [Device] = []
    @Published private(set) var nearby: [Device] = []
    /// The nearby device the user is typing a code for.
    @Published var joining: Device?
    @Published var entered = ""
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var paired: String?

    private let node: Node
    private var timer: Timer?
    /// Devices already paired when the window opened, to spot new ones.
    private var known: Set<String> = []

    init(node: Node) { self.node = node }

    func open() {
        code = node.startPairing()
        paired = nil
        devices = (try? node.devices()) ?? []
        known = Set(devices.map(\.id))
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        node.stopPairing()
        joining = nil
        entered = ""
        error = nil
    }

    func refresh() {
        devices = (try? node.devices()) ?? []
        nearby = node.nearby()
        if let new = devices.first(where: { !known.contains($0.id) }) {
            known.insert(new.id)
            paired = new.name
            // Pairing stops after a success. Start again so a third device can pair.
            code = node.startPairing()
        }
    }

    func startJoining(_ device: Device) {
        joining = device
        entered = ""
        error = nil
    }

    func pair() {
        guard let device = joining, !busy else { return }
        busy = true
        error = nil
        let node = node
        let code = entered
        Task.detached {
            let result = Result { try node.pair(deviceId: device.id, code: code) }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success:
                    self.joining = nil
                    self.entered = ""
                    self.refresh()
                case .failure(let error):
                    if case HoltError.Pairing(let message) = error {
                        self.error = message
                    } else {
                        self.error = "\(error)"
                    }
                }
            }
        }
    }

    func remove(_ device: Device) {
        try? node.removeDevice(deviceId: device.id)
        refresh()
    }
}

@MainActor
final class DevicesWindow: NSObject, NSWindowDelegate {
    private let model: DevicesModel
    private var window: NSWindow?

    init(node: Node) {
        model = DevicesModel(node: node)
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: DevicesView(model: model)))
            window.title = "Devices"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        if window?.isVisible != true {
            model.open()
            window?.center()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.close()
    }
}

struct DevicesView: View {
    @ObservedObject var model: DevicesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Skip().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Devices").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("What you copy on one device shows up on the others.")
                        .foregroundStyle(.secondary)
                }
            }

            section("YOUR DEVICES") {
                if model.devices.isEmpty {
                    Text("No devices yet. Pair one below.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.devices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: "laptopcomputer").frame(width: 22)
                            Text(device.name)
                            Spacer()
                            Circle().fill(device.online ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                            Text(device.online ? "Connected" : "Not connected")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Remove") { model.remove(device) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }

            section("PAIR A NEW DEVICE") {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This Mac's code").font(.callout).foregroundStyle(.secondary)
                        Text(spaced(model.code))
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Brand.river)
                            .textSelection(.enabled)
                    }
                    Text("On your other Mac, open Devices in Holt, pick this Mac below, and type this code.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.river.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("Nearby").font(.callout.weight(.medium)).padding(.top, 6)
                if model.nearby.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for Macs on this network with Devices open…").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.nearby) { device in
                        nearbyRow(device)
                    }
                }

                if let paired = model.paired {
                    Label("Paired with \(paired)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder
    private func nearbyRow(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer").frame(width: 22)
                Text(device.name)
                Spacer()
                if model.joining?.id != device.id {
                    Button("Pair…") { model.startJoining(device) }
                }
            }
            if model.joining?.id == device.id {
                HStack(spacing: 8) {
                    TextField("Code shown on \(device.name)", text: $model.entered)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 15, design: .rounded).monospacedDigit())
                        .onSubmit { model.pair() }
                    if model.busy {
                        ProgressView().controlSize(.small)
                    }
                    Button("Pair") { model.pair() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.busy || model.entered.filter(\.isNumber).count != 6)
                    Button("Cancel") { model.joining = nil }
                }
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}
