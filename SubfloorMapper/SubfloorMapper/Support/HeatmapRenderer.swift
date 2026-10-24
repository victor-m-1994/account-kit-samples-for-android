import CoreGraphics
import SwiftUI
import SubfloorCore

enum MapLayer: String, CaseIterable, Identifiable {
    case heights = "Highs & lows"
    case actions = "Grind / fill"

    var id: String { rawValue }
}

/// Colors and the bitmap behind the map. One pixel per grid cell; SwiftUI scales it up.
enum HeatmapRenderer {
    /// Color scale saturates at ±1.5× the tolerance so the same color means the same thing on every floor.
    static func range(for spec: FlatnessSpec) -> Double { spec.tolerance * 1.5 }

    private static let stops: [(t: Double, rgb: (Double, Double, Double))] = [
        (-1.0, (0.13, 0.25, 0.80)), // deep low: blue
        (-0.5, (0.20, 0.65, 0.95)), // low: sky
        (0.0, (0.30, 0.78, 0.42)),  // flat: green
        (0.5, (0.98, 0.83, 0.25)),  // high: yellow
        (1.0, (0.88, 0.20, 0.18)),  // very high: red
    ]

    static func rgb(deviation: Double, range: Double) -> (Double, Double, Double) {
        let t = max(-1, min(1, deviation / range))
        for k in 1..<stops.count where t <= stops[k].t {
            let (a, b) = (stops[k - 1], stops[k])
            let f = (t - a.t) / (b.t - a.t)
            return (a.rgb.0 + (b.rgb.0 - a.rgb.0) * f,
                    a.rgb.1 + (b.rgb.1 - a.rgb.1) * f,
                    a.rgb.2 + (b.rgb.2 - a.rgb.2) * f)
        }
        return stops[stops.count - 1].rgb
    }

    static func color(deviation: Double, range: Double) -> Color {
        let c = rgb(deviation: deviation, range: range)
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    static let gradient = Gradient(colors: stops.map { Color(red: $0.rgb.0, green: $0.rgb.1, blue: $0.rgb.2) })

    static func rgb(for condition: CellCondition) -> (Double, Double, Double)? {
        switch condition {
        case .noData: nil
        case .ok: (0.80, 0.92, 0.82)
        case .grind: (0.88, 0.20, 0.18)
        case .fill: (0.13, 0.35, 0.85)
        case .clearsAfterGrind: (0.98, 0.78, 0.35)
        }
    }

    static func color(for condition: CellCondition) -> Color {
        guard let c = rgb(for: condition) else { return .clear }
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    static func image(for report: FlatnessReport, layer: MapLayer) -> CGImage? {
        let grid = report.grid
        let range = Self.range(for: report.spec)
        var pixels = [UInt8](repeating: 0, count: grid.cellCount * 4)
        for i in 0..<grid.cellCount {
            let rgb: (Double, Double, Double)?
            switch layer {
            case .heights: rgb = report.deviation[i].map { self.rgb(deviation: $0, range: range) }
            case .actions: rgb = self.rgb(for: report.condition[i])
            }
            guard let rgb else { continue } // transparent where there's no floor data
            pixels[i * 4] = UInt8(rgb.0 * 255)
            pixels[i * 4 + 1] = UInt8(rgb.1 * 255)
            pixels[i * 4 + 2] = UInt8(rgb.2 * 255)
            pixels[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: grid.columns, height: grid.rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: grid.columns * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
