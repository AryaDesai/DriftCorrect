import Foundation

/// One image file directory (page) of a TIFF file.
public struct TIFFPage: Sendable {
    public var width: Int = 0
    public var height: Int = 0
    public var bitsPerSample: Int = 1
    public var sampleFormat: Int = 1
    public var samplesPerPixel: Int = 1
    public var compression: Int = 1
    public var predictor: Int = 1
    public var planarConfig: Int = 1
    public var rowsPerStrip: Int = Int.max
    public var stripOffsets: [UInt64] = []
    public var stripByteCounts: [UInt64] = []
    public var isTiled: Bool = false
    public var description: String?
    public var imageJMetadata: [UInt8]?

    public var sampleType: SampleType? { SampleType(bitsPerSample: bitsPerSample, sampleFormat: sampleFormat) }
    public var decodedByteCount: Int { width * height * samplesPerPixel * max(1, bitsPerSample / 8) }
}

/// Minimal, fast TIFF / BigTIFF reader for grayscale image stacks.
///
/// Supports strips with no compression, LZW, Deflate and PackBits, with or
/// without horizontal differencing. Uncompressed pages are read directly
/// into the caller's buffer.
public final class TIFFFile: @unchecked Sendable {
    public let url: URL
    public let file: RandomAccessFile
    public let bigEndian: Bool
    public let isBigTIFF: Bool
    public private(set) var pages: [TIFFPage] = []

    public init(url: URL) throws {
        self.url = url
        let f = try RandomAccessFile(url: url)
        self.file = f
        let head = try f.read(at: 0, count: min(16, Int(f.size)))
        guard head.count >= 8 else { throw DCError("Not a TIFF file: \(url.lastPathComponent)") }
        let be: Bool
        if head[0] == 0x49 && head[1] == 0x49 { be = false }
        else if head[0] == 0x4D && head[1] == 0x4D { be = true }
        else { throw DCError("Not a TIFF file: \(url.lastPathComponent)") }
        bigEndian = be
        let r = ByteReader(head, bigEndian: be)
        let magic = r.u16(at: 2)
        var firstIFD: UInt64
        switch magic {
        case 42:
            isBigTIFF = false
            firstIFD = UInt64(r.u32(at: 4))
        case 43:
            guard head.count >= 16, r.u16(at: 4) == 8 else { throw DCError("Unsupported BigTIFF header") }
            isBigTIFF = true
            firstIFD = r.u64(at: 8)
        default:
            throw DCError("Not a TIFF file: \(url.lastPathComponent)")
        }
        try parseIFDs(from: firstIFD)
    }

