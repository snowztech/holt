import SwiftUI

/// Two ways to pair: the QR code on the Mac, which the Camera opens here, or picking a
/// nearby Mac and typing its 6-digit code.
struct PairView: View {
    let library: Library
    /// Set when the Camera opened a pairing link, so pairing starts right away.
    let link: PairingLink?

    @Environment(\.dismiss) private var dismiss
    @State private var nearby = Nearby()
    @State private var chosen: Nearby.Mac?
    @State private var code = ""
    @State private var state = PairState.ready
    @FocusState private var codeFocused: Bool

    enum PairState: Equatable {
        case ready
        case pairing
        case paired(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .pairing:
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text("Pairing…").font(.title3.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .paired(let name):
                    paired(name)
                case .ready, .failed:
                    ways
                }
            }
            .navigationTitle("Pair with your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                if let link {
                    start(link)
                } else {
                    nearby.start()
                }
            }
            .onDisappear { nearby.stop() }
        }
    }

    private var ways: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                way(
                    symbol: "qrcode.viewfinder", title: "Scan the code",
                    detail:
                        "On your Mac, open Holt → Settings → Devices. Point this iPhone's Camera at the code, then tap Open in Holt."
                )

                VStack(alignment: .leading, spacing: 16) {
                    way(symbol: "number", title: "Or type it", detail: "Pick your Mac, then type the 6-digit code it shows.")
                    if nearby.macs.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for Macs with Devices open…").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 46)
                    }
                    ForEach(nearby.macs) { mac in
                        macRow(mac)
                    }
                }

                if case .failed(let message) = state {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
    }

    private func macRow(_ mac: Nearby.Mac) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.snappy) {
                    chosen = mac
                    code = ""
                }
                codeFocused = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer").foregroundStyle(Brand.river)
                    Text(mac.name).foregroundStyle(.primary)
                    Spacer()
                    if chosen != mac { Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                }
                .padding(.leading, 46)
            }
            if chosen == mac {
                TextField("000 000", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .focused($codeFocused)
                    .onChange(of: code) { _, new in
                        code = String(new.filter(\.isNumber).prefix(6))
                        if code.count == 6 { start(PairingLink(id: mac.id, code: code)) }
                    }
                    .padding(.leading, 46)
            }
        }
    }

    private func paired(_ name: String) -> some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Brand.river)
            Text("Paired with \(name)")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 20)
            Text("What you copy on your Mac now shows up here, and what you send from this iPhone shows up there.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }

    private func way(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Brand.river)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func start(_ link: PairingLink) {
        codeFocused = false
        state = .pairing
        Task {
            if let error = await library.pair(link) {
                state = .failed(error)
                code = ""
                nearby.start()
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                state = .paired(library.devices.first(where: { $0.id == link.id })?.name ?? "your Mac")
            }
        }
    }
}
