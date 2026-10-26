import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share → Holt from any app: sends the shared text or link to your paired Macs.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let status = ShareStatus()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(status: status))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { @MainActor in
            let start = Date()
            Core.log("share: started")
            guard let text = await sharedText() else {
                Core.log("share: nothing to send")
                status.state = .nothing
                try? await Task.sleep(for: .seconds(1.2))
                extensionContext?.completeRequest(returningItems: nil)
                return
            }
            let sent = await Core.shared.send(text)
            Core.log("share: done in \(ms(since: start)) ms, connected: \(sent)")
            status.state = sent ? .sent : .saved
            try? await Task.sleep(for: .seconds(0.9))
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// A link if there is one, otherwise plain text.
    private func sharedText() async -> String? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return url.absoluteString
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                return text
            }
        }
        return nil
    }
}

@MainActor
@Observable
final class ShareStatus {
    enum State { case sending, sent, saved, nothing }
    var state = State.sending
}

private struct ShareView: View {
    let status: ShareStatus

    var body: some View {
        VStack(spacing: 10) {
            switch status.state {
            case .sending:
                ProgressView()
                Text("Sending to your Mac…")
            case .sent:
                Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.teal)
                Text("Sent to your Mac")
            case .saved:
                Image(systemName: "tray.and.arrow.down.fill").font(.title).foregroundStyle(.teal)
                Text("Saved. It goes to your Mac when it's reachable.").multilineTextAlignment(.center)
            case .nothing:
                Image(systemName: "questionmark.circle").font(.title).foregroundStyle(.secondary)
                Text("There's no text or link to send.")
            }
        }
        .font(.headline)
        .padding(28)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
