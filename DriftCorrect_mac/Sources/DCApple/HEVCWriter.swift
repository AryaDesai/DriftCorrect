#if canImport(VideoToolbox) && canImport(AVFoundation)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import DCCore

/// HEVC movie writer on the Apple media engine (replaces the bundled FFmpeg).
///
/// Matches `ffmpeg_runtime.encode_rgb_mp4` with the VideoToolbox encoder:
/// quality 0.65 (`-q:v 65`), 4:2:0, `hvc1` tag, fast start, and frames padded
/// with black to even width and height. The file is written under a temporary
/// name and moved into place only after a successful finish.
public final class HEVCMovieWriter: MovieWriter {
    public let url: URL
    let width: Int, height: Int
    let encodedWidth: Int, encodedHeight: Int
    let fps: Double
    private let tempURL: URL
    private var session: VTCompressionSession?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var pending: [CMSampleBuffer] = []
    private let lock = NSLock()
    private var encodeError: OSStatus = noErr
    private var frameIndex: Int64 = 0
    private var finished = false

    public init(url: URL, width: Int, height: Int, fps: Double, quality: Double = 0.65) throws {
        guard fps.isFinite && fps > 0 else { throw DCError("FPS must be a finite positive number") }
        self.url = url
        self.width = width
        self.height = height
        self.encodedWidth = (width + 1) / 2 * 2
        self.encodedHeight = (height + 1) / 2 * 2
        self.fps = fps
        tempURL = url.deletingLastPathComponent().appendingPathComponent(".encoding-\(UUID().uuidString).mp4")

        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: encodedWidth,
            kCVPixelBufferHeightKey: encodedHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(encodedWidth), height: Int32(encodedHeight),
                                                codecType: kCMVideoCodecType_HEVC,
                                                encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: attrs as CFDictionary,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &s)
        guard status == noErr, let session = s else { throw DCError("No working HEVC encoder (VideoToolbox status \(status))") }
        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: NSNumber(value: quality))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        if !finished { cancel() }
    }

    private func time(_ i: Int64) -> CMTime {
        let hundredths = fps * 100
        if abs(hundredths - hundredths.rounded()) < 1e-9 && hundredths.rounded() <= Double(Int32.max) {
            return CMTime(value: i * 100, timescale: Int32(hundredths.rounded()))
        }
        return CMTime(seconds: Double(i) / fps, preferredTimescale: 1_000_000)
    }

    public func append(gray: [UInt8]) throws {
        guard let session = session else { throw DCError("Movie writer is closed") }
        guard gray.count == width * height else { throw DCError("Movie frame has the wrong size") }
        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else { throw DCError("No pixel buffer pool") }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else {
            throw DCError("Cannot allocate a video frame")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        gray.withUnsafeBufferPointer { g in
            // Limited-range luma of gray RGB: Y = 16 + (220 * v + 128) >> 8 (black padding: Y = 16).
            for y in 0..<encodedHeight {
                let row = yBase + y * yStride
                if y < height {
                    let src = g.baseAddress! + y * width
                    for x in 0..<width { row[x] = UInt8(16 + ((220 * Int(src[x]) + 128) >> 8)) }
                    if encodedWidth > width { row[width] = 16 }
                } else {
                    memset(row, 16, encodedWidth)
                }
            }
            for y in 0..<(encodedHeight / 2) { memset(cBase + y * cStride, 128, encodedWidth) }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        let pts = time(frameIndex)
        let duration = CMTimeSubtract(time(frameIndex + 1), pts)
        frameIndex += 1
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts,
                                                     duration: duration, frameProperties: nil, infoFlagsOut: nil) {
            [weak self] status, _, sample in
            guard let self = self else { return }
            self.lock.lock()
            if status != noErr { self.encodeError = status }
            if let sample = sample { self.pending.append(sample) }
            self.lock.unlock()
        }
        guard status == noErr else { throw DCError("HEVC encode failed (status \(status))") }
        try drain(waitForAll: false)
    }

    /// Move encoded samples into the MP4 file.
    private func drain(waitForAll: Bool) throws {
        lock.lock()
        let samples = pending
        pending.removeAll()
        let err = encodeError
        lock.unlock()
        if err != noErr { throw DCError("HEVC encode failed (status \(err))") }
        for sample in samples {
            if writer == nil { try startWriter(format: CMSampleBufferGetFormatDescription(sample)) }
            guard let input = input, let writer = writer else { continue }
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw DCError("MP4 writer failed: \(writer.error?.localizedDescription ?? "unknown")") }
                usleep(1000)
            }
            if !input.append(sample) {
                throw DCError("MP4 writer failed: \(writer.error?.localizedDescription ?? "unknown")")
            }
        }
    }

    private func startWriter(format: CMFormatDescription?) throws {
        try? FileManager.default.removeItem(at: tempURL)
        let w = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
        w.shouldOptimizeForNetworkUse = true  // -movflags +faststart
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        i.expectsMediaDataInRealTime = false
        guard w.canAdd(i) else { throw DCError("Cannot add the HEVC track to the MP4 file") }
        w.add(i)
        guard w.startWriting() else { throw DCError("Cannot write \(url.lastPathComponent): \(w.error?.localizedDescription ?? "")") }
        w.startSession(atSourceTime: .zero)
        writer = w
        input = i
    }

    public func finish() throws {
        guard !finished else { return }
        guard let session = session else { return }
        guard frameIndex > 0 else { throw DCError("Cannot encode a movie with no frames") }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        try drain(waitForAll: true)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        guard let writer = writer, let input = input else { throw DCError("The encoder produced no frames") }
        input.markAsFinished()
        writer.endSession(atSourceTime: time(frameIndex))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw DCError("MP4 writer failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
        finished = true
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    public func cancel() {
        if let s = session {
            VTCompressionSessionInvalidate(s)
            session = nil
        }
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: tempURL)
        finished = true
    }
}

public struct HEVCMovieFactory: MovieWriterFactory {
    public init() {}
    public func makeWriter(url: URL, width: Int, height: Int, fps: Double) throws -> MovieWriter {
        try HEVCMovieWriter(url: url, width: width, height: height, fps: fps)
    }
}
#endif
