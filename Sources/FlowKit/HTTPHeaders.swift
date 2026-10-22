import Foundation

/// A single HTTP header field. Order and duplicates are preserved.
public struct Header: Codable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// An ordered, case-insensitive HTTP header collection.
public struct HTTPHeaders: Codable, Hashable, Sendable {
    public private(set) var entries: [Header]

    public init(_ entries: [Header] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Case-insensitive lookup of the first matching header.
    public subscript(name: String) -> String? {
        get {
            entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        set {
            if let newValue {
                if let index = entries.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    entries[index].value = newValue
                } else {
                    entries.append(Header(name: name, value: newValue))
                }
            } else {
                entries.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            }
        }
    }

    public mutating func add(name: String, value: String) {
        entries.append(Header(name: name, value: value))
    }

    public mutating func set(name: String, value: String) {
        self[name] = value
    }

    public mutating func remove(name: String) {
        entries.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func allValues(for name: String) -> [String] {
        entries.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public func contains(name: String) -> Bool {
        entries.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public var contentLength: Int? {
        self["Content-Length"].flatMap(Int.init)
    }

    public var contentType: MIMEType? {
        self["Content-Type"].flatMap(MIMEType.init(rawValue:))
    }

    public var host: String? { self["Host"] }
}
