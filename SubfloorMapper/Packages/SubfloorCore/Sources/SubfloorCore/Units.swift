import Foundation

public enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case imperial
    case metric
}

public enum Length {
    public static let metersPerInch = 0.0254
    public static let metersPerFoot = 0.3048

    public static func inches(_ value: Double) -> Double { value * metersPerInch }
    public static func feet(_ value: Double) -> Double { value * metersPerFoot }
}

/// Formats values the way installers read them: fractional inches / feet-inches, or mm / m.
public enum MeasureFormat {
    /// Small vertical values (deviations, gaps). Imperial rounds to the nearest 1/16".
    public static func height(_ meters: Double, units: UnitSystem, signed: Bool = false) -> String {
        switch units {
        case .metric:
            let mm = (meters * 1000 * 10).rounded() / 10
            let body = String(format: "%.1f mm", abs(mm))
            guard signed, mm != 0 else { return body }
            return (mm > 0 ? "+" : "−") + body
        case .imperial:
            let sixteenths = Int((abs(meters) / Length.metersPerInch * 16).rounded())
            let body = fractionalInches(sixteenths: sixteenths)
            guard signed, sixteenths != 0 else { return body }
            return (meters > 0 ? "+" : "−") + body
        }
    }

    /// Horizontal distances (positions in the room). Imperial rounds to the nearest inch.
    public static func distance(_ meters: Double, units: UnitSystem) -> String {
        switch units {
        case .metric:
            return meters >= 1 ? String(format: "%.2f m", meters) : String(format: "%.0f cm", meters * 100)
        case .imperial:
            let totalInches = Int((meters / Length.metersPerInch).rounded())
            let feet = totalInches / 12
            let inches = totalInches % 12
            if feet == 0 { return "\(inches)\"" }
            return inches == 0 ? "\(feet)'" : "\(feet)' \(inches)\""
        }
    }

    public static func area(_ squareMeters: Double, units: UnitSystem) -> String {
        switch units {
        case .metric: return String(format: "%.2f m²", squareMeters)
        case .imperial: return String(format: "%.1f sq ft", squareMeters / (Length.metersPerFoot * Length.metersPerFoot))
        }
    }

    public static func volume(_ cubicMeters: Double, units: UnitSystem) -> String {
        switch units {
        case .metric: return String(format: "%.1f L", cubicMeters * 1000)
        case .imperial: return String(format: "%.2f cu ft", cubicMeters / pow(Length.metersPerFoot, 3))
        }
    }

    public static func fractionalInches(sixteenths: Int) -> String {
        let whole = sixteenths / 16
        var numerator = sixteenths % 16
        guard numerator != 0 else { return "\(whole)\"" }
        var denominator = 16
        while numerator % 2 == 0 {
            numerator /= 2
            denominator /= 2
        }
        return whole > 0 ? "\(whole) \(numerator)/\(denominator)\"" : "\(numerator)/\(denominator)\""
    }
}

/// Parses what people type on a job site: `1 3/16`, `1-3/16`, `3/16"`, `1.25` (inches) or `12,5` (mm).
public enum MeasureParser {
    /// Returns meters, or nil if the text isn't a number we understand.
    public static func height(_ text: String, units: UnitSystem) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces)
        var negative = false
        if let first = s.first, first == "-" || first == "−" {
            negative = true
            s.removeFirst()
        }
        let value: Double?
        switch units {
        case .metric:
            let cleaned = s.replacingOccurrences(of: "mm", with: "")
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespaces)
            value = Double(cleaned).map { $0 / 1000 }
        case .imperial:
            let cleaned = s.replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "″", with: "")
                .replacingOccurrences(of: "in", with: "")
            value = inches(cleaned).map(Length.inches)
        }
        guard let value else { return nil }
        return negative ? -value : value
    }

    static func inches(_ text: String) -> Double? {
        let parts = text.replacingOccurrences(of: "-", with: " ").split(separator: " ")
        guard !parts.isEmpty, parts.count <= 2 else { return nil }
        var total = 0.0
        for (offset, part) in parts.enumerated() {
            if part.contains("/") {
                let fraction = part.split(separator: "/")
                guard offset == parts.count - 1, fraction.count == 2,
                      let numerator = Double(fraction[0]), let denominator = Double(fraction[1]),
                      denominator != 0 else { return nil }
                total += numerator / denominator
            } else {
                guard offset == 0, let whole = Double(part) else { return nil }
                total += whole
            }
        }
        return total
    }
}