    private func parseIFDs(from start: UInt64) throws {
        var offset = start
        var seen = Set<UInt64>()
        let entrySize = isBigTIFF ? 20 : 12
        let countSize = isBigTIFF ? 8 : 2
        let nextSize = isBigTIFF ? 8 : 4
        // Read IFDs through a small cache window to avoid one syscall per tag.
        var window = [UInt8]()
        var windowStart: UInt64 = 0

        func bytes(_ at: UInt64, _ n: Int) throws -> ByteReader {
            if at >= windowStart && at + UInt64(n) <= windowStart + UInt64(window.count) {
                let lo = Int(at - windowStart)
                return ByteReader(Array(window[lo..<lo + n]), bigEndian: bigEndian)
            }
            let want = max(n, 16 * 1024)
            let avail = Int(min(UInt64(want), file.size > at ? file.size - at : 0))
            guard avail >= n else { throw DCError("TIFF directory beyond end of file") }
            window = try file.read(at: at, count: avail)
            windowStart = at
            return ByteReader(Array(window[0..<n]), bigEndian: bigEndian)
        }

        while offset != 0 {
            if seen.contains(offset) { break }
            seen.insert(offset)
            let countReader = try bytes(offset, countSize)
            let n = isBigTIFF ? Int(countReader.u64(at: 0)) : Int(countReader.u16(at: 0))
            guard n > 0 && n < 10000 else { throw DCError("Corrupt TIFF directory at \(offset)") }
            let block = try bytes(offset + UInt64(countSize), n * entrySize + nextSize)
            var page = TIFFPage()
            for k in 0..<n {
                let e = k * entrySize
                let tag = Int(block.u16(at: e))
                let type = Int(block.u16(at: e + 2))
                let count = isBigTIFF ? Int(block.u64(at: e + 4)) : Int(block.u32(at: e + 4))
                let valueFieldOffset = e + (isBigTIFF ? 12 : 8)
                let size = TIFFFile.typeSize(type) * count
                let inlineCapacity = isBigTIFF ? 8 : 4
                let valueBytes: ByteReader
                if size <= inlineCapacity {
                    valueBytes = ByteReader(Array(block.bytes[valueFieldOffset..<valueFieldOffset + inlineCapacity]), bigEndian: bigEndian)
                } else {
                    let ptr = isBigTIFF ? block.u64(at: valueFieldOffset) : UInt64(block.u32(at: valueFieldOffset))
                    guard ptr + UInt64(size) <= file.size else { continue }
                    valueBytes = ByteReader(try file.read(at: ptr, count: size), bigEndian: bigEndian)
                }
                func ints() -> [UInt64] { TIFFFile.integers(valueBytes, type: type, count: count) }
                switch tag {
                case 256: page.width = Int(ints().first ?? 0)
                case 257: page.height = Int(ints().first ?? 0)
                case 258: page.bitsPerSample = Int(ints().first ?? 1)
                case 259: page.compression = Int(ints().first ?? 1)
                case 270:
                    var raw = valueBytes.bytes
                    if raw.count > count { raw = Array(raw[0..<count]) }
                    while let last = raw.last, last == 0 { raw.removeLast() }
                    page.description = String(decoding: raw, as: UTF8.self)
                case 273, 324: page.stripOffsets = ints(); if tag == 324 { page.isTiled = true }
                case 277: page.samplesPerPixel = Int(ints().first ?? 1)
                case 278: page.rowsPerStrip = Int(ints().first ?? UInt64(Int.max))
                case 279, 325: page.stripByteCounts = ints()
                case 284: page.planarConfig = Int(ints().first ?? 1)
                case 317: page.predictor = Int(ints().first ?? 1)
                case 322, 323: page.isTiled = true
                case 339: page.sampleFormat = Int(ints().first ?? 1)
                case 50839: page.imageJMetadata = valueBytes.bytes
                default: break
                }
            }
            if page.rowsPerStrip <= 0 || page.rowsPerStrip > page.height { page.rowsPerStrip = max(1, page.height) }
            pages.append(page)
            let nextReader = try bytes(offset + UInt64(countSize) + UInt64(n * entrySize), nextSize)
            offset = isBigTIFF ? nextReader.u64(at: 0) : UInt64(nextReader.u32(at: 0))
        }
        if pages.isEmpty { throw DCError("TIFF has no pages: \(url.lastPathComponent)") }
    }

