import XCTest
@testable import SubfloorCore

final class FlatnessAnalyzerTests: XCTestCase {
    let spec = FlatnessSpec.threeSixteenthsPerTenFeet
    let inch = Length.metersPerInch

    /// 12' x 12' room sampled every 2", with an optional shape added on top of a tilted plane.
    func makeGrid(_ shape: (Double, Double) -> Double = { _, _ in 0 }) -> ElevationGrid {
        let size = Length.feet(12), cell = Length.inches(2)
        let n = Int((size / cell).rounded()) + 1
        var heights: [Double?] = []
        for row in 0..<n {
            for column in 0..<n {
                let x = Double(column) * cell, y = Double(row) * cell
                heights.append(0.01 * x - 0.004 * y + 0.05 + shape(x, y))
            }
        }
        return ElevationGrid(columns: n, rows: n, cellSize: cell, heights: heights)
    }

    func bump(centerX: Double, centerY: Double, radius: Double, height: Double) -> (Double, Double) -> Double {
        { x, y in
            let d2 = (x - centerX) * (x - centerX) + (y - centerY) * (y - centerY)
            return height * exp(-d2 / (2 * radius * radius))
        }
    }

    func testTiltedButFlatFloorPasses() {
        let report = FlatnessAnalyzer.analyze(makeGrid(), spec: spec)
        XCTAssertTrue(report.passes)
        XCTAssertLessThan(report.worstGap, 1e-9)
        XCTAssertEqual(report.highest, 0, accuracy: 1e-9)
        XCTAssertEqual(report.lowest, 0, accuracy: 1e-9)
        XCTAssertTrue(report.highSpots.isEmpty)
        XCTAssertTrue(report.lowSpots.isEmpty)
        XCTAssertEqual(report.inSpecFraction, 1, accuracy: 1e-9)
    }

    func testDipIsFlaggedForFill() throws {
        let center = Length.feet(6)
        let grid = makeGrid(bump(centerX: center, centerY: center, radius: Length.inches(10), height: -0.4 * inch))
        let report = FlatnessAnalyzer.analyze(grid, spec: spec)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(report.highSpots.isEmpty)
        let low = try XCTUnwrap(report.lowSpots.first)
        XCTAssertEqual(low.x, center, accuracy: Length.inches(2))
        XCTAssertEqual(low.y, center, accuracy: Length.inches(2))
        XCTAssertEqual(low.magnitude, 0.4 * inch, accuracy: 0.05 * inch)
        XCTAssertGreaterThan(report.fillVolume, 0)
        XCTAssertEqual(report.grindVolume, 0)
    }

    func testHumpIsFlaggedForGrindingNotFill() throws {
        let grid = makeGrid(bump(centerX: Length.feet(4), centerY: Length.feet(8), radius: Length.inches(8),
                                 height: 0.5 * inch))
        let report = FlatnessAnalyzer.analyze(grid, spec: spec)
        XCTAssertFalse(report.passes)
        let high = try XCTUnwrap(report.highSpots.first)
        XCTAssertEqual(high.x, Length.feet(4), accuracy: Length.inches(2))
        XCTAssertEqual(high.y, Length.feet(8), accuracy: Length.inches(2))
        // The flat floor around the hump is only "low" relative to the hump, so once the
        // hump is ground nothing should be left to fill.
        XCTAssertTrue(report.lowSpots.isEmpty, "unexpected lows: \(report.lowSpots.map(\.label))")
        XCTAssertTrue(report.condition.contains(.clearsAfterGrind))
    }

    func testGentleCrownWithinSpecIsLeftAlone() {
        // A 1/4" crown across the room is out of level, but never leaves more than 3/16"
        // under a 10' straightedge, so there's nothing to grind or fill.
        let grid = makeGrid { x, _ in
            let u = x / Length.feet(12) * 2 - 1
            return (1 - u * u) * 0.25 * self.inch
        }
        let report = FlatnessAnalyzer.analyze(grid, spec: spec)
        XCTAssertTrue(report.passes)
        XCTAssertTrue(report.highSpots.isEmpty)
    }

    func testCrownOutOfSpecIsGroundAtTheTop() throws {
        // A 1/2" crown: the straightedge balances on top and both ends hover.
        let grid = makeGrid { x, _ in
            let u = x / Length.feet(12) * 2 - 1
            return (1 - u * u) * 0.5 * self.inch
        }
        let report = FlatnessAnalyzer.analyze(grid, spec: spec)
        XCTAssertFalse(report.passes)
        let high = try XCTUnwrap(report.highSpots.first)
        XCTAssertEqual(high.x, Length.feet(6), accuracy: Length.feet(1))
    }

    func testHolesSplitTheStraightedge() {
        var grid = makeGrid()
        let row = grid.rows / 2
        for column in 0..<grid.columns { grid.heights[grid.index(column: column, row: row)] = nil }
        let report = FlatnessAnalyzer.analyze(grid, spec: spec)
        XCTAssertTrue(report.passes)
        XCTAssertEqual(report.condition[grid.index(column: 3, row: row)], .noData)
    }
}

final class ManualSurveyTests: XCTestCase {
    func testNodesIncludeBothWalls() {
        XCTAssertEqual(ManualSurvey.nodes(extent: 3, spacing: 1), [0, 1, 2, 3])
        XCTAssertEqual(ManualSurvey.nodes(extent: 3.5, spacing: 1), [0, 1, 2, 3, 3.5])
        XCTAssertEqual(ManualSurvey.nodes(extent: 3.1, spacing: 1), [0, 1, 2, 3.1])
    }

