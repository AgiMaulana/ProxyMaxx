import Foundation

/// Shell-style wildcard matching (`*` = any run, `?` = one character).
public enum Wildcard {
    /// Match `value` against a `pattern` containing `*` and `?` wildcards.
    public static func matches(pattern: String, value: String, caseSensitive: Bool = false) -> Bool {
        let pattern = caseSensitive ? pattern : pattern.lowercased()
        let value = caseSensitive ? value : value.lowercased()
        if pattern.isEmpty { return value.isEmpty }
        if !pattern.contains("*") && !pattern.contains("?") {
            return pattern == value
        }
        return isMatch(Array(pattern), Array(value))
    }

    private static func isMatch(_ pattern: [Character], _ value: [Character]) -> Bool {
        var p = 0, v = 0
        var starIndex = -1
        var matchIndex = 0

        while v < value.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == value[v] {
                p += 1
                v += 1
            } else if p < pattern.count, pattern[p] == "*" {
                starIndex = p
                matchIndex = v
                p += 1
            } else if starIndex != -1 {
                p = starIndex + 1
                matchIndex += 1
                v = matchIndex
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
