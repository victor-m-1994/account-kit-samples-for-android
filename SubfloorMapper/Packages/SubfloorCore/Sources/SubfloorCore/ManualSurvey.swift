import Foundation

/// Readings taken by hand on a grid chalked across the room, typically with a rotating laser
/// and a tape or detector rod. Column 0 / row 0 is the starting corner (top-left on the map).
public struct ManualSurvey: Codable, Hashable, Sendable {
    public enum ReadingMode: String, Codable, CaseIterable, Sendable {
        /// Distance from the floor up to a laser line. Bigger number = lower floor.
        case distanceToLaser
        /// Floor elevation. Bigger number = higher floor.
        case elevation
    }

    public let width: Double
    public let length: Double
    public let spacing: Double
    public var readingMode: ReadingMode
    /// Row-major raw readings in meters, nil where not yet taken or skipped.
    public var readings: [Double?]
    /// Nodes deliberately skipped (cabinets, toilet flange, etc.).
    public var skipped: Set<Int>

    public init(width: Double, length: Double, spacing: Double, readingMode: ReadingMode = .distanceToLaser) {
        precondition(width > 0 && length > 0 && spacing > 0)
        self.width = width
        self.length = length
        self.spacing = spacing
        self.readingMode = readingMode
        self.readings = []
        self.skipped = []
        self.readings = [Double?](repeating: nil, count: columns * rows)
    }

    public var xs: [Double] { Self.nodes(extent: width, spacing: spacing) }
    public var ys: [Double] { Self.nodes(extent: length, spacing: spacing) }
    public var columns: Int { xs.count }
    public var rows: Int { ys.count }
    public var nodeCount: Int { columns * rows }
    public var completedCount: Int { readings.lazy.filter { $0 != nil }.count }
    public var remainingCount: Int { nodeCount - completedCount - skipped.count }

    public func index(column: Int, row: Int) -> Int { row * columns + column }

    /// Spreadsheet-style node name: columns A, B, C… and rows 1, 2, 3…
    public func label(of index: Int) -> String {
        Self.columnLetters(index % columns) + "\(index / columns + 1)"
    }

    public static func columnLetters(_ column: Int) -> String {
        var n = column
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters
            n = n / 26 - 1
        } while n >= 0
        return letters
    }

    public mutating func record(_ value: Double?, at index: Int) {
        readings[index] = value
        if value != nil { skipped.remove(index) }
    }

    public mutating func skip(_ index: Int) {
        readings[index] = nil
        skipped.insert(index)
    }

    /// Floor elevation at a node with the reading mode applied.
    public func elevation(at index: Int) -> Double? {
        guard let reading = readings[index] else { return nil }
        return readingMode == .elevation ? reading : -reading
    }

    /// Back-and-forth walking order, so the next node is always a step away.
    public var walkingOrder: [Int] {
        (0..<rows).flatMap { row in
            let columnsInRow = row.isMultiple(of: 2) ? Array(0..<columns) : Array((0..<columns).reversed())
            return columnsInRow.map { index(column: $0, row: row) }
        }
    }

    /// The next node still waiting for a reading after `index` in walking order.
    public func nextPending(after index: Int?) -> Int? {
        let order = walkingOrder
        let start = index.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let rotated = order[start...] + order[..<start]
        return rotated.first { readings[$0] == nil && !skipped.contains($0) }
    }

    public func grid(cellSize: Double) -> ElevationGrid? {
        guard completedCount >= 3 else { return nil }
        return ElevationGrid.interpolating(nodesX: xs, nodesY: ys,
                                           values: (0..<nodeCount).map { elevation(at: $0) },
                                           cellSize: cellSize)
    }

    /// Nodes every `spacing` from 0, plus one on the far wall. A leftover sliver under a quarter
    /// spacing is absorbed by moving the last node onto the wall instead.
    static func nodes(extent: Double, spacing: Double) -> [Double] {
        let whole = Int((extent / spacing + 1e-9).rounded(.down))
        var values = (0...whole).map { Double($0) * spacing }
        let remainder = extent - values[values.count - 1]
        if remainder > spacing * 0.25 {
            values.append(extent)
        } else if values.count > 1 {
            values[values.count - 1] = extent
        } else {
            values.append(extent)
        }
        return values
    }
}
