import Foundation

/// A flatness requirement: no gap under a straightedge of length `span` may exceed `tolerance`.
public struct FlatnessSpec: Codable, Hashable, Sendable {
    public var name: String
    public var tolerance: Double
    public var span: Double

    public init(name: String, tolerance: Double, span: Double) {
        self.name = name
        self.tolerance = tolerance
        self.span = span
    }

    /// The most common LVP / rigid-core requirement.
    public static let threeSixteenthsPerTenFeet = FlatnessSpec(
        name: "3/16\" in 10'", tolerance: Length.inches(3.0 / 16.0), span: Length.feet(10))
    public static let oneEighthPerSixFeet = FlatnessSpec(
        name: "1/8\" in 6'", tolerance: Length.inches(1.0 / 8.0), span: Length.feet(6))
    public static let quarterPerTenFeet = FlatnessSpec(
        name: "1/4\" in 10'", tolerance: Length.inches(1.0 / 4.0), span: Length.feet(10))
    public static let fourMillimetersPerTwoMeters = FlatnessSpec(
        name: "4 mm in 2 m", tolerance: 0.004, span: 2.0)

    public static let presets: [FlatnessSpec] = [
        .threeSixteenthsPerTenFeet, .oneEighthPerSixFeet, .quarterPerTenFeet, .fourMillimetersPerTwoMeters,
    ]
}

/// What deviations are measured against.
public enum ReferencePlane: String, Codable, CaseIterable, Sendable {
    /// The plane that best fits the floor. LVP needs flat, not level, so this is the default.
    case bestFit
    /// A horizontal plane. Use when the floor also has to be level.
    case level
}

public struct Plane: Codable, Hashable, Sendable {
    /// z = a·x + b·y + c
    public var a: Double
    public var b: Double
    public var c: Double

    public init(a: Double, b: Double, c: Double) {
        self.a = a
        self.b = b
        self.c = c
    }

    public func z(atX x: Double, y: Double) -> Double { a * x + b * y + c }

    /// Rise over run of the steepest direction.
    public var slope: Double { (a * a + b * b).squareRoot() }

    public static func leastSquares(_ samples: [SurveyPoint]) -> Plane {
        guard !samples.isEmpty else { return Plane(a: 0, b: 0, c: 0) }
        let n = Double(samples.count)
        let mx = samples.reduce(0) { $0 + $1.x } / n
        let my = samples.reduce(0) { $0 + $1.y } / n
        let mz = samples.reduce(0) { $0 + $1.z } / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0, sxz = 0.0, syz = 0.0
        for p in samples {
            let dx = p.x - mx, dy = p.y - my, dz = p.z - mz
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
            sxz += dx * dz
            syz += dy * dz
        }
        let determinant = sxx * syy - sxy * sxy
        var a = 0.0, b = 0.0
        if determinant > 1e-12 * max(1, sxx * syy) {
            a = (sxz * syy - syz * sxy) / determinant
            b = (syz * sxx - sxz * sxy) / determinant
        } else if sxx > 1e-12 {
            a = sxz / sxx // all samples on one line along x
        } else if syy > 1e-12 {
            b = syz / syy
        }
        return Plane(a: a, b: b, c: mz - a * mx - b * my)
    }
}

public enum CellCondition: UInt8, Sendable {
    case noData
    /// Within spec.
    case ok
    /// A high spot the straightedge rocks on: grind it down.
    case grind
    /// A low spot that still fails after grinding: fill it.
    case fill
    /// Fails today, but only because it sits in the shadow of a high spot that's being ground.
    case clearsAfterGrind
}

public struct Hotspot: Identifiable, Sendable {
    public enum Kind: Sendable {
        case high
        case low
    }

    public let kind: Kind
    public let rank: Int
    /// Position of the worst cell, in meters from the map origin.
    public let x: Double
    public let y: Double
    public let area: Double
    /// Height above the reference plane for highs, depth under the straightedge for lows. Always positive.
    public let magnitude: Double
    public let cells: [Int]

