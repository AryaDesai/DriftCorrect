import Foundation

/// The accuracy check measures how well the xy and z matching recover a known move on a real movie.
///
/// A real movie has no known answer, so the check adds one. It moves a timepoint by a known shift, turn and z
/// offset and matches the moved copy. The difference between the move that the matching finds and the move that
/// was applied is the error. Nothing is written to disk.
///
/// The check has two parts.
/// - The first part matches a timepoint with a moved copy of itself. The tissue does not change, so this is the
///   error of the matching alone.
/// - The second part matches a timepoint with the next one, and then with a moved copy of the next one. The two
///   answers must differ by exactly the known move. The tissue changes between the two timepoints as it does in a
///   real run. This error holds the errors of both matches.
public enum AccuracyCheck {
    public struct Options {
        /// This is the OME-TIFF or ND2 movie to measure on.
        public var source: URL
        /// This is the channel to match, given by index or by name. When both are nil, the first channel is used.
        public var channelIndex: Int?
        public var channelName: String?
        /// This many timepoints, spread evenly over the movie, are tested.
        public var pairs = 12
        /// The matching looks for turns up to this many degrees, as in a run of the alignment.
        public var maximumAngle = 3.0
        public init(source: URL) { self.source = source }
    }

    /// The known moves stay within this shift in pixels, this turn in degrees and this z offset in slices. These
    /// cover the usual movement between two timepoints without the jump of a stage that was centred again.
    static let largestShift = 20.0, largestTurn = 2.0, largestOffset = 2.0

    /// This is a known move. `xy` moves the image, and `dz` moves the tissue toward a higher slice index.
    struct Move {
        var xy: Rigid
        var dz: Double
    }

    /// This is the error of one match. In xy it is the distance between where the found move and the true move put
    /// a point of the frame.
    struct Miss {
        /// This is the error at the frame centre in pixels, which is the error of the shift.
        var centre: Double
        /// This is the largest error at the four corners in pixels. An error of the angle shows here, because a
        /// turn moves the corners most.
        var corner: Double
        /// This is the error of the angle in degrees.
        var angle: Double
        /// This is the error in z in slices.
        var z: Double
    }

