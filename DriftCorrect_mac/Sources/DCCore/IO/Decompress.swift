import Foundation
#if canImport(Compression)
import Compression
#endif

enum Decompress {
    /// Inflate zlib (RFC 1950) or raw DEFLATE data. `expected` is a size hint.
    static func zlib(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        #if canImport(Compression)
        var start = 0
        // Skip a zlib header (CMF/FLG) when present. Apple's COMPRESSION_ZLIB is raw DEFLATE.
        if input.count >= 2 {
            let cmf = input[0], flg = input[1]
            if cmf & 0x0F == 8 && (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 {
                start = 2
                if flg & 0x20 != 0 { start += 4 }  // preset dictionary id (not used by TIFF/ND2)
            }
        }
        if input.count <= start { return [] }
        var output = [UInt8]()
        output.reserveCapacity(max(expected, 1024))
        let chunk = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw DCError("zlib: cannot initialize decoder")
        }
        defer { compression_stream_destroy(stream) }
        try input.withUnsafeBufferPointer { src in
            stream.pointee.src_ptr = src.baseAddress! + start
            stream.pointee.src_size = src.count - start
            while true {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 { output.append(contentsOf: UnsafeBufferPointer(start: dst, count: produced)) }
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { throw DCError("zlib: corrupt compressed data") }
                if produced == 0 && stream.pointee.src_size == 0 { break }
            }
        }
        return output
        #else
        throw DCError("zlib decompression is not available on this platform")
        #endif
    }

    /// TIFF LZW (compression = 5), MSB-first codes with early change.
    static func lzw(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(expected)
        // Dictionary as (prefix code, last byte, length); strings rebuilt on demand.
        var prefix = [Int32](repeating: -1, count: 4096)
        var suffix = [UInt8](repeating: 0, count: 4096)
        var length = [Int32](repeating: 0, count: 4096)
        for i in 0..<256 { suffix[i] = UInt8(i); length[i] = 1 }
        var next = 258
        var width = 9
        var bitPos = 0
        let totalBits = input.count * 8
        var old: Int = -1
        var scratch = [UInt8](repeating: 0, count: 4096)

        func readCode() -> Int? {
            if bitPos + width > totalBits { return nil }
            var code = 0
            for _ in 0..<width {
                let byte = input[bitPos >> 3]
                let bit = (byte >> (7 - UInt8(bitPos & 7))) & 1
                code = code << 1 | Int(bit)
                bitPos += 1
            }
            return code
        }

        func emit(_ code: Int) -> UInt8 {
            // Write the string for `code`; return its first byte.
            let n = Int(length[code])
            var c = code
            var i = n - 1
            while i >= 0 {
                scratch[i] = suffix[c]
                c = Int(prefix[c])
                i -= 1
            }
            out.append(contentsOf: scratch[0..<n])
            return scratch[0]
        }

        while let code = readCode() {
            if code == 257 { break }  // EOI
            if code == 256 {          // Clear
                next = 258; width = 9; old = -1
                continue
            }
            if old < 0 {
                if code > 255 { throw DCError("LZW: invalid first code") }
                _ = emit(code)
                old = code
            } else {
                var first: UInt8
                if code < next {
                    first = emit(code)
                } else if code == next {
                    // KwKwK case: string(old) + first(old)
                    let n = Int(length[old])
                    var c = old
                    var i = n - 1
                    while i >= 0 { scratch[i] = suffix[c]; c = Int(prefix[c]); i -= 1 }
                    first = scratch[0]
                    scratch[n] = first
                    out.append(contentsOf: scratch[0...n])
                } else {
                    throw DCError("LZW: invalid code \(code)")
                }
                if next < 4096 {
                    prefix[next] = Int32(old)
                    suffix[next] = first
                    length[next] = length[old] + 1
                    next += 1
                }
                old = code
            }
            // Early change: widen one code before the table fills the current width.
            if next + 1 >= (1 << width) && width < 12 { width += 1 }
        }
        return out
    }

    /// PackBits (compression = 32773).
    static func packBits(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(expected)
        var i = 0
        while i < input.count && out.count < expected {
            let n = Int(Int8(bitPattern: input[i]))
            i += 1
            if n >= 0 {
                let count = n + 1
                guard i + count <= input.count else { throw DCError("PackBits: truncated literal run") }
                out.append(contentsOf: input[i..<i + count])
                i += count
            } else if n != -128 {
                guard i < input.count else { throw DCError("PackBits: truncated repeat run") }
                out.append(contentsOf: repeatElement(input[i], count: 1 - n))
                i += 1
            }
        }
        return out
    }
}
