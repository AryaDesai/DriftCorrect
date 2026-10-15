import Foundation

/// Number and path formatting that matches the Python scripts' output.
public enum PyFormat {
    /// Python `repr(float)`: shortest round-trip digits, `.0` for integral values.
    public static func repr(_ v: Double) -> String {
        if v.isNaN { return "nan" }
        if v.isInfinite { return v > 0 ? "inf" : "-inf" }
        return "\(v)"  // Swift uses the same shortest round-trip algorithm and exponent style.
    }

    /// C/Python printf-style formatting, e.g. `fmt("%+7.2f", dy)`.
    public static func fmt(_ format: String, _ args: CVarArg...) -> String {
        String(format: format, locale: Locale(identifier: "en_US_POSIX"), arguments: args)
    }

    /// Python `f"{x:.6g}"`.
    public static func g6(_ v: Double) -> String { fmt("%.6g", v) }

    /// Python `f"{x:g}"`.
    public static func g(_ v: Double) -> String { fmt("%g", v) }

    /// Python `str()` of a float percentile value such as `90.0` or `92.5`.
    public static func str(_ v: Double) -> String { repr(v) }

    /// `Path(p).stem` with a trailing `.ome` removed, as the scripts do for output names.
    public static func stemWithoutOME(_ url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        if stem.hasSuffix(".ome") { stem = String(stem.dropLast(4)) }
        return stem
    }

    /// Python `Path(p).stem` (removes only the last suffix).
    public static func stem(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Python `round(x, n)` (round half to even at the decimal digit, via repr).
    public static func round(_ x: Double, _ n: Int) -> Double {
        // Python rounds the exact binary value correctly; formatting with %.nf
        // uses the same correctly rounded decimal conversion.
        let s = fmt("%.\(n)f", x)
        return Double(s) ?? x
    }
}

/// Sort URLs the way Python sorts `Path` objects from one directory glob.
public func pySortedByName(_ urls: [URL]) -> [URL] {
    urls.sorted { a, b in
        let sa = Array(a.path.unicodeScalars).map { $0.value }
        let sb = Array(b.path.unicodeScalars).map { $0.value }
        return sa.lexicographicallyPrecedes(sb)
    }
}

/// Files in `dir` whose names match a simple glob (`*` wildcard only).
public func globFiles(_ dir: URL, pattern: String) -> [URL] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
    let matches = names.filter { wildcardMatch($0, pattern) }
    return pySortedByName(matches.map { dir.appendingPathComponent($0) }).filter {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && !isDir.boolValue
    }
}

/// `fnmatch`-style match for patterns that only use `*`. Case-sensitive (macOS glob in Python is case-sensitive).
public func wildcardMatch(_ name: String, _ pattern: String) -> Bool {
    let n = Array(name.unicodeScalars)
    let p = Array(pattern.unicodeScalars)
    var i = 0, j = 0, star = -1, mark = 0
    while i < n.count {
        if j < p.count && p[j] != "*" && p[j] == n[i] {
            i += 1; j += 1
        } else if j < p.count && p[j] == "*" {
            star = j; mark = i; j += 1
        } else if star >= 0 {
            j = star + 1; mark += 1; i = mark
        } else {
            return false
        }
    }
    while j < p.count && p[j] == "*" { j += 1 }
    return j == p.count
}
