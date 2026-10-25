import Foundation

// ZIPFoundation treats unknown Unix types as files and may end iteration early on a
// malformed header. Check the directory and local headers before trusting its entries.
struct MapLocalBundleZIPStructure {
    struct Record {
        let checksum: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let directory: Bool
    }

    static let maximumEntries = 10_000
    static let maximumFileBytes: UInt64 = 512 * 1_024 * 1_024
    static let maximumTotalBytes: UInt64 = 1_024 * 1_024 * 1_024
    static let maximumArchiveBytes: UInt64 = maximumTotalBytes + 16 * 1_024 * 1_024
    static let maximumManifestBytes: UInt64 = 4 * 1_024 * 1_024

    let records: [Record]

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length <= Self.maximumArchiveBytes else {
            throw MapLocalBundleError.resourceLimit("ZIP exceeds 1 GiB plus metadata.")
        }
        guard length >= 22 else { throw Self.invalid("Missing ZIP end record.") }
        let tailLength = Int(min(length, 65_557))
        let tail = try Self.read(handle, at: length - UInt64(tailLength), count: tailLength)
        var endIndex: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.u32(index) == 0x06054b50,
               index + 22 + Int(tail.u16(index + 20)) == tail.count {
                endIndex = index
                break
            }
        }
        guard let endIndex else { throw Self.invalid("Missing or truncated ZIP end record.") }
        let end = tail.subdata(in: endIndex..<(endIndex + 22))
        guard end.u16(4) == 0, end.u16(6) == 0, end.u16(8) == end.u16(10) else {
            throw Self.invalid("Split or multi-disk ZIP archives are not supported.")
        }
        let count = Int(end.u16(10))
        let centralSize = UInt64(end.u32(12))
        let centralOffset = UInt64(end.u32(16))
        guard count != Int(UInt16.max), centralSize != UInt64(UInt32.max), centralOffset != UInt64(UInt32.max) else {
            throw Self.invalid("ZIP64 archives are not supported by bundle format 1; use a ZIP under the resource limits.")
        }
        guard count <= Self.maximumEntries else {
            throw MapLocalBundleError.resourceLimit("More than \(Self.maximumEntries) ZIP entries.")
        }
        let endOffset = length - UInt64(tailLength) + UInt64(endIndex)
        guard centralOffset + centralSize == endOffset else {
            throw Self.invalid("Central directory size or offset is inconsistent.")
        }
        var position = centralOffset
        var records: [Record] = []
        var ranges: [Range<UInt64>] = []
        var total: UInt64 = 0
        for _ in 0..<count {
            guard position + 46 <= endOffset else { throw Self.invalid("Truncated central directory.") }
            let header = try Self.read(handle, at: position, count: 46)
            guard header.u32(0) == 0x02014b50 else { throw Self.invalid("Invalid central directory entry.") }
            let flags = header.u16(8)
            let compression = header.u16(10)
            guard flags & ~UInt16(0x080e) == 0, compression == 0 || compression == 8 else {
                throw Self.invalid("Encrypted entries or unsupported ZIP compression/flags.")
            }
            guard header.u16(6) < 45, header.u16(34) == 0 else {
                throw Self.invalid("ZIP64 or split entries are not supported.")
            }
            let nameLength = Int(header.u16(28))
            let extraLength = Int(header.u16(30))
            let commentLength = Int(header.u16(32))
            guard nameLength > 0, nameLength <= 1_024,
                  position + UInt64(46 + nameLength + extraLength + commentLength) <= endOffset else {
                throw Self.invalid("Invalid or oversized ZIP entry name.")
            }
            let name = try Self.read(handle, at: position + 46, count: nameLength)
            let extra = try Self.read(handle, at: position + UInt64(46 + nameLength), count: extraLength)
            try Self.validateExtra(extra)
            let compressed = UInt64(header.u32(20))
            let uncompressed = UInt64(header.u32(24))
            guard uncompressed <= Self.maximumFileBytes else {
                throw MapLocalBundleError.resourceLimit("A response file exceeds 512 MiB.")
            }
            total += uncompressed
            guard total <= Self.maximumTotalBytes else {
                throw MapLocalBundleError.resourceLimit("Uncompressed responses exceed 1 GiB.")
            }
            let attributes = header.u32(38)
            let host = header.u16(4) >> 8
            let mode = (attributes >> 16) & 0xf000
            guard mode == 0 || mode == 0x8000 || mode == 0x4000 else {
                throw Self.invalid("Symbolic links and non-regular filesystem entries are forbidden.")
            }
            guard host == 0 || host == 3 || host == 19 else {
                throw Self.invalid("Unsupported ZIP filesystem type \(host).")
            }
            let hasSlash = name.last == 47
            let directory = mode == 0x4000 || (mode == 0 && (hasSlash || attributes & 0x10 != 0))
            guard directory == hasSlash, !directory || (compressed == 0 && uncompressed == 0 && header.u32(16) == 0) else {
                throw Self.invalid("ZIP entry type disagrees with its name or directory data.")
            }
            guard compression != 0 || compressed == uncompressed else {
                throw Self.invalid("Stored entry sizes disagree.")
            }
            let offset = UInt64(header.u32(42))
            guard offset + 30 <= centralOffset else { throw Self.invalid("Invalid local header offset.") }
            let local = try Self.read(handle, at: offset, count: 30)
            guard local.u32(0) == 0x04034b50,
                  local.u16(4) == header.u16(6), local.u16(6) == flags,
                  local.u16(8) == compression, Int(local.u16(26)) == nameLength else {
                throw Self.invalid("Local and central ZIP headers disagree.")
            }
            let localExtraLength = Int(local.u16(28))
            let dataOffset = offset + UInt64(30 + nameLength + localExtraLength)
            guard dataOffset + compressed <= centralOffset else { throw Self.invalid("Entry data overlaps the central directory.") }
            guard try Self.read(handle, at: offset + 30, count: nameLength) == name else {
                throw Self.invalid("Local and central ZIP entry names disagree.")
            }
            try Self.validateExtra(Self.read(handle, at: offset + UInt64(30 + nameLength), count: localExtraLength))
            var rangeEnd = dataOffset + compressed
            if flags & 8 == 0 {
                guard local.u32(14) == header.u32(16), local.u32(18) == header.u32(20), local.u32(22) == header.u32(24) else {
                    throw Self.invalid("Local and central ZIP checksums or sizes disagree.")
                }
            } else {
                guard rangeEnd + 12 <= centralOffset else { throw Self.invalid("Truncated data descriptor.") }
                let first = try Self.read(handle, at: rangeEnd, count: 4)
                let signed = first.u32(0) == 0x08074b50
                let descriptorSize = signed ? 16 : 12
                guard rangeEnd + UInt64(descriptorSize) <= centralOffset else { throw Self.invalid("Truncated data descriptor.") }
                let descriptor = try Self.read(handle, at: rangeEnd, count: descriptorSize)
                let start = signed ? 4 : 0
                guard descriptor.u32(start) == header.u32(16), descriptor.u32(start + 4) == header.u32(20), descriptor.u32(start + 8) == header.u32(24) else {
                    throw Self.invalid("ZIP data descriptor disagrees with the central directory.")
                }
                rangeEnd += UInt64(descriptorSize)
            }
            ranges.append(offset..<rangeEnd)
            records.append(Record(checksum: header.u32(16), compressedSize: compressed,
                                  uncompressedSize: uncompressed, directory: directory))
            position += UInt64(46 + nameLength + extraLength + commentLength)
        }
        guard position == endOffset else { throw Self.invalid("Central directory entry count is inconsistent.") }
        let sortedRanges = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<max(1, sortedRanges.count) {
            guard sortedRanges[index - 1].upperBound <= sortedRanges[index].lowerBound else {
                throw Self.invalid("ZIP entries overlap or share a local header.")
            }
        }
        self.records = records
    }

    private static func validateExtra(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            guard offset + 4 <= data.count else { throw invalid("Truncated ZIP extra field.") }
            let size = Int(data.u16(offset + 2))
            guard data.u16(offset) != 1, offset + 4 + size <= data.count else {
                throw invalid("ZIP64 or malformed extra fields are not supported.")
            }
            offset += 4 + size
        }
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw invalid("Truncated ZIP metadata.") }
        return data
    }

    private static func invalid(_ reason: String) -> MapLocalBundleError { .invalidArchive(reason) }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }
}
