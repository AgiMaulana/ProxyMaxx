import XCTest
@testable import SystemKit

/// Covers the decisions that must be right before anything touches a device: which devices
/// are usable, what the installer is told, and how a command is quoted for a human to paste.
final class AndroidInstallerTests: XCTestCase {
    private let script = URL(fileURLWithPath: "/tmp/install_certificate_android_emulator.sh")
    private let certificate = URL(fileURLWithPath: "/tmp/ca.pem")
    private let apk = URL(fileURLWithPath: "/tmp/proxymaxx-vpn.apk")
    private let state = URL(fileURLWithPath: "/tmp/state")

    private func magisk() -> AndroidMagiskAssets {
        AndroidMagiskAssets(
            version: "30.7",
            apk: URL(fileURLWithPath: "/tmp/Magisk-v30.7.apk"),
            hostPatch: URL(fileURLWithPath: "/tmp/host_patch.sh"),
            script: URL(fileURLWithPath: "/tmp/magisk.sh")
        )
    }

    private func paths(magiskAssets: AndroidMagiskAssets? = nil, tunnel: URL? = nil) -> AndroidInstallPaths {
        AndroidInstallPaths(script: script, certificate: certificate, tunnelAPK: tunnel, magisk: magiskAssets)
    }

    private func request(mode: AndroidInstallMode) -> AndroidInstallRequest {
        AndroidInstallRequest(
            mode: mode,
            host: "10.0.2.2",
            httpPort: 9090,
            socksPort: 8989,
            certificatePEM: "-----BEGIN CERTIFICATE-----",
            includePhysical: false,
            enableMagisk: true,
            serial: "emulator-5554",
            stateDirectory: state
        )
    }

    // MARK: - Device parsing

    func testParsesUsableDevicesAndSkipsTheRest() {
        let output = """
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
        emulator-5556          offline transport_id:2
        1A2B3C4D               unauthorized usb:336592896X transport_id:3
        R58M12ABCDE            device product:beyond1 model:SM_G973F device:beyond1 transport_id:4
        """

        let devices = AndroidToolchain.parseDevices(output)

        XCTAssertEqual(devices.map(\.serial), ["emulator-5554", "R58M12ABCDE"])
        XCTAssertEqual(devices[0].isEmulator, true)
        XCTAssertEqual(devices[1].isEmulator, false)
        // Model names arrive underscored; they read better with spaces.
        XCTAssertEqual(devices[1].model, "SM G973F")
    }

    func testAnEmptyListingYieldsNoDevices() {
        XCTAssertTrue(AndroidToolchain.parseDevices("List of devices attached\n\n").isEmpty)
    }

    /// An emulator always reaches its host at 10.0.2.2; a real device cannot use that address.
    func testEmulatorsGetTheEmulatorHostAddress() {
        XCTAssertEqual(AndroidToolchain.hostAddress(forEmulator: true), "10.0.2.2")
    }

    // MARK: - Arguments

    func testAutomaticModePassesEverythingTheScriptNeeds() {
        let arguments = AndroidInstaller.arguments(for: request(mode: .auto), paths: paths(magiskAssets: magisk(), tunnel: apk))

        XCTAssertEqual(Array(arguments.prefix(2)), ["-m", "all"])
        XCTAssertTrue(arguments.contains("-i"))
        XCTAssertTrue(arguments.contains("10.0.2.2"))
        XCTAssertTrue(arguments.contains("9090"))
        XCTAssertTrue(arguments.contains("--socks-port"))
        XCTAssertTrue(arguments.contains("8989"))
        XCTAssertTrue(arguments.contains("--serial"))
        XCTAssertTrue(arguments.contains("emulator-5554"))
        XCTAssertTrue(arguments.contains("--vpn-apk"))
        XCTAssertTrue(arguments.contains("--enable-magisk"))
        XCTAssertTrue(arguments.contains("--magisk-apk"))
        XCTAssertTrue(arguments.contains("--magisk-host-patch"))
        XCTAssertTrue(arguments.contains("--magisk-state-dir"))
        XCTAssertFalse(arguments.contains("--include-physical"))
        XCTAssertFalse(arguments.contains("--uninstall-vpn"))
    }

