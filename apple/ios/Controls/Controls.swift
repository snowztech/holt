import SwiftUI
import WidgetKit

@main
struct HoltControls: WidgetBundle {
    var body: some Widget {
        SendClipboardControl()
    }
}

/// A Control Center and lock screen button: copy something, tap it, and it's on your Mac.
struct SendClipboardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.holtclip.Holt.send-clipboard") {
            ControlWidgetButton(action: SendClipboardToHolt()) {
                Label("Send Clipboard", systemImage: "doc.on.clipboard")
            }
        }
        .displayName("Send Clipboard to Holt")
        .description("Sends what you copied to your paired Macs.")
    }
}