    /// Run the check and write the mean and the largest error of each part to the log.
    public static func run(options o: Options, backend: ComputeBackend, context ctx: RunContext) throws {
        // Open the movie and find the channel to match. The check uses the first embryo of an ND2 file.
        let src = try ZPass.open(o.source)
        let names = Array(src.metadata.channelNames.prefix(src.c))
        let channel = try resolveChannel(index: o.channelIndex, name: o.channelName, names: names, count: src.c,
                                         fallback: 0, label: "Accuracy")
        guard src.t >= 2 else { throw DCError("The accuracy check needs a movie with at least 2 timepoints") }
        ctx.log("Accuracy check on \(o.source.lastPathComponent), channel \(channel < names.count ? names[channel] : "ch\(channel)")")
        ctx.log("  Shape: T=\(src.t), Z=\(src.z), Y=\(src.y), X=\(src.x)")
        let W = src.x, H = src.y
        let midX = Double(W - 1) / 2, midY = Double(H - 1) / 2

        // The known moves come from a fixed sequence of random numbers, so that two runs test the same moves and
        // their results can be compared.
        var state: UInt64 = 0x9E3779B97F4A7C15
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
        func randomMove() -> Move {
            let turn = o.maximumAngle > 0 ? random() * min(largestTurn, o.maximumAngle) : 0
            let shift = Rigid.shift(dx: random() * largestShift, dy: random() * largestShift)
            return Move(xy: shift.after(Rigid.rotation(degrees: turn, aboutX: midX, y: midY)), dz: random() * largestOffset)
        }

        // Read one channel of a timepoint as a stack of its own, which is all that the matching uses.
        func stack(_ t: Int) throws -> Volume {
            let frame = try src.readFrame(t: t, p: 0)
            let out = Volume(c: 1, z: frame.z, y: frame.y, x: frame.x, type: frame.type)
            for z in 0..<frame.z {
                out.planePointer(c: 0, z: z).copyMemory(from: frame.planePointer(c: channel, z: z), byteCount: frame.planeBytes)
            }
            return out
        }
        func prepared(_ v: Volume) throws -> XYFrame { XYMatch.prepare(try backend.maxProjectZ(v, channel: 0)) }
        // Match `b` onto `a` in xy and then in z, as a run of the alignment does.
        func measure(_ a: Volume, _ b: Volume) throws -> (step: Rigid, dz: Double) {
            let step = XYMatch.match(try prepared(a), try prepared(b), maximumAngle: o.maximumAngle).step
            let dz = ZDrift.match(ZDrift.describe(frame: a, channel: 0), ZDrift.describe(frame: b, channel: 0, transform: step)).dz
            return (step, dz)
        }
        // Compare a found move with the move that it should be.
        func miss(found: (step: Rigid, dz: Double), expected: (step: Rigid, dz: Double)) -> Miss {
            let error = found.step.after(expected.step.inverse)
            func distance(_ x: Double, _ y: Double) -> Double { let p = error.apply(x: x, y: y); return hypot(p.x - x, p.y - y) }
            let corners = [(0.0, 0.0), (Double(W - 1), 0.0), (0.0, Double(H - 1)), (Double(W - 1), Double(H - 1))]
            return Miss(centre: distance(midX, midY), corner: corners.map { distance($0.0, $0.1) }.max()!,
                        angle: abs(error.degrees), z: abs(found.dz - expected.dz))
        }
        // Write the mean and the largest error of one part to the log.
        func report(_ title: String, _ misses: [Miss]) {
            func line(_ label: String, _ v: [Double]) -> String {
                String(format: "    %@ mean %.3f   largest %.3f", label.padding(toLength: 26, withPad: " ", startingAt: 0),
                       v.reduce(0, +) / Double(max(1, v.count)), v.max() ?? 0)
            }
            ctx.log("\n  \(title) (\(misses.count) matches)")
            ctx.log(line("shift at the centre (px)", misses.map { $0.centre }))
            ctx.log(line("largest at a corner (px)", misses.map { $0.corner }))
            ctx.log(line("angle (degrees)", misses.map { $0.angle }))
            ctx.log(line("z (slices)", misses.map { $0.z }))
        }

        // Both parts use timepoints spread evenly over the movie.
        let count = min(o.pairs, src.t - 1)
        var same: [Miss] = [], next: [Miss] = []
        for k in 0..<count {
            try ctx.checkCancelled()
            let t = count > 1 ? k * (src.t - 2) / (count - 1) : 0
            let a = try stack(t), b = try stack(t + 1)
            // A moved copy of the timepoint itself must be moved back by exactly the opposite move.
            var move = randomMove()
            same.append(miss(found: try measure(a, moved(a, by: move)), expected: (move.xy.inverse, move.dz)))
            // A moved copy of the next timepoint must give the answer of the next timepoint, with the move undone first.
            move = randomMove()
            let plain = try measure(a, b)
            next.append(miss(found: try measure(a, moved(b, by: move)), expected: (plain.step.after(move.xy.inverse), plain.dz + move.dz)))
            ctx.progress("Accuracy", k + 1, count)
        }
        report("Same timepoint, moved by a known amount", same)
        report("Next timepoint, moved by a known amount", next)
    }

    /// Return a copy of a stack that is moved in xy and then along z. A move along z by a part of a slice is
    /// interpolated between the two nearest slices. A slice that no data reaches stays empty.
    static func moved(_ v: Volume, by move: Move) -> Volume {
        let inPlane = Shift.warp(v, pad: .none, transform: move.xy)
        if move.dz == 0 { return inPlane }
        let out = Volume(c: 1, z: v.z, y: v.y, x: v.x, type: .uint16, zeroed: true)
        let n = v.planeElements
        Parallel.forEach(v.z) { z in
            // The tissue moved up by dz, so output slice z shows the source at z - dz.
            let position = Double(z) - move.dz
            let lower = Int(position.rounded(.down)), part = Float(position - position.rounded(.down))
            guard lower >= 0, lower + (part > 0 ? 1 : 0) < v.z else { return }
            let a = inPlane.planePointer(c: 0, z: lower).assumingMemoryBound(to: UInt16.self)
            let b = inPlane.planePointer(c: 0, z: min(v.z - 1, lower + 1)).assumingMemoryBound(to: UInt16.self)
            let dst = out.planePointer(c: 0, z: z).assumingMemoryBound(to: UInt16.self)
            for i in 0..<n { dst[i] = UInt16((Float(a[i]) * (1 - part) + Float(b[i]) * part).rounded()) }
        }
        return out
    }
}