    /// The whole point of the Google APIs mode is that it never patches the emulator, even
    /// when the Magisk assets are sitting right there.
    func testGoogleAPIsModeNeverEnablesMagisk() {
        let arguments = AndroidInstaller.arguments(for: request(mode: .googleAPIs), paths: paths(magiskAssets: magisk()))

        XCTAssertEqual(Array(arguments.prefix(2)), ["-m", "all"])
        XCTAssertFalse(arguments.contains("--enable-magisk"))
        XCTAssertFalse(arguments.contains("--magisk-apk"))
    }

    func testGoogleAPIsModeStillSetsTheProxyAndCertificate() {
        let arguments = AndroidInstaller.arguments(for: request(mode: .googleAPIs), paths: paths())

        XCTAssertTrue(arguments.contains("-c"))
        XCTAssertTrue(arguments.contains(certificate.path))
        XCTAssertTrue(arguments.contains("--socks-port"))
    }

    func testRevertClearsRatherThanInstalls() {
        let arguments = AndroidInstaller.arguments(for: request(mode: .revert), paths: paths(magiskAssets: magisk(), tunnel: apk))

        XCTAssertEqual(Array(arguments.prefix(2)), ["-m", "revertProxy"])
        XCTAssertTrue(arguments.contains("--uninstall-vpn"))
        XCTAssertTrue(arguments.contains("--restore-magisk"))
        // The certificate is installed into the device's user trust store, so revert has to name
        // it in order to take it back off.
        XCTAssertTrue(arguments.contains("-c"))
        XCTAssertTrue(arguments.contains(certificate.path))
        // Nothing to point a proxy at while reverting.
        XCTAssertFalse(arguments.contains("-i"))
        XCTAssertFalse(arguments.contains("-p"))
        XCTAssertFalse(arguments.contains("--vpn-apk"))
        XCTAssertFalse(arguments.contains("--enable-magisk"))
    }

    /// A build without the Magisk assets must not promise a restore it cannot perform.
    func testRevertWithoutMagiskAssetsDoesNotClaimToRestore() {
        let arguments = AndroidInstaller.arguments(for: request(mode: .revert), paths: paths())

        XCTAssertTrue(arguments.contains("--uninstall-vpn"))
        XCTAssertFalse(arguments.contains("--restore-magisk"))
    }

    func testIncludePhysicalIsOptIn() {
        var withPhysical = request(mode: .auto)
        withPhysical.includePhysical = true
        XCTAssertTrue(AndroidInstaller.arguments(for: withPhysical, paths: paths()).contains("--include-physical"))

        var withoutSerial = request(mode: .auto)
        withoutSerial.serial = nil
        XCTAssertFalse(AndroidInstaller.arguments(for: withoutSerial, paths: paths()).contains("--serial"))
    }

    func testMagiskIsSkippedWhenConsentIsWithheld() {
        var declined = request(mode: .auto)
        declined.enableMagisk = false
        let arguments = AndroidInstaller.arguments(for: declined, paths: paths(magiskAssets: magisk(), tunnel: apk))

        XCTAssertFalse(arguments.contains("--enable-magisk"))
        XCTAssertTrue(arguments.contains("--vpn-apk"), "the tunnel app is still installed")
    }

    // MARK: - Command line

    func testCommandLineIsQuotedSoAPathWithSpacesSurvives() {
        let spaced = AndroidInstallPaths(
            script: URL(fileURLWithPath: "/Applications/ProxyMaxx.app/Contents/Resources/Android/install.sh"),
            certificate: certificate,
            tunnelAPK: nil,
            magisk: nil
        )
        let command = AndroidInstaller.commandLine(for: request(mode: .auto), paths: spaced)

        // Every element is quoted, including the flags, so a path can never be re-split.
        XCTAssertTrue(command.hasPrefix("/bin/bash '/Applications/ProxyMaxx.app/"))
        XCTAssertTrue(command.contains("'-m' 'all'"))
    }

    func testShellQuotingNeutralisesAnEmbeddedQuote() {
        XCTAssertEqual(AndroidInstaller.shellQuoted("it's"), "'it'\\''s'")
    }
}
