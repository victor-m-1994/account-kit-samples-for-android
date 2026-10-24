import Foundation

/// One elevation sample on the floor, in meters. `x`/`y` lie in the floor plane, `z` is height (up is positive).
public struct SurveyPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Bins raw depth samples into small floor cells and averages them. Averaging hundreds of
/// noisy LiDAR returns per cell is what makes millimeter-scale relief visible at all.
public struct PointAccumulator: Sendable {
    private struct Key: Hashable, Sendable {
        let i: Int32
        let j: Int32
    }

    private struct Bin: Sendable {
        var sum = 0.0
        var sumOfSquares = 0.0
        var count = 0

        mutating func add(_ z: Double) {
            sum += z
            sumOfSquares += z * z
            count += 1
        }
    }

    public let binSize: Double
    private var bins: [Key: Bin] = [:]
    public private(set) var sampleCount = 0

    public init(binSize: Double) {
        precondition(binSize > 0)
        self.binSize = binSize
    }

    public var binCount: Int { bins.count }
    public var coveredArea: Double { Double(bins.count) * binSize * binSize }

    public mutating func add(x: Double, y: Double, z: Double) {
        let key = Key(i: Int32((x / binSize).rounded(.down)), j: Int32((y / binSize).rounded(.down)))
        bins[key, default: Bin()].add(z)
        sampleCount += 1
    }

    public mutating func reset() {
        bins.removeAll()
        sampleCount = 0
    }

    /// Mean height per bin. Bins with too few samples, or with a spread that points to an
    /// object edge rather than floor, are dropped.
    public func points(minSamples: Int = 3, maxStandardDeviation: Double = 0.015) -> [SurveyPoint] {
        bins.compactMap { key, bin in
            guard bin.count >= minSamples else { return nil }
            let n = Double(bin.count)
            let mean = bin.sum / n
            let variance = max(0, bin.sumOfSquares / n - mean * mean)
            guard variance.squareRoot() <= maxStandardDeviation else { return nil }
            return SurveyPoint(x: (Double(key.i) + 0.5) * binSize, y: (Double(key.j) + 0.5) * binSize, z: mean)
        }
    }
}

public enum PointCloudAlignment {
    /// Rotates points about the vertical axis so the floor's footprint lines up with the map
    /// axes (walls come out horizontal/vertical), then shifts the corner to 0,0.
    public static func alignedToAxes(_ points: [SurveyPoint]) -> [SurveyPoint] {
        guard points.count >= 3 else { return translatedToOrigin(points) }
        let step = max(1, points.count / 3000)
        let sample = stride(from: 0, to: points.count, by: step).map { points[$0] }

        var bestAngle = 0.0
        var bestArea = Double.infinity
        var xs = [Double](repeating: 0, count: sample.count)
        var ys = [Double](repeating: 0, count: sample.count)
        for halfDegree in 0..<180 {
            let angle = Double(halfDegree) * 0.5 * .pi / 180
            let (c, s) = (cos(angle), sin(angle))
            for (k, p) in sample.enumerated() {
                xs[k] = p.x * c - p.y * s
                ys[k] = p.x * s + p.y * c
            }
            let area = robustExtent(&xs) * robustExtent(&ys)
            if area < bestArea {
                bestArea = area
                bestAngle = angle
            }
        }

        let (c, s) = (cos(bestAngle), sin(bestAngle))
        let rotated = points.map { SurveyPoint(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c, z: $0.z) }
        return translatedToOrigin(rotated)
    }

    /// Width of the middle 99% of values, so a few stray points don't define the room.
    private static func robustExtent(_ values: inout [Double]) -> Double {
        values.sort()
        let last = Double(values.count - 1)
        return values[Int(last * 0.995)] - values[Int(last * 0.005)]
    }

    static func translatedToOrigin(_ points: [SurveyPoint]) -> [SurveyPoint] {
        guard let minX = points.map(\.x).min(), let minY = points.map(\.y).min() else { return points }
        return points.map { SurveyPoint(x: $0.x - minX, y: $0.y - minY, z: $0.z) }
    }
}
