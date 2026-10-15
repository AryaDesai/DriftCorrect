import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Read-only file with thread-safe positional reads (`pread`).
public final class RandomAccessFile: @unchecked Sendable {
    public let url: URL
    public let size: UInt64
    private let fd: Int32

    public init(url: URL) throws {
        self.url = url
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw DCError("Cannot open \(url.path): \(String(cString: strerror(errno)))") }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw DCError("Cannot stat \(url.path)")
        }
        self.fd = fd
        self.size = UInt64(st.st_size)
        #if canImport(Darwin)
        // Sequential readahead helps the large strip reads.
        _ = fcntl(fd, F_RDAHEAD, 1)
        #endif
    }

    deinit { close(fd) }

    /// Read exactly `count` bytes at `offset` into `buffer`.
    public func read(at offset: UInt64, count: Int, into buffer: UnsafeMutableRawPointer) throws {
        var done = 0
        while done < count {
            let n = pread(fd, buffer + done, count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw DCError("Read error in \(url.lastPathComponent) at \(offset): \(String(cString: strerror(errno)))")
            }
            if n == 0 { throw DCError("Unexpected end of file in \(url.lastPathComponent) at offset \(offset + UInt64(done))") }
            done += n
        }
    }

    public func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        if count > 0 {
            try out.withUnsafeMutableBytes { try read(at: offset, count: count, into: $0.baseAddress!) }
        }
        return out
    }
}

/// Little/big-endian reader over a byte array.
struct ByteReader {
    let bytes: [UInt8]
    let bigEndian: Bool
    var pos: Int = 0

    init(_ bytes: [UInt8], bigEndian: Bool = false) { self.bytes = bytes; self.bigEndian = bigEndian }

    var remaining: Int { bytes.count - pos }

    func u8(at i: Int) -> UInt8 { bytes[i] }

    func u16(at i: Int) -> UInt16 {
        let a = UInt16(bytes[i]), b = UInt16(bytes[i + 1])
        return bigEndian ? (a << 8 | b) : (b << 8 | a)
    }

    func u32(at i: Int) -> UInt32 {
        var v: UInt32 = 0
        if bigEndian { for k in 0..<4 { v = v << 8 | UInt32(bytes[i + k]) } }
        else { for k in (0..<4).reversed() { v = v << 8 | UInt32(bytes[i + k]) } }
        return v
    }

    func u64(at i: Int) -> UInt64 {
        var v: UInt64 = 0
        if bigEndian { for k in 0..<8 { v = v << 8 | UInt64(bytes[i + k]) } }
        else { for k in (0..<8).reversed() { v = v << 8 | UInt64(bytes[i + k]) } }
        return v
    }

    func f64(at i: Int) -> Double { Double(bitPattern: u64(at: i)) }
    func f32(at i: Int) -> Float { Float(bitPattern: u32(at: i)) }

    mutating func readU8() throws -> UInt8 { try need(1); defer { pos += 1 }; return bytes[pos] }
    mutating func readU16() throws -> UInt16 { try need(2); defer { pos += 2 }; return u16(at: pos) }
    mutating func readU32() throws -> UInt32 { try need(4); defer { pos += 4 }; return u32(at: pos) }
    mutating func readI32() throws -> Int32 { Int32(bitPattern: try readU32()) }
    mutating func readU64() throws -> UInt64 { try need(8); defer { pos += 8 }; return u64(at: pos) }
    mutating func readI64() throws -> Int64 { Int64(bitPattern: try readU64()) }
    mutating func readF64() throws -> Double { Double(bitPattern: try readU64()) }

    mutating func readBytes(_ n: Int) throws -> [UInt8] {
        try need(n)
        defer { pos += n }
        return Array(bytes[pos..<pos + n])
    }

    func need(_ n: Int) throws {
        if n < 0 || pos + n > bytes.count { throw DCError("Truncated data (need \(n) bytes at \(pos) of \(bytes.count))") }
    }
}
