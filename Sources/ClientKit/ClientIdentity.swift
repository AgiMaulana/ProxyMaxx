import AppKit
import FlowKit

/// Groups nested app helpers under their containing app; keeps bare executable paths.
enum ClientIdentity {
    static func client(for pid: Int32) -> ClientApp? {
        guard pid > 0, let executable = executablePath(pid: pid) else { return nil }
        let running = NSRunningApplication(processIdentifier: pid)
        guard running?.isTerminated != true else { return nil }
        let bundlePath = outermostBundlePath(for: executable)
            ?? running?.bundleURL.flatMap { outermostBundlePath(for: $0.path) }

        if let bundlePath, let bundle = Bundle(path: bundlePath) {
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
            return ClientApp(
                name: name,
                bundleIdentifier: bundle.bundleIdentifier,
                path: bundlePath,
                pid: pid
            )
        }

        return ClientApp(
            name: processName(pid: pid) ?? (executable as NSString).lastPathComponent,
            path: executable,
            pid: pid
        )
    }

    /// The first `.app` component identifies the containing app rather than its helper.
    static func outermostBundlePath(for path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let end = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[...end]))
    }

    static func executablePath(pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro Swift cannot import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }

    static func processName(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let written = proc_name(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
