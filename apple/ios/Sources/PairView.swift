import SwiftUI

/// Pairing: scan the QR code in Holt on the Mac, or pick a nearby Mac and type its code.
struct PairView: View {
    let library: Library
    /// Set when the Camera opened a pairing link, so pairing starts right away.
    let link: PairingLink?

    @Environment(\.dismiss) private var dismiss
    @State private var nearby = Nearby()
    @State private var scanning = false
    @State private var state = PairState.ready

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
                    PairingProgress()
                case .paired(let name):
                    Paired(name: name) { dismiss() }
                case .ready, .failed:
                    options
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(isPresented: $scanning) {
                QRScanner { link in
                    scanning = false
                    start(link)
                }
                .ignoresSafeArea()
            }
            .task {
                if let link { start(link) } else { nearby.start() }
            }
            .onDisappear { nearby.stop() }
        }
    }

    private var options: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pair with your Mac")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text("On your Mac, open Holt Settings and pick Devices.")
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            if case .failed(let message) = state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }

            Section {
                if QRScanner.isAvailable {
                    Button {
                        scanning = true
                    } label: {
                        OptionRow(symbol: "qrcode.viewfinder", title: "Scan the QR code", detail: "The quickest way.")
                    }
                } else {
                    OptionRow(symbol: "camera", title: "Scan with the Camera app", detail: "Point it at the QR code on your Mac.")
                }
            }

            Section("Nearby Macs") {
                if nearby.macs.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for Macs with Devices open").foregroundStyle(.secondary)
                    }
                }
                ForEach(nearby.macs) { mac in
                    NavigationLink {
                        CodeEntry(mac: mac) { code in start(PairingLink(id: mac.id, code: code)) }
                    } label: {
                        OptionRow(symbol: "laptopcomputer", title: mac.name, detail: "Type the code it shows.")
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func start(_ link: PairingLink) {
        state = .pairing
        Task {
            if let error = await library.pair(link) {
                state = .failed(error)
                nearby.start()
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                state = .paired(library.devices.first(where: { $0.id == link.id })?.name ?? "your Mac")
            }
        }
    }
}

private struct OptionRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Brand.river)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Six boxes for the code the Mac shows. Pairing starts on the sixth digit.
private struct CodeEntry: View {
    let mac: Nearby.Mac
    let submit: (String) -> Void
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("Enter the code")
                    .font(.system(.title, design: .rounded).weight(.bold))
                Text("It's in Holt Settings on \(mac.name), under Devices.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    let digit = index < code.count ? String(Array(code)[index]) : ""
                    Text(digit)
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        .frame(width: 46, height: 58)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(index == code.count && focused ? Brand.river : .clear, lineWidth: 2)
                        }
                        // A gap between the two halves, the way the Mac shows the code.
                        .padding(.trailing, index == 2 ? 10 : 0)
                }
            }
            .background {
                // The real field, invisible. The boxes above show what it holds.
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .opacity(0.01)
            }
            .onTapGesture { focused = true }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .onAppear { focused = true }
        .onChange(of: code) { _, new in
            code = String(new.filter(\.isNumber).prefix(6))
            if code.count == 6 { submit(code) }
        }
    }
}

private struct PairingProgress: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Pairing").font(.system(.title3, design: .rounded).weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Paired: View {
    let name: String
    let done: () -> Void

    var body: some View {
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
            Text("What you copy on your Mac shows up here. What you send from this iPhone lands there.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            Spacer()
            Button("Done", action: done)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }
}
