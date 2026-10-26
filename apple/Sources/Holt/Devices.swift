import AppKit
import CoreImage.CIFilterBuiltins
import HoltBrand
import SwiftUI
import HoltCore

extension Device: Identifiable {}

@MainActor
final class DevicesModel: ObservableObject {
    @Published private(set) var code = ""
    /// What the QR code holds. The iPhone's Camera opens it in Holt, which pairs.
    var pairingLink: String {
        "holt://pair?id=\(node.deviceId())&code=\(code)"
    }
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
    /// Announces this Mac over Bonjour while Devices is open, so an iPhone can list it
    /// and pair with the code. iPhones can't use the core's mDNS without a special entitlement.
    private var bonjour: NetService?
    /// Devices already paired when the window opened, to spot new ones.
    private var known: Set<String> = []

    init(node: Node) { self.node = node }

    func open() {
        let service = NetService(domain: "local.", type: "_holt-pair._tcp.", name: "", port: 9)
        service.setTXTRecord(NetService.data(fromTXTRecord: ["id": Data(node.deviceId().utf8)]))
        service.publish()
        bonjour = service
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
        bonjour?.stop()
        bonjour = nil
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

struct DevicesView: View {
    @ObservedObject var model: DevicesModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Skip().frame(width: 68, height: 68)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync your devices").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("What you copy on one device shows up on the others.")
                        .foregroundStyle(.secondary)
                }
            }

            section("Your devices") {
                if model.devices.isEmpty {
                    Text("No devices yet. Pair one below.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.devices) { device in
                        HStack(spacing: 10) {
                            // iOS reports every iPhone's name as "iPhone".
                            Image(systemName: device.name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "laptopcomputer")
                                .frame(width: 22)
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

            section("Pair a new device") {
                HStack(alignment: .center, spacing: 20) {
                    if let qr = qrCode(model.pairingLink) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 104, height: 104)
                            .padding(6)
                            .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .help("Point your iPhone's Camera at this code")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This Mac's code").font(.callout).foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(spaced(model.code))
                                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(Brand.river)
                                    .textSelection(.enabled)
                                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(model.code, forType: .string)
                                    copied = true
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.5))
                                        copied = false
                                    }
                                }
                                .controlSize(.small)
                                .disabled(model.code.isEmpty)
                            }
                        }
                        Text(
                            "On your iPhone, open Holt and scan this code. On another Mac, pick this Mac under Nearby and type the code."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.river.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("Nearby").font(.callout.weight(.medium)).padding(.top, 6)
                if model.nearby.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for Macs on this network with this tab open…").foregroundStyle(.secondary)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}

/// A crisp QR code image for `text`, drawn one pixel per module and scaled up by SwiftUI.
@MainActor
private func qrCode(_ text: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
        let cgImage = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return NSImage(cgImage: cgImage, size: output.extent.size)
}
