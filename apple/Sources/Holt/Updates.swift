import AppKit
import Sparkle

/// Sparkle checks for a new version once a day. When there is one, the menu bar
/// menu offers it instead of Sparkle opening its window by itself. Picking it opens
/// Sparkle, which downloads the update, checks its signature and relaunches Holt.
@MainActor
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    /// The version waiting to be installed, if any.
    private(set) var available: String?

    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        // Builds from `make run` have no feed, so they never replace themselves with a release.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var canCheck: Bool { controller != nil }

    func check() {
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A check Sparkle runs on its own shows up in the menu. One you ask for opens Sparkle right away.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if !handleShowingUpdate { available = version }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { available = nil }
    }
}
