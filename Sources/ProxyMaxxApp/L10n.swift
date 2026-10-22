import Foundation

/// Lookups for text the UI builds in code rather than in a `Text` literal.
///
/// Keys are stable symbolic identifiers such as `main.systemProxy`; the English copy lives in
/// `Resources/en.lproj/Localizable.strings`. `Scripts/run.sh` puts the `.lproj` folders
/// beside the unbundled binary, while `Scripts/bundle-app.sh` ships every language it finds.
enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
    }
}
