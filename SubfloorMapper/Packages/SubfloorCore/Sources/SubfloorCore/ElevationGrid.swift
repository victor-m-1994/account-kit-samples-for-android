import Foundation

/// A regular grid of floor heights. Cell `(column, row)` is centered at
/// `(originX + column * cellSize, originY + row * cellSize)`; row 0 is the top of the map.
public struct ElevationGrid: Sendable {
    public let columns: Int
    public let rows: Int
    public let cellSize: Double
    public let originX: Double
    public let originY: Double
    /// Row-major heights in meters; nil where there is no floor data to interpolate from.
    public var heights: [Double?]
    /// True for cells backed by a real measurement, false for interpolated ones.
    public var isMeasured: [Bool]

    public init(columns: Int, rows: Int, cellSize: Double, originX: Double = 0, originY: Double = 0,
                heights: [Double?], isMeasured: [Bool]? = nil) {
        precondition(columns > 0 && rows > 0 && cellSize > 0 && heights.count == columns * rows)
        self.columns = columns
        self.rows = rows
        self.cellSize = cellSize
        self.originX = originX
        self.originY = originY
        self.heights = heights
        self.isMeasured = isMeasured ?? heights.map { $0 != nil }
    }

    public var cellCount: Int { columns * rows }
    public var width: Double { Double(columns) * cellSize }
    public var length: Double { Double(rows) * cellSize }
    public var cellArea: Double { cellSize * cellSize }

    public func index(column: Int, row: Int) -> Int { row * columns + column }

    public func position(of index: Int) -> (column: Int, row: Int) { (index % columns, index / columns) }

    public func center(of index: Int) -> (x: Double, y: Double) {
        let p = position(of: index)
        return (originX + Double(p.column) * cellSize, originY + Double(p.row) * cellSize)
    }

    /// The cell containing a floor position, if it's on the grid.
    public func index(atX x: Double, y: Double) -> Int? {
        let column = Int(((x - originX) / cellSize).rounded())
        let row = Int(((y - originY) / cellSize).rounded())
        guard (0..<columns).contains(column), (0..<rows).contains(row) else { return nil }
        return index(column: column, row: row)
    }

    func neighbors4(of index: Int) -> [Int] {
        let (column, row) = position(of: index)
        var result: [Int] = []
        result.reserveCapacity(4)
        if column > 0 { result.append(index - 1) }
        if column < columns - 1 { result.append(index + 1) }
        if row > 0 { result.append(index - columns) }
        if row < rows - 1 { result.append(index + columns) }
        return result
    }
}

extension ElevationGrid {
    /// Bins scattered points (e.g. a LiDAR scan) and fills small holes by inverse-distance weighting.
    /// Holes farther than `interpolationRadius` from any data stay empty.
    public static func binning(_ points: [SurveyPoint], cellSize: Double, interpolationRadius: Double,
                               maxCells: Int = 250_000) -> ElevationGrid? {
        guard !points.isEmpty, cellSize > 0,
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }

        var size = cellSize
        var columns = 0
        var rows = 0
        while true {
            columns = Int(((maxX - minX) / size).rounded()) + 1
            rows = Int(((maxY - minY) / size).rounded()) + 1
            if columns * rows <= maxCells { break }
            size *= 1.25
        }

        var sums = [Double](repeating: 0, count: columns * rows)
        var counts = [Int](repeating: 0, count: columns * rows)
        for p in points {
            let column = min(columns - 1, max(0, Int(((p.x - minX) / size).rounded())))
            let row = min(rows - 1, max(0, Int(((p.y - minY) / size).rounded())))
            sums[row * columns + column] += p.z
            counts[row * columns + column] += 1
        }

