import Foundation
import Observation

/// Keeps every project as its own JSON file in the app's Documents folder.
@Observable
final class ProjectStore {
    private(set) var projects: [FloorProject] = []
    var lastError: String?

    @ObservationIgnored private let directory: URL

    init(directory: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? documents.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        load()
    }

    func project(_ id: UUID) -> FloorProject? {
        projects.first { $0.id == id }
    }

    func save(_ project: FloorProject) {
        var project = project
        project.updatedAt = Date()
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
        projects.sort { $0.updatedAt > $1.updatedAt }
        do {
            let data = try JSONEncoder().encode(project)
            try data.write(to: url(for: project.id), options: .atomic)
        } catch {
            lastError = "Couldn't save \(project.name): \(error.localizedDescription)"
        }
    }

    func delete(_ id: UUID) {
        projects.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        projects = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(FloorProject.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