    static func typeSize(_ type: Int) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11, 13: return 4
        case 5, 10, 12, 16, 17, 18: return 8
        default: return 1
        }
    }

    static func integers(_ r: ByteReader, type: Int, count: Int) -> [UInt64] {
        var out = [UInt64]()
        out.reserveCapacity(count)
        for i in 0..<count {
            switch type {
            case 1, 6, 7: if i < r.bytes.count { out.append(UInt64(r.u8(at: i))) }
            case 3, 8: if 2 * i + 2 <= r.bytes.count { out.append(UInt64(r.u16(at: 2 * i))) }
            case 4, 9, 13: if 4 * i + 4 <= r.bytes.count { out.append(UInt64(r.u32(at: 4 * i))) }
            case 16, 17, 18: if 8 * i + 8 <= r.bytes.count { out.append(r.u64(at: 8 * i)) }
            default: break
            }
        }
        return out
    }

    /// Decode page `index` into `destination` as native-endian samples, row-major.
    ///
    /// `destination` must hold `pages[index].decodedByteCount` bytes.
    public func readPage(_ index: Int, into destination: UnsafeMutableRawPointer) throws {
        let page = pages[index]
        guard !page.isTiled else { throw DCError("Tiled TIFF pages are not supported (\(url.lastPathComponent))") }
        guard page.samplesPerPixel == 1 else { throw DCError("Only single-sample (grayscale) TIFF pages are supported") }
        guard let type = page.sampleType else {
            throw DCError("Unsupported TIFF sample format: \(page.bitsPerSample)-bit, format \(page.sampleFormat)")
        }
        let bps = type.byteCount
        let rowBytes = page.width * bps
        let total = rowBytes * page.height
        guard page.stripOffsets.count == page.stripByteCounts.count, !page.stripOffsets.isEmpty else {
            throw DCError("TIFF page \(index) has no strip data")
        }

        if page.compression == 1 {
            // Uncompressed: copy strips straight into the destination.
            var written = 0
            for s in 0..<page.stripOffsets.count where written < total {
                let rows = min(page.rowsPerStrip, page.height - s * page.rowsPerStrip)
                let n = min(rows * rowBytes, total - written)
                if n <= 0 { break }
                try file.read(at: page.stripOffsets[s], count: n, into: destination + written)
                written += n
            }
            if written < total { memset(destination + written, 0, total - written) }
        } else {
            var written = 0
            for s in 0..<page.stripOffsets.count where written < total {
                let rows = min(page.rowsPerStrip, page.height - s * page.rowsPerStrip)
                let expected = rows * rowBytes
                let raw = try file.read(at: page.stripOffsets[s], count: Int(page.stripByteCounts[s]))
                var decoded: [UInt8]
                switch page.compression {
                case 5: decoded = try Decompress.lzw(raw, expected: expected)
                case 8, 32946: decoded = try Decompress.zlib(raw, expected: expected)
                case 32773: decoded = try Decompress.packBits(raw, expected: expected)
                default: throw DCError("Unsupported TIFF compression \(page.compression) in \(url.lastPathComponent)")
                }
                let n = min(expected, decoded.count, total - written)
                decoded.withUnsafeBytes { src in
                    (destination + written).copyMemory(from: src.baseAddress!, byteCount: n)
                }
                if n < expected { memset(destination + written + n, 0, min(expected - n, total - written - n)) }
                written += expected
            }
        }

        if bigEndian && bps > 1 { TIFFFile.byteSwap(destination, count: page.width * page.height, width: bps) }

        if page.predictor == 2 {
            TIFFFile.undoHorizontalDifferencing(destination, width: page.width, height: page.height, type: type)
        } else if page.predictor == 3 {
            throw DCError("Floating-point predictor is not supported (\(url.lastPathComponent))")
        }
    }

    /// Read the raw stored bytes of an uncompressed page (used for byte-exact concatenation).
    public func readRawUncompressed(_ index: Int, into destination: UnsafeMutableRawPointer) throws -> Bool {
        let page = pages[index]
        guard page.compression == 1, !page.isTiled, !bigEndian, page.predictor == 1 else { return false }
        try readPage(index, into: destination)
        return true
    }

    static func byteSwap(_ p: UnsafeMutableRawPointer, count: Int, width: Int) {
        if width == 2 {
            let s = p.assumingMemoryBound(to: UInt16.self)
            for i in 0..<count { s[i] = s[i].byteSwapped }
        } else if width == 4 {
            let s = p.assumingMemoryBound(to: UInt32.self)
            for i in 0..<count { s[i] = s[i].byteSwapped }
        }
    }

    static func undoHorizontalDifferencing(_ p: UnsafeMutableRawPointer, width: Int, height: Int, type: SampleType) {
        switch type {
        case .uint8:
            let s = p.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height { let r = y * width; for x in 1..<max(1, width) { s[r + x] = s[r + x] &+ s[r + x - 1] } }
        case .uint16:
            let s = p.assumingMemoryBound(to: UInt16.self)
            for y in 0..<height { let r = y * width; for x in 1..<max(1, width) { s[r + x] = s[r + x] &+ s[r + x - 1] } }
        case .float32:
            break
        }
    }
}