        let measured = counts.map { $0 > 0 }
        var heights: [Double?] = zip(sums, counts).map { $1 > 0 ? $0 / Double($1) : nil }
        let radius = max(1, Int((interpolationRadius / size).rounded(.up)))
        let original = heights
        for row in 0..<rows {
            for column in 0..<columns where !measured[row * columns + column] {
                var weightSum = 0.0
                var valueSum = 0.0
                for dr in -radius...radius {
                    let r = row + dr
                    guard (0..<rows).contains(r) else { continue }
                    for dc in -radius...radius {
                        let c = column + dc
                        guard (0..<columns).contains(c), let h = original[r * columns + c] else { continue }
                        let d2 = Double(dc * dc + dr * dr)
                        guard d2 <= Double(radius * radius) else { continue }
                        let w = 1 / d2
                        weightSum += w
                        valueSum += w * h
                    }
                }
                if weightSum > 0 { heights[row * columns + column] = valueSum / weightSum }
            }
        }
        return ElevationGrid(columns: columns, rows: rows, cellSize: size, originX: minX, originY: minY,
                             heights: heights, isMeasured: measured)
    }

    /// Bilinear interpolation of readings taken on a rectangular layout of nodes (a manual survey).
    /// `values` is row-major over `nodesY` rows and `nodesX` columns; nil marks a skipped node.
    public static func interpolating(nodesX xs: [Double], nodesY ys: [Double], values: [Double?],
                                     cellSize: Double) -> ElevationGrid? {
        guard xs.count >= 2, ys.count >= 2, values.count == xs.count * ys.count, cellSize > 0,
              values.contains(where: { $0 != nil }) else { return nil }
        let nx = xs.count
        let x0 = xs[0], y0 = ys[0], x1 = xs[nx - 1], y1 = ys[ys.count - 1]
        let columns = Int(((x1 - x0) / cellSize).rounded()) + 1
        let rows = Int(((y1 - y0) / cellSize).rounded()) + 1
        var heights = [Double?](repeating: nil, count: columns * rows)
        var measured = [Bool](repeating: false, count: columns * rows)

        for row in 0..<rows {
            let y = min(y0 + Double(row) * cellSize, y1)
            let j = segment(ys, containing: y)
            let ty = (y - ys[j]) / (ys[j + 1] - ys[j])
            for column in 0..<columns {
                let x = min(x0 + Double(column) * cellSize, x1)
                let i = segment(xs, containing: x)
                let tx = (x - xs[i]) / (xs[i + 1] - xs[i])
                let corners: [(value: Double?, weight: Double)] = [
                    (values[j * nx + i], (1 - tx) * (1 - ty)),
                    (values[j * nx + i + 1], tx * (1 - ty)),
                    (values[(j + 1) * nx + i], (1 - tx) * ty),
                    (values[(j + 1) * nx + i + 1], tx * ty),
                ]
                let known = corners.compactMap { corner in corner.value.map { ($0, corner.weight) } }
                guard !known.isEmpty else { continue }
                let weightSum = known.reduce(0) { $0 + $1.1 }
                // Renormalize over the corners we have; if they all carry zero weight we sit
                // exactly on a skipped node, so fall back to their plain average.
                heights[row * columns + column] = weightSum > 1e-9
                    ? known.reduce(0) { $0 + $1.0 * $1.1 } / weightSum
                    : known.reduce(0) { $0 + $1.0 } / Double(known.count)
            }
        }

        for (n, value) in values.enumerated() where value != nil {
            let column = Int(((xs[n % nx] - x0) / cellSize).rounded())
            let row = Int(((ys[n / nx] - y0) / cellSize).rounded())
            measured[min(rows - 1, row) * columns + min(columns - 1, column)] = true
        }
        return ElevationGrid(columns: columns, rows: rows, cellSize: cellSize, originX: x0, originY: y0,
                             heights: heights, isMeasured: measured)
    }

    /// Index `i` with `nodes[i] <= value <= nodes[i + 1]`, clamped to the outer segments.
    private static func segment(_ nodes: [Double], containing value: Double) -> Int {
        var i = 0
        while i < nodes.count - 2 && value > nodes[i + 1] { i += 1 }
        return i
    }
}
