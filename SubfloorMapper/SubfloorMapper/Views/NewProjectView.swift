import SubfloorCore
import SwiftUI

struct NewProjectView: View {
    let method: SurveyMethod
    let onCreate: (FloorProject) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var units: UnitSystem = Locale.current.measurementSystem == .metric ? .metric : .imperial
    @State private var spec = FlatnessSpec.threeSixteenthsPerTenFeet
    @State private var width = Length.feet(12)
    @State private var length = Length.feet(14)
    @State private var spacing = Length.feet(2)
    @State private var readingMode = ManualSurvey.ReadingMode.distanceToLaser

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Smith kitchen)", text: $name)
                    Picker("Units", selection: $units) {
                        Text("Inches").tag(UnitSystem.imperial)
                        Text("Millimeters").tag(UnitSystem.metric)
                    }
                }
                Section {
                    SpecPicker(spec: $spec)
                } footer: {
                    Text("Use the flatness spec from your flooring's installation guide. 3/16\" in 10' is the most common for LVP.")
                }
                if method == .manual {
                    Section {
                        LengthField(title: "Room width", meters: $width, units: units)
                        LengthField(title: "Room length", meters: $length, units: units)
                        LengthField(title: "Grid spacing", meters: $spacing, units: units)
                        Picker("Readings", selection: $readingMode) {
                            ForEach(ManualSurvey.ReadingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } header: {
                        Text("Grid")
                    } footer: {
                        Text(gridSummary)
                    }
                } else {
                    Section {
                        Label("Clear the floor and sweep up debris.", systemImage: "1.circle")
                        Label("Hold the phone about waist height, pointed down.", systemImage: "2.circle")
                        Label("Walk slowly in overlapping passes until the map fills in.", systemImage: "3.circle")
                    } header: {
                        Text("Scanning")
                    } footer: {
                        Text("LiDAR finds problem areas fast but isn't survey-grade. Confirm anything borderline with a straightedge.")
                    }
                }
            }
            .navigationTitle(method.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create).disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        method == .lidar || (width > 0 && length > 0 && spacing >= 0.15 && spacing <= min(width, length))
    }

    private var gridSummary: String {
        guard isValid else { return "Spacing must be at least 6\" (15 cm) and smaller than the room." }
        let survey = ManualSurvey(width: width, length: length, spacing: spacing)
        return "\(survey.columns) × \(survey.rows) grid = \(survey.nodeCount) readings."
    }

    private func create() {
        var project = FloorProject(
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Floor \(Date().formatted(date: .abbreviated, time: .omitted))" : name,
            method: method,
            units: units,
            spec: spec
        )
        if method == .manual {
            project.manual = ManualSurvey(width: width, length: length, spacing: spacing, readingMode: readingMode)
        }
        onCreate(project)
        dismiss()
    }
}

struct SpecPicker: View {
    @Binding var spec: FlatnessSpec

    var body: some View {
        Picker("Flatness spec", selection: $spec) {
            ForEach(FlatnessSpec.presets, id: \.self) { Text($0.name).tag($0) }
        }
    }
}

/// Feet + inches, or meters, editing a value stored in meters.
struct LengthField: View {
    let title: String
    @Binding var meters: Double
    let units: UnitSystem

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            switch units {
            case .imperial:
                TextField("ft", value: feet, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 50)
                Text("ft").foregroundStyle(.secondary)
                TextField("in", value: inches, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                Text("in").foregroundStyle(.secondary)
            case .metric:
                TextField("m", value: $meters, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("m").foregroundStyle(.secondary)
            }
        }
    }

    private var totalInches: Double { (meters / Length.metersPerInch).rounded() }

    private var feet: Binding<Int> {
        Binding(
            get: { Int(totalInches) / 12 },
            set: { meters = Length.inches(Double($0 * 12) + totalInches.truncatingRemainder(dividingBy: 12)) }
        )
    }

    private var inches: Binding<Int> {
        Binding(
            get: { Int(totalInches) % 12 },
            set: { meters = Length.inches(Double(Int(totalInches) / 12 * 12 + $0)) }
        )
    }
}
