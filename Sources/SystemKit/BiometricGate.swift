import Foundation
import LocalAuthentication

/// Touch ID / Face ID confirmation for privileged actions.
///
/// This proves the person at the keyboard is the owner, and can stand in for a typed
/// administrator password wherever the underlying operation does not itself demand an
/// interactive authorization.
public enum BiometricGate {
    /// True when this Mac has usable biometric hardware that is enrolled.
    public static var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Name of the sensor, for display: "Touch ID", "Face ID", …
    public static var displayName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Biometrics"
        }
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }

    /// Ask for a biometric confirmation, blocking until the user responds.
    ///
    /// Safe to call from a background thread; the sheet is presented by the system, not the
    /// app. The password fallback is deliberately left enabled so a failed sensor can never
    /// lock someone out of their own machine.
    @discardableResult
    public static func authorize(reason: String) -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            granted = success
            semaphore.signal()
        }
        semaphore.wait()
        return granted
    }
}
