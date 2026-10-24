import CoreTransferable
import SubfloorCore
import SwiftUI
import UniformTypeIdentifiers

/// A shareable PDF, rendered only when the user actually shares it.
struct FloorReportFile: Transferable {
    let project: FloorProject
    let report: FlatnessReport

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { file in
            let url = try await MainActor.run { try ReportExporter.pdf(project: file.project, report: file.report) }
            return SentTransferredFile(url)
        }
    }
}

enum ReportExporter {
    struct RenderError: Error {}

    @MainActor
    static func pdf(project: FloorProject, report: FlatnessReport) throws -> URL {
        let pageWidth: CGFloat = 612 // US Letter width in points
        let renderer = ImageRenderer(content:
            ReportPage(project: project, report: report)
                .frame(width: pageWidth)
                .environment(\.colorScheme, .light)
        )
        renderer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)

        let safeName = project.name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName.isEmpty ? "Floor" : safeName)-report.pdf")
        var rendered = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            rendered = true
        }
        guard rendered else { throw RenderError() }
        return url
    }
}

/// The printable report: verdict, both maps, numbers and the punch list.
struct ReportPage: View {
    let project: FloorProject
    let report: FlatnessReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.largeTitle.bold())
                Text("\(project.method.title) · \(Date().formatted(date: .long, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            VerdictView(report: report, units: project.units)

            HStack(alignment: .top, spacing: 16) {
                map(.heights)
                map(.actions)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Measurements").font(.headline)
                ReportStatsRows(project: project, report: report)
            }
            .font(.subheadline)

            punchList(title: "High spots · grind", spots: report.highSpots)
            punchList(title: "Low spots · fill", spots: report.lowSpots)

            if !project.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.headline)
                    Text(project.notes)
                }
            }

            Text("Positions are measured from the top-left corner of the map\(project.method == .manual ? " (point A1)" : ""). Volumes are estimates. \(project.method == .lidar ? "LiDAR readings are approximate; confirm borderline areas with a straightedge." : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .background(.white)
    }

    private func map(_ layer: MapLayer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(layer.rawValue).font(.headline)
            HeatmapView(report: report, units: project.units, layer: layer, interactive: false)
            HeatmapLegend(report: report, units: project.units, layer: layer)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func punchList(title: String, spots: [Hotspot]) -> some View {
        if !spots.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                ForEach(spots.prefix(20)) { spot in
                    HStack(alignment: .firstTextBaseline) {
                        Text(spot.label).bold().frame(width: 34, alignment: .leading)
                        Text("\(spot.kind == .high ? "+" : "−")\(MeasureFormat.height(spot.magnitude, units: project.units))")
                            .frame(width: 70, alignment: .leading)
                        Text(Analysis.locationText(x: spot.x - report.grid.originX, y: spot.y - report.grid.originY, project: project))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline.monospacedDigit())
                }
                if spots.count > 20 {
                    Text("+ \(spots.count - 20) smaller").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
