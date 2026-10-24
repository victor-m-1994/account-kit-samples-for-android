import SwiftUI
import SubfloorCore

/// The floor map: colored cells with labeled hot spots. Tap anywhere to read that spot.
struct HeatmapView: View {
    let report: FlatnessReport
    let units: UnitSystem
    var layer: MapLayer = .heights
    var showsHotspots = true
    var interactive = true
    /// Manual surveys show where readings were actually taken.
    var nodes: [(x: Double, y: Double)] = []

    @State private var selected: Int?

    private var grid: ElevationGrid { report.grid }

    var body: some View {
        let image = HeatmapRenderer.image(for: report, layer: layer)
        GeometryReader { proxy in
            let scale = proxy.size.width / grid.width
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                }
                Canvas { context, _ in
                    for node in nodes {
                        let p = point(x: node.x, y: node.y, scale: scale)
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                                     with: .color(.black.opacity(0.45)))
                    }
                    if showsHotspots {
                        for spot in report.highSpots.prefix(9) + report.lowSpots.prefix(9) {
                            draw(spot, in: &context, scale: scale)
                        }
                    }
                    if let selected {
                        let c = grid.center(of: selected)
                        let p = point(x: c.x, y: c.y, scale: scale)
                        context.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                                       with: .color(.white), lineWidth: 3)
                        context.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                                       with: .color(.black), lineWidth: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard interactive else { return }
                let x = grid.originX + location.x / scale - grid.cellSize / 2
                let y = grid.originY + location.y / scale - grid.cellSize / 2
                let index = grid.index(atX: x, y: y)
                selected = (index.flatMap { report.deviation[$0] } != nil) ? index : nil
            }
            .overlay(alignment: .bottom) {
                if let selected, interactive {
                    readout(for: selected).padding(8)
                }
            }
        }
        .aspectRatio(grid.width / grid.length, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: report.grid.cellCount) { selected = nil }
    }

    private func point(x: Double, y: Double, scale: Double) -> CGPoint {
        CGPoint(x: (x - grid.originX + grid.cellSize / 2) * scale, y: (y - grid.originY + grid.cellSize / 2) * scale)
    }

    private func draw(_ spot: Hotspot, in context: inout GraphicsContext, scale: Double) {
        let p = point(x: spot.x, y: spot.y, scale: scale)
        let tint: Color = spot.kind == .high ? .red : .blue
        let rect = CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26)
        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)))
        context.stroke(Path(ellipseIn: rect), with: .color(tint), lineWidth: 2)
        context.draw(Text(spot.label).font(.system(size: 11, weight: .bold)).foregroundColor(tint), at: p)
    }

    private func readout(for index: Int) -> some View {
        let deviation = report.deviation[index] ?? 0
        let c = grid.center(of: index)
        return VStack(alignment: .leading, spacing: 2) {
            Text(deviation >= 0 ? "High" : "Low") + Text(" \(MeasureFormat.height(deviation, units: units, signed: true))").bold()
            Text("Straightedge gap \(MeasureFormat.height(report.straightedgeGap[index], units: units))")
            Text("\(MeasureFormat.distance(c.x - grid.originX, units: units)) across, \(MeasureFormat.distance(c.y - grid.originY, units: units)) down")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct HeatmapLegend: View {
    let report: FlatnessReport
    let units: UnitSystem
    let layer: MapLayer

    var body: some View {
        switch layer {
        case .heights:
            let range = HeatmapRenderer.range(for: report.spec)
            VStack(spacing: 4) {
                LinearGradient(gradient: HeatmapRenderer.gradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 10)
                    .clipShape(Capsule())
                HStack {
                    Text("Low \(MeasureFormat.height(-range, units: units, signed: true))")
                    Spacer()
                    Text("Flat")
                    Spacer()
                    Text("High \(MeasureFormat.height(range, units: units, signed: true))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        case .actions:
            HStack(spacing: 12) {
                swatch(.grind, "Grind")
                swatch(.fill, "Fill")
                swatch(.clearsAfterGrind, "OK after grind")
                swatch(.ok, "In spec")
            }
            .font(.caption2)
        }
    }

    private func swatch(_ condition: CellCondition, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(HeatmapRenderer.color(for: condition)).frame(width: 10, height: 10)
            Text(title)
        }
    }
}
