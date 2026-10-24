import SubfloorCore
import SwiftUI

struct ProjectDetailView: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @State private var report: FlatnessReport?
    @State private var layer: MapLayer = .heights
    @State private var showsScan = false
    @State private var showsSettings = false
    @State private var confirmsRescan = false

    var body: some View {
        if let project = store.project(projectID) {
            content(project)
        } else {
            ContentUnavailableView("Floor not found", systemImage: "questionmark.square.dashed")
        }
    }

    private func content(_ project: FloorProject) -> some View {
        List {
            captureSection(project)

            if let report {
                Section { VerdictView(report: report, units: project.units) }

                Section {
                    Picker("Map", selection: $layer) {
                        ForEach(MapLayer.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HeatmapView(report: report, units: project.units, layer: layer, nodes: nodes(project))
                    HeatmapLegend(report: report, units: project.units, layer: layer)
                } footer: {
                    Text(project.method == .manual
                         ? "Top-left is point A1. Tap the map to read any spot."
                         : "Map is squared to the room's walls. Tap the map to read any spot.")
                }

                Section {
                    ReportStatsRows(project: project, report: report)
                } header: {
                    Text("Measurements")
                } footer: {
                    if !report.highSpots.isEmpty {
                        Text("Gaps are for the floor as it is now. A hump makes the straightedge rock, which exaggerates the gaps around it until it's ground.")
                    }
                }
                HotspotSections(project: project, report: report)
            } else if project.hasData {
                Section { ProgressView("Analyzing…").frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let report {
                    ShareLink(item: FloorReportFile(project: project, report: report),
                              preview: SharePreview("\(project.name) floor report")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button { showsSettings = true } label: { Image(systemName: "slider.horizontal.3") }
            }
        }
        .task(id: project.updatedAt) { await analyze(project) }
        .fullScreenCover(isPresented: $showsScan) {
            ScanView(units: project.units, spec: project.spec) { points in
                guard var latest = store.project(projectID) else { return }
                latest.scanPoints = points
                store.save(latest)
            }
        }
        .sheet(isPresented: $showsSettings) {
            ProjectSettingsView(project: project) { store.save($0) }
        }
        .confirmationDialog("Replace the current scan?", isPresented: $confirmsRescan, titleVisibility: .visible) {
            Button("Scan again", role: .destructive) { showsScan = true }
        } message: {
            Text("Scans can't be stitched together, so a new scan replaces this one. Cover the whole floor in one go.")
        }
    }

    @ViewBuilder
    private func captureSection(_ project: FloorProject) -> some View {
        switch project.method {
        case .lidar:
            Section {
                Button {
                    if project.scanPoints.isEmpty { showsScan = true } else { confirmsRescan = true }
                } label: {
                    Label(project.scanPoints.isEmpty ? "Start scan" : "Scan again", systemImage: "camera.metering.matrix")
                }
                .disabled(!FloorScanner.isSupported)
            } footer: {
                if !FloorScanner.isSupported {
                    Text("This device has no LiDAR scanner. Use a laser level grid instead.")
                }
            }
        case .manual:
            if let survey = project.manual {
                Section {
                    NavigationLink {
                        ManualEntryView(survey: survey, units: project.units) { updated in
                            guard var latest = store.project(projectID) else { return }
                            latest.manual = updated
                            store.save(latest)
                        }
                    } label: {
                        LabeledContent {
                            Text("\(survey.completedCount) of \(survey.nodeCount)")
                        } label: {
                            Label(survey.completedCount == 0 ? "Enter readings" : "Readings", systemImage: "grid")
                        }
                    }
                } footer: {
                    if survey.completedCount < 3 {
                        Text("Enter at least 3 readings to see the map. More readings, sharper map.")
                    }
                }
            }
        }
    }

    private func nodes(_ project: FloorProject) -> [(x: Double, y: Double)] {
        guard let survey = project.manual else { return [] }
        let xs = survey.xs, ys = survey.ys
        return (0..<survey.nodeCount)
            .filter { survey.readings[$0] != nil }
            .map { (x: xs[$0 % xs.count], y: ys[$0 / xs.count]) }
    }

    @MainActor
    private func analyze(_ project: FloorProject) async {
        let result = await Task.detached(priority: .userInitiated) { Analysis.report(for: project) }.value
        guard !Task.isCancelled else { return }
        report = result
    }
}

struct VerdictView: View {
    let report: FlatnessReport
    let units: UnitSystem

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: report.passes ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(report.passes ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.passes ? "Ready for LVP" : "Needs floor prep")
                    .font(.title3.bold())
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        let tolerance = MeasureFormat.height(report.spec.tolerance, units: units)
        if report.passes {
            return "No gap over \(tolerance) under a \(MeasureFormat.distance(report.spec.span, units: units)) straightedge."
        }
        var parts: [String] = []
        if !report.highSpots.isEmpty { parts.append("\(report.highSpots.count) high spot\(report.highSpots.count == 1 ? "" : "s") to grind") }
        if !report.lowSpots.isEmpty { parts.append("\(report.lowSpots.count) low spot\(report.lowSpots.count == 1 ? "" : "s") to fill") }
        let worst = "Worst gap \(MeasureFormat.height(report.worstGap, units: units)) vs \(tolerance) allowed."
        return parts.isEmpty ? worst : parts.joined(separator: ", ") + ". " + worst
    }
}

struct ReportStatsRows: View {
    let project: FloorProject
    let report: FlatnessReport

    private var units: UnitSystem { project.units }

    var body: some View {
        LabeledContent("Spec", value: report.spec.name)
        LabeledContent("Worst straightedge gap", value: MeasureFormat.height(report.worstGap, units: units))
        LabeledContent("Floor in spec", value: report.inSpecFraction.formatted(.percent.precision(.fractionLength(0))))
        LabeledContent("Highest point", value: MeasureFormat.height(report.highest, units: units, signed: true))
        LabeledContent("Lowest point", value: MeasureFormat.height(report.lowest, units: units, signed: true))
        LabeledContent("Out of level",
                       value: "\(MeasureFormat.height(report.slopeOverSpan, units: units)) per \(MeasureFormat.distance(report.spec.span, units: units))")
        LabeledContent("Area mapped", value: MeasureFormat.area(report.coveredArea, units: units))
        if report.grindVolume > 0 {
            LabeledContent("Grinding (est.)", value: MeasureFormat.volume(report.grindVolume, units: units))
        }
        if report.fillVolume > 0 {
            LabeledContent("Patch / leveler (est.)",
                           value: "\(MeasureFormat.volume(report.fillVolume, units: units)) · ~\(Analysis.bagEstimate(fillVolume: report.fillVolume)) bag(s)")
        }
    }
}

struct HotspotSections: View {
    let project: FloorProject
    let report: FlatnessReport
    var limit = 25

    var body: some View {
        if !report.highSpots.isEmpty {
            Section {
                ForEach(report.highSpots.prefix(limit)) { row($0) }
            } header: {
                Text("High spots · grind")
            } footer: {
                Text("Height above the floor's reference plane. Grind until a straightedge no longer rocks.")
            }
        }
        if !report.lowSpots.isEmpty {
            Section {
                ForEach(report.lowSpots.prefix(limit)) { row($0) }
            } header: {
                Text("Low spots · fill")
            } footer: {
                Text("Depth under the straightedge after the highs are ground. Fill with patch or self-leveler and feather out.")
            }
        }
    }

    private func row(_ spot: Hotspot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(spot.label)
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(spot.kind == .high ? .red : .blue)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(spot.kind == .high ? "+" : "−")\(MeasureFormat.height(spot.magnitude, units: project.units)) · \(MeasureFormat.area(spot.area, units: project.units))")
                    .font(.subheadline.monospacedDigit())
                Text(Analysis.locationText(x: spot.x - report.grid.originX, y: spot.y - report.grid.originY, project: project))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ProjectSettingsView: View {
    @State var project: FloorProject
    let onSave: (FloorProject) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $project.name)
                    Picker("Units", selection: $project.units) {
                        Text("Inches").tag(UnitSystem.imperial)
                        Text("Millimeters").tag(UnitSystem.metric)
                    }
                }
                Section {
                    SpecPicker(spec: $project.spec)
                    Picker("Compare against", selection: $project.reference) {
                        ForEach(ReferencePlane.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("LVP needs a flat floor, not a level one. Choose Level only if the floor must also be level.")
                }
                if project.manual != nil {
                    Section("Readings") {
                        Picker("Readings are", selection: Binding(
                            get: { project.manual!.readingMode },
                            set: { project.manual!.readingMode = $0 }
                        )) {
                            ForEach(ManualSurvey.ReadingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $project.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Floor settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(project)
                        dismiss()
                    }
                }
            }
        }
    }
}