    public var id: String { label }
    public var label: String { (kind == .high ? "H" : "L") + "\(rank)" }
}

public struct FlatnessReport: Sendable {
    public let grid: ElevationGrid
    public let spec: FlatnessSpec
    public let reference: ReferencePlane
    public let plane: Plane
    /// Height relative to the reference plane, per cell.
    public let deviation: [Double?]
    /// Largest gap found under a straightedge laid across each cell, floor as-is.
    public let straightedgeGap: [Double]
    public let condition: [CellCondition]
    public let highSpots: [Hotspot]
    public let lowSpots: [Hotspot]
    public let highest: Double
    public let lowest: Double
    public let worstGap: Double
    public let coveredArea: Double
    public let inSpecFraction: Double
    /// Rise of the best-fit plane across one spec span, i.e. how out of level the floor is overall.
    public let slopeOverSpan: Double
    public let grindVolume: Double
    public let fillVolume: Double

    public var passes: Bool { worstGap <= spec.tolerance }
}

public enum FlatnessAnalyzer {
    /// Reads the floor the way an installer would: lay a straightedge everywhere (along rows,
    /// columns and both diagonals), flag the humps it rocks on, then re-check as if those were
    /// ground down — whatever still shows a gap needs fill.
    public static func analyze(_ grid: ElevationGrid, spec: FlatnessSpec, reference: ReferencePlane = .bestFit,
                               minimumHotspotCells: Int = 1) -> FlatnessReport {
        let n = grid.cellCount
        let tolerance = spec.tolerance
        // Highs get ground down to a quarter of the tolerance above the reference; leaving more
        // than that makes a ridge the straightedge can still rock on.
        let grindLevel = tolerance / 4
        let bestFit = bestFitPlane(grid)
        let plane: Plane
        switch reference {
        case .bestFit:
            plane = bestFit
        case .level:
            let known = grid.heights.compactMap { $0 }
            plane = Plane(a: 0, b: 0, c: known.isEmpty ? 0 : known.reduce(0, +) / Double(known.count))
        }

        var deviation = [Double?](repeating: nil, count: n)
        for i in 0..<n {
            guard let h = grid.heights[i] else { continue }
            let p = grid.center(of: i)
            deviation[i] = h - plane.z(atX: p.x, y: p.y)
        }

        let asIs = Straightedge.evaluate(grid: grid, values: deviation, span: spec.span, tolerance: tolerance)

        // Grind: hull points of failing straightedge placements that stand proud of the plane,
        // grown out over the raised area connected to them.
        var grind = [Bool](repeating: false, count: n)
        var stack: [Int] = []
        for i in 0..<n where asIs.violationSupport[i] {
            if let d = deviation[i], d > grindLevel {
                grind[i] = true
                stack.append(i)
            }
        }
        while let i = stack.popLast() {
            for j in grid.neighbors4(of: i) where !grind[j] {
                if let d = deviation[j], d > grindLevel {
                    grind[j] = true
                    stack.append(j)
                }
            }
        }

        var ground = deviation
        for i in 0..<n where grind[i] {
            ground[i] = min(deviation[i]!, grindLevel)
        }
        let afterGrind = Straightedge.evaluate(grid: grid, values: ground, span: spec.span, tolerance: tolerance)

        var condition = [CellCondition](repeating: .noData, count: n)
        var fill = [Bool](repeating: false, count: n)
        var grindVolume = 0.0
        var fillVolume = 0.0
        var known = 0
        var inSpec = 0
        for i in 0..<n {
            guard let d = deviation[i] else { continue }
            known += 1
            if asIs.gap[i] <= tolerance { inSpec += 1 }
            if grind[i] {
                condition[i] = .grind
                grindVolume += (d - grindLevel) * grid.cellArea
            } else if afterGrind.gap[i] > tolerance {
                condition[i] = .fill
                fill[i] = true
                fillVolume += afterGrind.gap[i] * grid.cellArea
            } else if asIs.gap[i] > tolerance {
                condition[i] = .clearsAfterGrind
            } else {
                condition[i] = .ok
            }
        }

        let knownDeviations = deviation.compactMap { $0 }
        return FlatnessReport(
            grid: grid,
            spec: spec,
            reference: reference,
            plane: plane,
            deviation: deviation,
            straightedgeGap: asIs.gap,
            condition: condition,
            highSpots: hotspots(in: grid, mask: grind, kind: .high, magnitude: { deviation[$0] ?? 0 },
                                minimumCells: minimumHotspotCells),
            lowSpots: hotspots(in: grid, mask: fill, kind: .low, magnitude: { afterGrind.gap[$0] },
                               minimumCells: minimumHotspotCells),
            highest: knownDeviations.max() ?? 0,
            lowest: knownDeviations.min() ?? 0,
            worstGap: asIs.gap.max() ?? 0,
            coveredArea: Double(known) * grid.cellArea,
            inSpecFraction: known > 0 ? Double(inSpec) / Double(known) : 0,
            slopeOverSpan: bestFit.slope * spec.span,
            grindVolume: grindVolume,
            fillVolume: fillVolume
        )
    }

