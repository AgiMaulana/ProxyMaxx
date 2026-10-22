import Foundation
import NIOHTTP1
import NIOCore
import FlowKit

extension FlowKit.HTTPHeaders {
    /// Convert from NIOHTTP1's header collection, preserving order and duplicates.
    init(nio headers: NIOHTTP1.HTTPHeaders) {
        self.init(headers.map { Header(name: $0.name, value: $0.value) })
    }

    /// Render into NIOHTTP1's header collection.
    var nio: NIOHTTP1.HTTPHeaders {
        var headers = NIOHTTP1.HTTPHeaders()
        headers.reserveCapacity(entries.count)
        for entry in entries {
            headers.add(name: entry.name, value: entry.value)
        }
        return headers
    }
}

extension HTTPVersion {
    var flowString: String { "HTTP/\(major).\(minor)" }
}

extension ByteBuffer {
    /// Copy the readable bytes into `Data` without consuming them.
    var data: Data { Data(readableBytesView) }
}
