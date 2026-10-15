import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Streaming OME-TIFF writer for (T, C, Z, Y, X) stacks.
///
/// Pages are written in T, C, Z order (Z fastest), one uncompressed strip
/// per page, as `save_ome_tiff` does through tifffile. Pixel data goes to
/// disk as it arrives; the directories go at the end of the file. The file
/// is written under a temporary name and renamed on `finish()`, so a failed
/// run never leaves a partial file at the output path.
public final class OMETIFFWriter {
    public let url: URL
    public let t: Int, c: Int, z: Int, y: Int, x: Int
    public let type: SampleType
    public let bigTIFF: Bool
    private let metadata: ImageMetadata
    private let tempURL: URL
    private var fd: Int32
    private var position: UInt64
    private var pageOffsets: [UInt64] = []
    private var finished = false

    public var pagesWritten: Int { pageOffsets.count }
    public var pageCount: Int { t * c * z }
    public var planeBytes: Int { y * x * type.byteCount }

    /// - Parameter bigTIFF: `true` forces BigTIFF (tifffile's streaming mode).
    ///   `nil` selects BigTIFF only when the data would not fit a classic TIFF.
    public init(url: URL, t: Int, c: Int, z: Int, y: Int, x: Int, type: SampleType,
                metadata: ImageMetadata, bigTIFF: Bool? = nil) throws {
        self.url = url
        self.t = t; self.c = c; self.z = z; self.y = y; self.x = x
        self.type = type
        self.metadata = metadata
        let dataBytes = UInt64(t * c * z) * UInt64(y * x * type.byteCount)
        let limit: UInt64 = (1 << 32) - (1 << 25)  // tifffile: 4 GB minus 32 MB
        self.bigTIFF = bigTIFF ?? (dataBytes > limit)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".writing-\(UUID().uuidString)-\(url.lastPathComponent)")
        let handle = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard handle >= 0 else { throw DCError("Cannot create \(temp.path): \(String(cString: strerror(errno)))") }
        tempURL = temp
        fd = handle
        position = 0
        // Header; the first-IFD offset is patched in finish().
        var header = [UInt8]()
        if self.bigTIFF {
            header = [0x49, 0x49, 43, 0, 8, 0, 0, 0] + [UInt8](repeating: 0, count: 8)
        } else {
            header = [0x49, 0x49, 42, 0, 0, 0, 0, 0]
        }
        try writeBytes(header)
    }

    deinit {
        if !finished {
            close(fd)
            unlink(tempURL.path)
        }
    }

    private func writeRaw(_ p: UnsafeRawPointer, _ n: Int) throws {
        var done = 0
        while done < n {
            let w = write(fd, p + done, n - done)
            if w < 0 {
                if errno == EINTR { continue }
                throw DCError("Write error in \(url.lastPathComponent): \(String(cString: strerror(errno)))")
            }
            done += w
        }
        position += UInt64(n)
    }

    private func writeBytes(_ b: [UInt8]) throws {
        try b.withUnsafeBytes { try writeRaw($0.baseAddress!, $0.count) }
    }

    /// Append one (Y, X) plane of `type` samples in native (little-endian) order.
    public func writePlane(_ p: UnsafeRawPointer) throws {
        guard pageOffsets.count < pageCount else { throw DCError("Too many planes written to \(url.lastPathComponent)") }
        // Keep plane data 2-byte aligned for readers that map pages directly.
        if position % 2 == 1 { try writeBytes([0]) }
        pageOffsets.append(position)
        try writeRaw(p, planeBytes)
    }

    /// Append all planes of one timepoint.
    public func writeVolume(_ v: Volume) throws {
        guard v.c == c, v.z == z, v.y == y, v.x == x, v.type == type else {
            throw DCError("Frame shape does not match the output \(url.lastPathComponent)")
        }
        if position % 2 == 1 { try writeBytes([0]) }
        // Planes are contiguous in the volume: one write for the whole block.
        for k in 0..<v.planeCount { pageOffsets.append(position + UInt64(k * planeBytes)) }
        guard pageOffsets.count <= pageCount else { throw DCError("Too many planes written to \(url.lastPathComponent)") }
        try writeRaw(v.storage.raw, v.byteCount)
    }

    /// Write the directories, close the file and move it to `url`.
    public func finish() throws {
        guard !finished else { return }
        guard pageOffsets.count == pageCount else {
            throw DCError("\(url.lastPathComponent): wrote \(pageOffsets.count) of \(pageCount) planes")
        }
        if position % 2 == 1 { try writeBytes([0]) }
        let firstIFD = position
        let block = buildDirectories(start: firstIFD)
        try writeBytes(block)
        // Patch the first-IFD offset in the header.
        var patch = [UInt8]()
        if bigTIFF { patch = le64(firstIFD) } else { patch = le32(UInt32(firstIFD)) }
        let at: off_t = bigTIFF ? 8 : 4
        let ok = patch.withUnsafeBytes { pwrite(fd, $0.baseAddress!, $0.count, at) } == patch.count
        guard ok else { throw DCError("Cannot finalize \(url.lastPathComponent)") }
        guard close(fd) == 0 else { throw DCError("Cannot close \(url.lastPathComponent)") }
        fd = -1
        finished = true
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    private func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    private struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: UInt64
        var value: [UInt8]  // already encoded, little-endian
    }

    private func buildDirectories(start: UInt64) -> [UInt8] {
        let description = Array(OMEXML.build(t: t, c: c, z: z, y: y, x: x, type: type, metadata: metadata).utf8) + [0]
        let software = Array("DriftCorrect".utf8) + [0]
        let rational: [UInt8] = le32(1) + le32(1)
        let offsetType: UInt16 = bigTIFF ? 16 : 4

        var out = [UInt8]()
        out.reserveCapacity(pageCount * (bigTIFF ? 260 : 200) + description.count + 64)
        let inlineCapacity = bigTIFF ? 8 : 4
        let entrySize = bigTIFF ? 20 : 12

        for (i, offset) in pageOffsets.enumerated() {
            var entries: [Entry] = [
                Entry(tag: 256, type: 4, count: 1, value: le32(UInt32(x))),
                Entry(tag: 257, type: 4, count: 1, value: le32(UInt32(y))),
                Entry(tag: 258, type: 3, count: 1, value: le16(UInt16(type.byteCount * 8))),
                Entry(tag: 259, type: 3, count: 1, value: le16(1)),
                Entry(tag: 262, type: 3, count: 1, value: le16(1)),
            ]
            if i == 0 { entries.append(Entry(tag: 270, type: 2, count: UInt64(description.count), value: description)) }
            entries.append(Entry(tag: 273, type: offsetType, count: 1, value: bigTIFF ? le64(offset) : le32(UInt32(offset))))
            entries.append(Entry(tag: 277, type: 3, count: 1, value: le16(1)))
            entries.append(Entry(tag: 278, type: 4, count: 1, value: le32(UInt32(y))))
            entries.append(Entry(tag: 279, type: offsetType, count: 1,
                                 value: bigTIFF ? le64(UInt64(planeBytes)) : le32(UInt32(planeBytes))))
            entries.append(Entry(tag: 282, type: 5, count: 1, value: rational))
            entries.append(Entry(tag: 283, type: 5, count: 1, value: rational))
            entries.append(Entry(tag: 296, type: 3, count: 1, value: le16(1)))
            if i == 0 { entries.append(Entry(tag: 305, type: 2, count: UInt64(software.count), value: software)) }
            if type == .float32 { entries.append(Entry(tag: 339, type: 3, count: 1, value: le16(3))) }

            let ifdStart = start + UInt64(out.count)
            let headerSize = (bigTIFF ? 8 : 2) + entries.count * entrySize + (bigTIFF ? 8 : 4)
            var extra = [UInt8]()
            var dir = [UInt8]()
            dir += bigTIFF ? le64(UInt64(entries.count)) : le16(UInt16(entries.count))
            for e in entries {
                dir += le16(e.tag) + le16(e.type)
                dir += bigTIFF ? le64(e.count) : le32(UInt32(e.count))
                if e.value.count <= inlineCapacity {
                    dir += e.value + [UInt8](repeating: 0, count: inlineCapacity - e.value.count)
                } else {
                    if (headerSize + extra.count) % 2 == 1 { extra.append(0) }
                    let ptr = ifdStart + UInt64(headerSize + extra.count)
                    dir += bigTIFF ? le64(ptr) : le32(UInt32(ptr))
                    extra += e.value
                }
            }
            if extra.count % 2 == 1 { extra.append(0) }
            let isLast = i == pageOffsets.count - 1
            let next: UInt64 = isLast ? 0 : ifdStart + UInt64(headerSize + extra.count)
            dir += bigTIFF ? le64(next) : le32(UInt32(next))
            out += dir
            out += extra
        }
        return out
    }
}