    /// Least squares over measured cells, refit once without outliers so one big hump
    /// doesn't tilt the reference.
    static func bestFitPlane(_ grid: ElevationGrid) -> Plane {
        var samples: [SurveyPoint] = []
        for i in 0..<grid.cellCount where grid.isMeasured[i] {
            guard let h = grid.heights[i] else { continue }
            let p = grid.center(of: i)
            samples.append(SurveyPoint(x: p.x, y: p.y, z: h))
        }
        if samples.count < 3 {
            samples = (0..<grid.cellCount).compactMap { i in
                grid.heights[i].map { h in
                    let p = grid.center(of: i)
                    return SurveyPoint(x: p.x, y: p.y, z: h)
                }
            }
        }
        let first = Plane.leastSquares(samples)
        let residuals = samples.map { $0.z - first.z(atX: $0.x, y: $0.y) }
        let rms = (residuals.reduce(0) { $0 + $1 * $1 } / Double(max(1, residuals.count))).squareRoot()
        guard rms > 0 else { return first }
        let kept = zip(samples, residuals).filter { abs($0.1) <= 2.5 * rms }.map(\.0)
        return kept.count >= 3 ? Plane.leastSquares(kept) : first
    }

    static func hotspots(in grid: ElevationGrid, mask: [Bool], kind: Hotspot.Kind,
                         magnitude: (Int) -> Double, minimumCells: Int) -> [Hotspot] {
        var visited = [Bool](repeating: false, count: mask.count)
        var regions: [(cells: [Int], worst: Int)] = []
        for seed in 0..<mask.count where mask[seed] && !visited[seed] {
            visited[seed] = true
            var cells: [Int] = []
            var queue = [seed]
            var worst = seed
            while let i = queue.popLast() {
                cells.append(i)
                if magnitude(i) > magnitude(worst) { worst = i }
                for j in grid.neighbors4(of: i) where mask[j] && !visited[j] {
                    visited[j] = true
                    queue.append(j)
                }
            }
            if cells.count >= minimumCells { regions.append((cells, worst)) }
        }
        regions.sort { magnitude($0.worst) > magnitude($1.worst) }
        return regions.enumerated().map { offset, region in
            let p = grid.center(of: region.worst)
            return Hotspot(kind: kind, rank: offset + 1, x: p.x, y: p.y,
                           area: Double(region.cells.count) * grid.cellArea,
                           magnitude: magnitude(region.worst), cells: region.cells)
        }
    }
}

/// Simulated straightedge. For every placement along a profile it rests on the upper convex hull
/// of the floor beneath it, and the gap at each point is the straightedge height minus the floor.
enum Straightedge {
    struct Result {
        var gap: [Double]
        /// Cells a failing straightedge placement rests on.
        var violationSupport: [Bool]
    }

    private struct Sample {
        let index: Int
        let s: Double
        let z: Double
    }

