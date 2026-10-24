import Foundation
import SubfloorCore

enum Analysis {
    /// Map resolution: 2" cells for scans, and fine enough to show the shape between manual nodes.
    static let scanCellSize = Length.inches(2)

    static func grid(for project: FloorProject) -> ElevationGrid? {
        switch project.method {
        case .lidar:
            guard !project.scanPoints.isEmpty else { return nil }
            return ElevationGrid.binning(project.scanPoints, cellSize: scanCellSize, interpolationRadius: Length.inches(4))
        case .manual:
            guard let survey = project.manual else { return nil }
            return survey.grid(cellSize: min(Length.inches(3), survey.spacing / 4))
        }
    }

    static func report(for project: FloorProject) -> FlatnessReport? {
        guard let grid = grid(for: project) else { return nil }
        // One 2" cell on its own is more likely sensor noise than a real spot worth chasing.
        let minimumCells = project.method == .lidar ? 3 : 1
        return FlatnessAnalyzer.analyze(grid, spec: project.spec, reference: project.reference,
                                        minimumHotspotCells: minimumCells)
    }

    /// Bags of patch / self-leveler for a fill volume. Yield varies a lot by product, so this is a ballpark.
    static func bagEstimate(fillVolume: Double, cubicFeetPerBag: Double = 0.45) -> Int {
        let cubicFeet = fillVolume / pow(Length.metersPerFoot, 3)
        return Int((cubicFeet / cubicFeetPerBag).rounded(.up))
    }

    /// Where a spot is, in words an installer can pace off.
    static func locationText(x: Double, y: Double, project: FloorProject) -> String {
        let across = MeasureFormat.distance(x, units: project.units)
        let down = MeasureFormat.distance(y, units: project.units)
        if project.method == .manual, let survey = project.manual {
            let column = survey.xs.enumerated().min { abs($0.element - x) < abs($1.element - x) }!.offset
            let row = survey.ys.enumerated().min { abs($0.element - y) < abs($1.element - y) }!.offset
            return "\(across) across, \(down) down · near \(survey.label(of: survey.index(column: column, row: row)))"
        }
        return "\(across) across, \(down) down"
    }
}
