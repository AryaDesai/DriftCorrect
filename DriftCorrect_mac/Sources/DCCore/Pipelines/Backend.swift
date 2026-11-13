import Foundation

/// The heavy operations that run on every frame. `CPUBackend` is the exact reference, and `MetalBackend` in
/// DCApple runs the same operations on the GPU.
///
/// Implementations must be safe to call from several threads at once.
public protocol ComputeBackend: AnyObject {
    var name: String { get }

    /// Blur a float32 image as `scipy.ndimage.gaussian_filter(image, sigma)` does.
    func gaussian(_ image: Image2D, sigma: Double) throws -> Image2D

    /// Return the maximum over Z of one channel of a (C, Z, Y, X) frame as float32.
    func maxProjectZ(_ frame: Volume, channel: Int) throws -> Image2D

    /// Return the maximum over Z of every channel.
    func maxProjectAll(_ frame: Volume) throws -> [Image2D]

    /// Shift every plane onto the canvas of the frame plus `pad` and convert the result to uint16. The shift is
    /// `scipy.ndimage.shift(order=1, mode="constant")` or a shift by whole pixels, followed by
    /// `clip(0, 65535).astype(np.uint16)`.
    func shift(_ frame: Volume, pad: Padding, dy: Double, dx: Double, mode: ShiftMode) throws -> Volume
}

public final class CPUBackend: ComputeBackend {
    public init() {}
    public var name: String { "CPU" }

    public func gaussian(_ image: Image2D, sigma: Double) throws -> Image2D {
        Gaussian.filter(image, sigma: sigma)
    }

    public func maxProjectZ(_ frame: Volume, channel: Int) throws -> Image2D {
        Image2D(width: frame.x, height: frame.y, pixels: frame.maxProjectZ(channel: channel))
    }

    public func maxProjectAll(_ frame: Volume) throws -> [Image2D] {
        var out = [Image2D?](repeating: nil, count: frame.c)
        let lock = NSLock()
        Parallel.forEach(frame.c) { c in
            let img = Image2D(width: frame.x, height: frame.y, pixels: frame.maxProjectZ(channel: c))
            lock.lock(); out[c] = img; lock.unlock()
        }
        return out.map { $0! }
    }

    public func shift(_ frame: Volume, pad: Padding, dy: Double, dx: Double, mode: ShiftMode) throws -> Volume {
        Shift.apply(frame, pad: pad, dy: dy, dx: dx, mode: mode)
    }
}

/// The detection of the xy centroid, which the Mask tool and the alignment share.
public enum Detection {
    public struct Result {
        public var dy: Double
        public var dx: Double
        public var centroid: (y: Double, x: Double)
        /// The mask that the centroid came from. Z correction can follow this mask.
        public var mask: Mask2D?
    }

    /// Find the mask and the shift as `compute_shift_xy` does in the Python scripts, with the same settings.
    public static func computeShift(frame: Volume, params: ThresholdParams, backend: ComputeBackend) throws -> Result {
        guard params.channelIndex >= 0 && params.channelIndex < frame.c else {
            throw DCError("Threshold channel index \(params.channelIndex) is out of range (the data has \(frame.c) channel(s))")
        }
        let projection = try backend.maxProjectZ(frame, channel: params.channelIndex)
        let smoothed = try backend.gaussian(projection, sigma: params.sigma)
        let r = try Masking.findLargestMask(smoothed, percentile: params.percentile, method: params.method,
                                            blockSize: params.blockSize, invert: params.invert,
                                            levels: params.levels, selectedLevels: params.selectedLevels)
        let (dy, dx) = Masking.shift(toCenter: r.centroid, height: frame.y, width: frame.x)
        return Result(dy: dy, dx: dx, centroid: r.centroid, mask: r.mask)
    }
}

/// The output of a grayscale movie. `DCApple.HEVCMovieWriter` implements it with VideoToolbox.
public protocol MovieWriter: AnyObject {
    /// Append one uint8 gray frame of `width * height` pixels, stored row by row.
    func append(gray: [UInt8]) throws
    /// Finish the file and move it to its final path.
    func finish() throws
    /// Stop and delete the partial file.
    func cancel()
}

public protocol MovieWriterFactory {
    func makeWriter(url: URL, width: Int, height: Int, fps: Double) throws -> MovieWriter
}

/// The channel movies of one output stack. The gray frames are made with `auto_contrast` of the maximum
/// projection along z, as `tiff_to_mp4` does.
public final class ChannelMovies {
    private var writers: [MovieWriter]
    public let urls: [URL]

    public init(factory: MovieWriterFactory, urls: [URL], width: Int, height: Int, fps: Double) throws {
        guard fps.isFinite && fps > 0 else { throw DCError("FPS must be a finite positive number") }
        var ws: [MovieWriter] = []
        for u in urls {
            do { ws.append(try factory.makeWriter(url: u, width: width, height: height, fps: fps)) }
            catch { ws.forEach { $0.cancel() }; throw error }
        }
        self.writers = ws
        self.urls = urls
    }

    /// Return the frame of every channel from the projection of that channel.
    public static func grayFrames(_ projections: [Image2D]) -> [[UInt8]] {
        var out = [[UInt8]](repeating: [], count: projections.count)
        let lock = NSLock()
        Parallel.forEach(projections.count) { c in
            let g = Contrast.autoContrast(projections[c].pixels)
            lock.lock(); out[c] = g; lock.unlock()
        }
        return out
    }

    public func append(_ frames: [[UInt8]]) throws {
        for (w, f) in zip(writers, frames) { try w.append(gray: f) }
    }

    public func finish() throws { for w in writers { try w.finish() } }
    public func cancel() { writers.forEach { $0.cancel() } }
}
