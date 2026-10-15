import Foundation

/// Timepoint frames of one file, as (C, Z, Y, X) volumes.
public protocol FrameSource: AnyObject {
    var t: Int { get }
    var positions: Int { get }
    var c: Int { get }
    var z: Int { get }
    var y: Int { get }
    var x: Int { get }
    var sampleType: SampleType { get }
    var metadata: ImageMetadata { get }
    func readFrame(t: Int, p: Int) throws -> Volume
}

extension FrameSource {
    public var frameBytes: Int { c * z * y * x * sampleType.byteCount }
}

public final class TIFFSource: FrameSource {
    public let stack: TIFFStack
    public init(_ stack: TIFFStack) { self.stack = stack }
    public convenience init(url: URL) throws { self.init(try TIFFStack(url: url)) }
    public var t: Int { stack.t }
    public var positions: Int { 1 }
    public var c: Int { stack.c }
    public var z: Int { stack.z }
    public var y: Int { stack.y }
    public var x: Int { stack.x }
    public var sampleType: SampleType { stack.sampleType }
    public var metadata: ImageMetadata {
        // `save_ome_tiff` always writes µm and s units.
        ImageMetadata.standard(channelNames: stack.metadata.channelNames, voxel: stack.metadata.voxel,
                               period: stack.metadata.timeIncrement)
    }
    public func readFrame(t: Int, p: Int) throws -> Volume { try stack.readFrame(t) }
}

public final class ND2Source: FrameSource {
    public let file: ND2File
    public init(_ file: ND2File) { self.file = file }
    public convenience init(url: URL) throws { self.init(try ND2File(url: url)) }
    public var t: Int { file.sizeT }
    public var positions: Int { file.sizeP }
    public var c: Int { file.sizeC }
    public var z: Int { file.sizeZ }
    public var y: Int { file.sizeY }
    public var x: Int { file.sizeX }
    public var sampleType: SampleType { file.sampleType }
    public var metadata: ImageMetadata { file.metadata }
    public func readFrame(t: Int, p: Int) throws -> Volume { try file.readFrame(t: t, p: p) }
}

/// Keeps frames read in Pass 1 for Pass 2 when they fit in memory.
final class FrameCache {
    private var frames: [Int: Volume] = [:]
    private let lock = NSLock()
    let enabled: Bool

    init(enabled: Bool) { self.enabled = enabled }

    func put(_ key: Int, _ v: Volume) {
        guard enabled else { return }
        lock.lock(); frames[key] = v; lock.unlock()
    }

    func take(_ key: Int) -> Volume? {
        guard enabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        return frames.removeValue(forKey: key)
    }

    /// Cache when the whole data set uses at most 40% of physical memory.
    static func fits(bytes: Int) -> Bool {
        Double(bytes) <= 0.4 * Double(ProcessInfo.processInfo.physicalMemory)
    }
}

/// Number of frames to keep in flight for a given frame size (bounded to about 2 GB).
func pipelineWidth(frameBytes: Int) -> Int {
    let budget = 2 << 30
    let byMemory = max(1, budget / max(1, frameBytes))
    return max(2, min(Parallel.workerCount, 8, byMemory))
}
