import SubfloorCore
import SwiftUI

/// Walk the chalked grid with a laser and tape, entering one reading per node.
struct ManualEntryView: View {
    @State var survey: ManualSurvey
    let units: UnitSystem
    let onChange: (ManualSurvey) -> Void

    @State private var current: Int?
    @State private var text = ""
    @State private var showsHelp = false
    @FocusState private var fieldFocused: Bool

    private let nodePitch: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                gridView.padding(20)
            }
            .background(Color(.secondarySystemBackground))

            entryPanel
        }
        .navigationTitle("Readings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsHelp = true } label: { Image(systemName: "questionmark.circle") }
            }
        }
        .sheet(isPresented: $showsHelp) { ManualHelpView(survey: survey, units: units) }
        .onAppear {
            if current == nil { select(survey.nextPending(after: nil) ?? 0) }
        }
    }

    private var gridView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 28, height: 20)
                ForEach(0..<survey.columns, id: \.self) { column in
                    Text(ManualSurvey.columnLetters(column))
                        .font(.caption2.bold())
                        .frame(width: nodePitch)
                }
            }
            ForEach(0..<survey.rows, id: \.self) { row in
                HStack(spacing: 0) {
                    Text("\(row + 1)")
                        .font(.caption2.bold())
                        .frame(width: 28)
                    ForEach(0..<survey.columns, id: \.self) { column in
                        nodeButton(survey.index(column: column, row: row))
                    }
                }
            }
        }
    }

    private func nodeButton(_ index: Int) -> some View {
        let reading = survey.readings[index]
        let isSkipped = survey.skipped.contains(index)
        let isCurrent = current == index
        return Button { select(index) } label: {
            VStack(spacing: 1) {
                Circle()
                    .fill(reading != nil ? Color.green : isSkipped ? Color.gray.opacity(0.4) : Color.orange.opacity(0.25))
                    .overlay(Circle().stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 3))
                    .frame(width: 18, height: 18)
                Text(reading.map { MeasureFormat.height($0, units: units, signed: $0 < 0) } ??(isSkipped ? "skip" : " "))
                    .font(.system(size: 9).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: nodePitch, height: nodePitch)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Point \(survey.label(of: index))")
    }

    private var entryPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Text(current.map { "Point \(survey.label(of: $0))" } ?? "All points done")
                    .font(.title3.bold())
                Spacer()
                Text("\(survey.completedCount)/\(survey.nodeCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if current != nil {
                HStack {
                    TextField(units == .imperial ? "e.g. 1 3/16" : "e.g. 32.5", text: $text)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3.monospacedDigit())
                        .focused($fieldFocused)
                        .submitLabel(.next)
                        .onSubmit(commit)
                    Text(units == .imperial ? "in" : "mm").foregroundStyle(.secondary)
                }
                if !text.isEmpty, MeasureParser.height(text, units: units) == nil {
                    Text(units == .imperial ? "Try 1 3/16, 1-3/16 or 1.1875" : "Enter millimeters, e.g. 32.5")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Skip (obstacle)") { skipCurrent() }
                        .buttonStyle(.bordered)
                    if let current, survey.readings[current] != nil {
                        Button("Clear", role: .destructive) { clearCurrent() }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button("Save & next", action: commit)
                        .buttonStyle(.borderedProminent)
                        .disabled(MeasureParser.height(text, units: units) == nil)
                }
            }
            Text(survey.readingMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.bar)
    }

    private func select(_ index: Int) {
        current = index
        text = survey.readings[index].map(editableText) ?? ""
        fieldFocused = true
    }

    /// A stored reading in the same form the field accepts, so editing round-trips.
    private func editableText(_ value: Double) -> String {
        switch units {
        case .imperial:
            MeasureFormat.height(value, units: .imperial, signed: value < 0).replacingOccurrences(of: "\"", with: "")
        case .metric:
            String(format: "%.1f", value * 1000)
        }
    }

    private func commit() {
        guard let current, let value = MeasureParser.height(text, units: units) else { return }
        survey.record(value, at: current)
        onChange(survey)
        advance(from: current)
    }

    private func skipCurrent() {
        guard let current else { return }
        survey.skip(current)
        onChange(survey)
        advance(from: current)
    }

    private func clearCurrent() {
        guard let current else { return }
        survey.record(nil, at: current)
        onChange(survey)
        text = ""
    }

    private func advance(from index: Int) {
        if let next = survey.nextPending(after: index) {
            select(next)
        } else {
            current = nil
            text = ""
            fieldFocused = false
        }
    }
}

struct ManualHelpView: View {
    let survey: ManualSurvey
    let units: UnitSystem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Set up") {
                    Label("Pick a starting corner. That's point A1, the top-left of the map.", systemImage: "1.circle")
                    Label("Chalk a grid every \(MeasureFormat.distance(survey.spacing, units: units)) — columns A, B, C… across, rows 1, 2, 3… down the room.", systemImage: "2.circle")
                    Label("Set a rotating or self-leveling line laser so its line hits a tape or rod held on the floor anywhere in the room.", systemImage: "3.circle")
                }
                Section("Measure") {
                    Label("At each point, stand the tape on the floor and read where the laser crosses it.", systemImage: "ruler")
                    Label("Points under cabinets, toilets or vents: tap Skip.", systemImage: "forward")
                    Label("The order snakes back and forth, so the next point is always one step away.", systemImage: "arrow.triangle.turn.up.right.diamond")
                }
                Section("Tips") {
                    Text("Don't move or bump the laser once you start — every reading is relative to it.")
                    Text("Tighter spacing finds smaller dips. 2' (60 cm) is a good default; use 1' (30 cm) for problem areas.")
                }
            }
            .navigationTitle("How to take readings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
