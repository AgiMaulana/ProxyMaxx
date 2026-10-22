import Foundation
import Compression
import libzstd
import SwiftBrotli

/// Reverses the `Content-Encoding` a server applied to a message body.
///
/// The proxy relays upstream bytes untouched, so a compressed body is recorded
/// exactly as it arrived. Rendering those bytes as text produces mojibake, so the
/// payload is inflated here before it reaches the inspector.
public enum ContentDecoding {
    /// Decode `data` according to a `Content-Encoding` value.
    ///
    /// Returns nil when there is no encoding, when it is `identity`, or when it is
    /// one this build cannot inflate (`compress`, or a coding not yet seen), leaving
    /// the caller to fall back to the raw bytes.
    public static func decode(_ data: Data, encoding: String?) -> Data? {
        guard let encoding else { return nil }
        let value = encoding
            .split(separator: ",")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch value {
        case "gzip", "x-gzip": return gunzip(data)
        case "deflate", "x-deflate": return inflate(data)
        case "br": return decompressBrotli(data)
        case "zstd": return decompressZstd(data)
        default: return nil
        }
    }

    /// Ceiling on a decoded body, so a decompression bomb cannot exhaust memory.
    /// Both decoders below grow their buffer up to this and then give up.
    private static let maximumDecodedSize = 64 * 1024 * 1024

    /// The first buffer size to attempt: small bodies decode on the first try, and
    /// larger ones climb the ladder from here.
    private static let initialBufferSize = 64 * 1024

    /// Brotli (RFC 7932). The decoder is one-shot and reports every failure the same
    /// way, so a too-small buffer is indistinguishable from corrupt input; the only
    /// safe response is to retry larger until the ceiling is reached.
    private static func decompressBrotli(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let decoder = Brotli()
        var capacity = max(initialBufferSize, min(data.count * 8, 1024 * 1024))
        while capacity <= maximumDecodedSize {
            if case .success(let decoded) = decoder.decompress(data, maximumDecompressedSize: capacity) {
                return decoded
            }
            capacity *= 8
        }
        return nil
    }

    /// Zstandard (RFC 8878). `ZSTD_getFrameContentSize` is not consulted because a
    /// frame may omit its size or, as with a streaming encoder, admit to not knowing
    /// it; the buffer is grown until the frame fits instead.
    private static func decompressZstd(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let source = [UInt8](data)
        var capacity = max(initialBufferSize, min(data.count * 8, 1024 * 1024))
        while capacity <= maximumDecodedSize {
            var destination = [UInt8](repeating: 0, count: capacity)
            let written = ZSTD_decompress(&destination, capacity, source, source.count)
            if ZSTD_isError(written) == 0 {
                return Data(destination[0..<written])
            }
            capacity *= 8
        }
        return nil
    }

    /// Strip a gzip member's header and trailer (RFC 1952), then inflate the DEFLATE payload.
    private static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return nil }

        var index = 10
        let flags = bytes[3]
        if flags & 0x04 != 0 { // FEXTRA: a length-prefixed block
            guard index + 2 <= bytes.count else { return nil }
            let length = Int(bytes[index]) | Int(bytes[index + 1]) << 8
            index += 2 + length
        }
        if flags & 0x08 != 0 { index = afterZeroTerminated(bytes, from: index) } // FNAME
        if flags & 0x10 != 0 { index = afterZeroTerminated(bytes, from: index) } // FCOMMENT
        if flags & 0x02 != 0 { index += 2 } // FHCRC

        // The last eight bytes are the CRC32 and the uncompressed size, neither of
        // which the inflater needs.
        guard index >= 0, index <= bytes.count - 8 else { return nil }
        let payload = Data(bytes[index..<(bytes.count - 8)])
        let size = Int(bytes[bytes.count - 4])
            | Int(bytes[bytes.count - 3]) << 8
            | Int(bytes[bytes.count - 2]) << 16
            | Int(bytes[bytes.count - 1]) << 24
        return inflateRaw(payload, expectedSize: size)
    }

    /// Inflate a `deflate` body, which may or may not carry a zlib wrapper (RFC 1950).
    private static func inflate(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        let hasZlibWrapper = bytes.count > 6
            && bytes[0] & 0x0f == 0x08
            && (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0
        if hasZlibWrapper {
            return inflateRaw(Data(bytes[2..<(bytes.count - 4)]), expectedSize: 0)
        }
        return inflateRaw(data, expectedSize: 0)
    }

    private static func afterZeroTerminated(_ bytes: [UInt8], from index: Int) -> Int {
        var cursor = index
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        return cursor + 1
    }

    /// Inflate a bare DEFLATE stream, growing the output buffer until the stream ends.
    private static func inflateRaw(_ source: Data, expectedSize: Int) -> Data? {
        guard !source.isEmpty else { return Data() }

        // The trailer states the uncompressed size, but it is attacker-controlled and
        // may be zero or wrong, so it only seeds the buffer between a floor and a cap.
        let bufferSize = max(64 * 1024, min(expectedSize, 8 * 1024 * 1024))
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        // The stream's pointers are non-optional, so they are seeded to the live buffer
        // and overwritten before each pass; `compression_stream_init` ignores them.
        var stream = compression_stream(
            dst_ptr: destination,
            dst_size: 0,
            src_ptr: UnsafePointer(destination),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        return source.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = source.count
            while true {
                stream.dst_ptr = destination
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                if produced > 0 { output.append(destination, count: produced) }
                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    // No output and no end means the input was exhausted mid-stream.
                    if produced == 0 { return output }
                default:
                    return nil
                }
            }
        }
    }
}