    func testDistanceToLaserInvertsSign() {
        var survey = ManualSurvey(width: 2, length: 2, spacing: 1)
        survey.record(0.05, at: 0)
        XCTAssertEqual(survey.elevation(at: 0), -0.05)
        survey.readingMode = .elevation
        XCTAssertEqual(survey.elevation(at: 0), 0.05)
    }

    func testWalkingOrderSnakes() {
        let survey = ManualSurvey(width: 2, length: 1, spacing: 1)
        XCTAssertEqual(survey.walkingOrder, [0, 1, 2, 5, 4, 3])
        XCTAssertEqual(survey.label(of: 4), "B2")
        XCTAssertEqual(ManualSurvey.columnLetters(26), "AA")
    }

    func testNextPendingSkipsDoneAndSkipped() {
        var survey = ManualSurvey(width: 2, length: 1, spacing: 1)
        survey.record(0.01, at: 0)
        survey.skip(1)
        XCTAssertEqual(survey.nextPending(after: 0), 2)
        XCTAssertEqual(survey.nextPending(after: 3), 2)
    }

    func testLowReadingShowsUpAsLowSpot() throws {
        var survey = ManualSurvey(width: Length.feet(10), length: Length.feet(10), spacing: Length.feet(2))
        for i in 0..<survey.nodeCount { survey.record(Length.inches(2), at: i) }
        let middle = survey.index(column: 2, row: 3)
        survey.record(Length.inches(2.5), at: middle) // laser further above floor = floor is lower
        let grid = try XCTUnwrap(survey.grid(cellSize: Length.inches(3)))
        let report = FlatnessAnalyzer.analyze(grid, spec: .threeSixteenthsPerTenFeet)
        XCTAssertFalse(report.passes)
        let low = try XCTUnwrap(report.lowSpots.first)
        XCTAssertEqual(low.x, survey.xs[2], accuracy: 1e-6)
        XCTAssertEqual(low.y, survey.ys[3], accuracy: 1e-6)
    }
}

final class ParsingAndFormattingTests: XCTestCase {
    func testParsesJobSiteFractions() {
        let inch = Length.metersPerInch
        XCTAssertEqual(MeasureParser.height("1 3/16", units: .imperial)!, 1.1875 * inch, accuracy: 1e-12)
        XCTAssertEqual(MeasureParser.height("1-3/16\"", units: .imperial)!, 1.1875 * inch, accuracy: 1e-12)
        XCTAssertEqual(MeasureParser.height("3/8", units: .imperial)!, 0.375 * inch, accuracy: 1e-12)
        XCTAssertEqual(MeasureParser.height("-1.5", units: .imperial)!, -1.5 * inch, accuracy: 1e-12)
        XCTAssertEqual(MeasureParser.height("12,5", units: .metric)!, 0.0125, accuracy: 1e-12)
        XCTAssertNil(MeasureParser.height("abc", units: .imperial))
        XCTAssertNil(MeasureParser.height("3/0", units: .imperial))
        XCTAssertNil(MeasureParser.height("1/2 3", units: .imperial))
    }

    func testFormatsFractions() {
        XCTAssertEqual(MeasureFormat.height(Length.inches(0.1875), units: .imperial), "3/16\"")
        XCTAssertEqual(MeasureFormat.height(Length.inches(-1.25), units: .imperial, signed: true), "−1 1/4\"")
        XCTAssertEqual(MeasureFormat.distance(Length.feet(5) + Length.inches(3), units: .imperial), "5' 3\"")
        XCTAssertEqual(MeasureFormat.height(0.0042, units: .metric, signed: true), "+4.2 mm")
    }
}

final class PointCloudTests: XCTestCase {
    func testAlignmentSquaresUpARotatedRoom() {
        var points: [SurveyPoint] = []
        let angle = 0.5 // radians
        for i in 0..<40 {
            for j in 0..<20 {
                let x = Double(i) * 0.1, y = Double(j) * 0.1
                points.append(SurveyPoint(x: x * cos(angle) - y * sin(angle), y: x * sin(angle) + y * cos(angle), z: 0))
            }
        }
        let aligned = PointCloudAlignment.alignedToAxes(points)
        let width = aligned.map(\.x).max()! - aligned.map(\.x).min()!
        let length = aligned.map(\.y).max()! - aligned.map(\.y).min()!
        XCTAssertEqual(max(width, length), 3.9, accuracy: 0.05)
        XCTAssertEqual(min(width, length), 1.9, accuracy: 0.05)
        XCTAssertEqual(aligned.map(\.x).min()!, 0, accuracy: 1e-9)
    }

    func testAccumulatorAveragesAndRejectsEdges() {
        var accumulator = PointAccumulator(binSize: 0.0254)
        for z in [0.001, 0.003, 0.002] { accumulator.add(x: 0.01, y: 0.01, z: z) }
        for z in [0.0, 0.05, 0.0] { accumulator.add(x: 1.01, y: 0.01, z: z) } // object edge
        accumulator.add(x: 2.01, y: 0.01, z: 0)
        let points = accumulator.points()
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].z, 0.002, accuracy: 1e-12)
    }
}
