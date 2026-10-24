import Foundation
import SubfloorCore

enum SurveyMethod: String, Codable, CaseIterable {
    case lidar
    case manual

    var title: String {
        switch self {
        case .lidar: "LiDAR scan"
        case .manual: "Laser level grid"
        }
    }
}

struct FloorProject: Codable, Identifiable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var updatedAt = Date()
    var method: SurveyMethod
    var units: UnitSystem
    var spec: FlatnessSpec
    var reference: ReferencePlane = .bestFit
    /// LiDAR results, already squared up to the room and averaged into ~1" bins.
    var scanPoints: [SurveyPoint] = []
    var manual: ManualSurvey?
    var notes = ""

    var hasData: Bool {
        switch method {
        case .lidar: !scanPoints.isEmpty
        case .manual: (manual?.completedCount ?? 0) >= 3
        }
    }
}

extension ReferencePlane {
    var title: String {
        switch self {
        case .bestFit: "Flat (best fit)"
        case .level: "Level"
        }
    }
}

extension ManualSurvey.ReadingMode {
    var title: String {
        switch self {
        case .distanceToLaser: "Floor up to laser line"
        case .elevation: "Floor elevation"
        }
    }

    var explanation: String {
        switch self {
        case .distanceToLaser: "Measure from the floor up to the laser line. A bigger number means the floor is lower."
        case .elevation: "Enter the floor's height. A bigger number means the floor is higher."
        }
    }
}
