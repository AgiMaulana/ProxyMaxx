import AppKit

/// Restores machine-wide settings when the app terminates.
///
/// Enabling the system proxy without putting it back would leave the machine pointed at a
/// port that no longer has a listener, which breaks networking until it is fixed by hand.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?


    func applicationWillTerminate(_ notification: Notification) {
        model?.restoreSystemProxyBeforeExit()
        model?.flushCrossToolStateBeforeExit()
        model?.ruleStore.flushRulesToDisk()
    }
}
