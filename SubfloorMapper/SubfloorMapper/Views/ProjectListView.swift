import SubfloorCore
import SwiftUI

struct ProjectListView: View {
    @Environment(ProjectStore.self) private var store
    @State private var path: [UUID] = []
    @State private var newMethod: SurveyMethod?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.projects) { project in
                    NavigationLink(value: project.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.name).font(.headline)
                            HStack {
                                Label(project.method.title, systemImage: project.method == .lidar ? "camera.metering.matrix" : "grid")
                                Text("·")
                                Text(project.spec.name)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(project.updatedAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { store.projects[$0].id }.forEach(store.delete)
                }
            }
            .overlay {
                if store.projects.isEmpty {
                    ContentUnavailableView {
                        Label("No floors yet", systemImage: "square.grid.3x3.middle.filled")
                    } description: {
                        Text("Map a subfloor's high and low spots before laying vinyl plank.")
                    } actions: {
                        newProjectMenu.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Subfloor Mapper")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { newProjectMenu }
            }
            .navigationDestination(for: UUID.self) { id in
                ProjectDetailView(projectID: id)
            }
            .sheet(item: $newMethod) { method in
                NewProjectView(method: method) { project in
                    store.save(project)
                    path = [project.id]
                }
            }
        }
    }

    private var newProjectMenu: some View {
        Menu {
            Button {
                newMethod = .lidar
            } label: {
                Label("LiDAR scan", systemImage: "camera.metering.matrix")
            }
            .disabled(!FloorScanner.isSupported)
            Button {
                newMethod = .manual
            } label: {
                Label("Laser level grid", systemImage: "grid")
            }
        } label: {
            Label("New floor", systemImage: "plus")
        }
    }
}

extension SurveyMethod: Identifiable {
    var id: String { rawValue }
}
