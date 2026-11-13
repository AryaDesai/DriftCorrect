import Foundation

/// A rotation followed by a shift in the plane. It maps the point (x, y) to (a x + b y + tx, c x + d y + ty).
public struct Rigid: Equatable, Sendable {
    public var a = 1.0, b = 0.0, tx = 0.0
    public var c = 0.0, d = 1.0, ty = 0.0

    public static let identity = Rigid()
    public init() {}

    /// A rotation by `degrees` about the point (cx, cy). A positive angle turns the x axis toward the y axis, which
    /// is clockwise on screen because y points down in an image.
    public static func rotation(degrees: Double, aboutX cx: Double, y cy: Double) -> Rigid {
        let r = degrees * .pi / 180, co = cos(r), si = sin(r)
        var m = Rigid()
        m.a = co; m.b = -si; m.tx = cx - co * cx + si * cy
        m.c = si; m.d = co; m.ty = cy - si * cx - co * cy
        return m
    }

    public static func shift(dx: Double, dy: Double) -> Rigid {
        var m = Rigid()
        m.tx = dx; m.ty = dy
        return m
    }

    /// Return the transform that applies `first` and then this one.
    public func after(_ first: Rigid) -> Rigid {
        var m = Rigid()
        m.a = a * first.a + b * first.c; m.b = a * first.b + b * first.d; m.tx = a * first.tx + b * first.ty + tx
        m.c = c * first.a + d * first.c; m.d = c * first.b + d * first.d; m.ty = c * first.tx + d * first.ty + ty
        return m
    }

    public var inverse: Rigid {
        var m = Rigid()
        m.a = a; m.b = c; m.tx = -(a * tx + c * ty)
        m.c = b; m.d = d; m.ty = -(b * tx + d * ty)
        return m
    }

    @inline(__always) public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        (a * x + b * y + tx, c * x + d * y + ty)
    }

    /// The angle of the rotation in degrees, between -180 and 180.
    public var degrees: Double { atan2(c, a) * 180 / .pi }
}

/// Where the body sits in one timepoint, measured from the embryo mask.
public struct BodyPose: Sendable {
    /// The centroid of the mask in pixels.
    public var x: Double, y: Double
    /// The direction of the long axis of the mask in degrees, between -90 and 90.
    public var angle: Double
    /// The length of the mask along its long axis divided by its length across. A round mask has 1.
    public var elongation: Double
}

/// Holds the body in place over the whole movie.
///
/// Image matching between neighbouring timepoints measures sudden movement well, but the sum of its steps follows
/// the cells. When the cells travel through the body, that sum slowly carries the frame away. The embryo mask
/// says where the body is at every timepoint. It is rough at a single timepoint and reliable over many. The
/// anchor therefore takes the movement between neighbouring timepoints from the image matching, and the position
/// and direction of the body from the mask, averaged over nearby timepoints.
public enum Anchor {
    /// The long axis of a mask is used only when the mask is at least this elongated at every timepoint. The axis
    /// of a nearly round mask has no stable direction.
    static let minimumElongation = 1.5

    /// Measure the centroid and the long axis of a mask. The result is nil when the mask is empty.
    public static func pose(of mask: Mask2D) -> BodyPose? {
        var n = 0.0, sx = 0.0, sy = 0.0
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.bits[y * mask.width + x] { n += 1; sx += Double(x); sy += Double(y) }
        }
        guard n > 0 else { return nil }
        let cx = sx / n, cy = sy / n
        var xx = 0.0, yy = 0.0, xy = 0.0
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.bits[y * mask.width + x] {
                let dx = Double(x) - cx, dy = Double(y) - cy
                xx += dx * dx; yy += dy * dy; xy += dx * dy
            }
        }
        xx /= n; yy /= n; xy /= n
        // The long axis is the direction of largest spread, and the two spreads give the elongation.
        let spread = (((xx - yy) / 2) * ((xx - yy) / 2) + xy * xy).squareRoot()
        let long = (xx + yy) / 2 + spread, short = (xx + yy) / 2 - spread
        return BodyPose(x: cx, y: cy, angle: 0.5 * atan2(2 * xy, xx - yy) * 180 / .pi,
                        elongation: short > 0 ? (long / short).squareRoot() : .infinity)
    }

    /// Average `v` over nearby timepoints with a Gaussian of width `sigma` timepoints.
    static func smooth(_ v: [Double], sigma: Double) -> [Double] {
        guard sigma > 0, v.count > 1 else { return v }
        let radius = Int((3 * sigma).rounded(.up))
        let weights = (0...radius).map { exp(-0.5 * Double($0 * $0) / (sigma * sigma)) }
        return v.indices.map { t in
            var sum = 0.0, total = 0.0
            for k in max(0, t - radius)...min(v.count - 1, t + radius) { sum += weights[abs(k - t)] * v[k]; total += weights[abs(k - t)] }
            return sum / total
        }
    }

    /// Remove the jumps of a full `period` from a series of angles, so that neighbouring values stay close.
    static func unwrap(_ v: [Double], period: Double) -> [Double] {
        var out = v
        for t in 1..<max(1, v.count) { out[t] -= period * ((out[t] - out[t - 1]) / period).rounded() }
        return out
    }

    /// Return the transform that places every timepoint in the output.
    /// - Parameters:
    ///   - steps: For each timepoint, the transform that moves it onto the timepoint before it. The first one is
    ///     ignored.
    ///   - poses: The pose of the body at each timepoint in its own frame. When it is nil, or a timepoint has no
    ///     pose, the body is not held and the result is the sum of the steps.
    ///   - smoothing: The number of timepoints over which the position and direction of the body are averaged.
    public static func transforms(steps: [Rigid], poses: [BodyPose?]?, smoothing: Double, width: Int, height: Int) -> [Rigid] {
        // Add up the steps. `chain[t]` moves timepoint t onto the first timepoint.
        var chain: [Rigid] = []
        for (t, s) in steps.enumerated() { chain.append(t == 0 ? .identity : chain[t - 1].after(s)) }
        guard let poses = poses, poses.count == steps.count, !poses.contains(where: { $0 == nil }) else { return chain }
        let body = poses.map { $0! }

        // Follow the centroid and the long axis of the body in the movie where the steps are added up, and average
        // both over nearby timepoints.
        let turned = unwrap(chain.map { $0.degrees }, period: 360)
        let centres = zip(chain, body).map { $0.apply(x: $1.x, y: $1.y) }
        let cx = smooth(centres.map { $0.x }, sigma: smoothing), cy = smooth(centres.map { $0.y }, sigma: smoothing)
        var turnBack: [Double]
        if body.allSatisfy({ $0.elongation >= minimumElongation }) {
            // Turn the long axis back to its direction at the first timepoint.
            let axis = unwrap(zip(body, turned).map { $0.angle + $1 }, period: 180)
            turnBack = smooth(axis, sigma: smoothing).map { axis[0] - $0 }
        } else {
            // Without a usable long axis, remove only the sudden turns and leave the slow turning as it is.
            turnBack = smooth(turned, sigma: smoothing).map { -$0 }
        }
        // Turn each timepoint about the averaged centroid and then move that centroid to the middle of the frame.
        let midX = Double(width - 1) / 2, midY = Double(height - 1) / 2
        return chain.indices.map { t in
            Rigid.shift(dx: midX - cx[t], dy: midY - cy[t])
                .after(Rigid.rotation(degrees: turnBack[t], aboutX: cx[t], y: cy[t]))
                .after(chain[t])
        }
    }
}
