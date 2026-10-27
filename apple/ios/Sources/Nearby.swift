import Network
import SwiftUI

/// Macs on this network with Holt Settings → Devices open, found over Bonjour. They
/// publish their device id in the TXT record, so pairing only needs the 6-digit code.
@MainActor
@Observable
final class Nearby {
    struct Mac: Identifiable, Hashable {
        let id: String
        let name: String
    }

    private(set) var macs: [Mac] = []
    /// iOS reports a denied Local Network permission as a policy error on the browser.
    private(set) var denied = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_holt-pair._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { result -> Mac? in
                guard case .service(let name, _, _, _) = result.endpoint,
                    case .bonjour(let txt) = result.metadata,
                    let id = txt["id"]
                else { return nil }
                return Mac(id: id, name: name)
            }
            Task { @MainActor in self?.macs = macs.sorted { $0.name < $1.name } }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let denied: Bool
            if case .waiting(.dns(let code)) = state, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                denied = true
            } else {
                denied = false
            }
            Task { @MainActor in self?.denied = denied }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// River teal with text that stays readable in dark mode, where the teal is lighter.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Brand.onRiver)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Brand.river, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