    static func evaluate(grid: ElevationGrid, values: [Double?], span: Double, tolerance: Double) -> Result {
        var result = Result(gap: [Double](repeating: 0, count: grid.cellCount),
                            violationSupport: [Bool](repeating: false, count: grid.cellCount))
        let columns = grid.columns, rows = grid.rows
        var line: [Sample] = []
        var hull: [Int] = []
        line.reserveCapacity(columns + rows)
        for (dc, dr) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
            let step = grid.cellSize * (dc != 0 && dr != 0 ? 2.0.squareRoot() : 1)
            for (startColumn, startRow) in lineStarts(columns: columns, rows: rows, dc: dc, dr: dr) {
                var column = startColumn, row = startRow, s = 0.0
                line.removeAll(keepingCapacity: true)
                while column >= 0, column < columns, row >= 0, row < rows {
                    let i = row * columns + column
                    if let z = values[i] {
                        line.append(Sample(index: i, s: s, z: z))
                    } else {
                        // A hole splits the line; a straightedge can't bridge missing data.
                        slide(over: line, span: span, tolerance: tolerance, hull: &hull, into: &result)
                        line.removeAll(keepingCapacity: true)
                    }
                    column += dc
                    row += dr
                    s += step
                }
                slide(over: line, span: span, tolerance: tolerance, hull: &hull, into: &result)
            }
        }
        return result
    }

    private static func lineStarts(columns: Int, rows: Int, dc: Int, dr: Int) -> [(Int, Int)] {
        switch (dc, dr) {
        case (1, 0): return (0..<rows).map { (0, $0) }
        case (0, 1): return (0..<columns).map { ($0, 0) }
        case (1, 1): return (0..<columns).map { ($0, 0) } + (1..<rows).map { (0, $0) }
        default: return (0..<columns).map { ($0, rows - 1) } + (0..<(rows - 1)).map { (0, $0) }
        }
    }

    /// Slides a straightedge of length `span` along one profile. Lines shorter than the span
    /// get a single placement over their whole length.
    private static func slide(over line: [Sample], span: Double, tolerance: Double,
                              hull: inout [Int], into result: inout Result) {
        guard line.count >= 2 else { return }
        var end = 0
        for start in 0..<line.count {
            while end + 1 < line.count, line[end + 1].s - line[start].s <= span + 1e-9 { end += 1 }
            if end > start {
                place(on: line, from: start, to: end, tolerance: tolerance, hull: &hull, into: &result)
            }
            if end == line.count - 1 { break }
        }
    }

    private static func place(on line: [Sample], from start: Int, to end: Int, tolerance: Double,
                              hull: inout [Int], into result: inout Result) {
        hull.removeAll(keepingCapacity: true)
        for k in start...end {
            while hull.count >= 2 {
                let o = line[hull[hull.count - 2]], a = line[hull[hull.count - 1]], b = line[k]
                let cross = (a.s - o.s) * (b.z - o.z) - (a.z - o.z) * (b.s - o.s)
                if cross >= 0 { hull.removeLast() } else { break }
            }
            hull.append(k)
        }
        // Gravity settles the straightedge on the hull edge under its middle. If the middle
        // sits right on a hull point it balances there and can rock either way: try both.
        let middle = (line[start].s + line[end].s) / 2
        for h in 0..<(hull.count - 1) {
            let left = line[hull[h]], right = line[hull[h + 1]]
            guard left.s - 1e-9 <= middle, middle <= right.s + 1e-9 else { continue }
            let slope = (right.z - left.z) / (right.s - left.s)
            var worst = 0.0
            for k in start...end {
                let gap = max(0, left.z + slope * (line[k].s - left.s) - line[k].z)
                if gap > result.gap[line[k].index] { result.gap[line[k].index] = gap }
                worst = max(worst, gap)
            }
            if worst > tolerance {
                result.violationSupport[left.index] = true
                result.violationSupport[right.index] = true
            }
        }
    }
}
