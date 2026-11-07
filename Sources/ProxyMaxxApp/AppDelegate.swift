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
        model?.shutdownCrashReportingBeforeExit()
    }

    /// A window-less launch leaves the app running with capture on and nothing to look at:
    /// clicking the Dock icon reopens what the Scene closed, which keeps the engine's
    /// session reachable instead of asking the user to quit and relaunch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        sender.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        for window in sender.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            break
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}
