import ARKit
import SubfloorCore
import SwiftUI

struct ScanView: View {
    let units: UnitSystem
    let spec: FlatnessSpec
    let onFinish: ([SurveyPoint]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scanner = FloorScanner()

    var body: some View {
        ZStack {
            ARCameraView(session: scanner.session)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Text(scanner.guidance)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                Spacer()

                if let preview = scanner.preview {
                    VStack(alignment: .leading, spacing: 6) {
                        HeatmapView(report: preview, units: units, showsHotspots: false, interactive: false)
                            .frame(maxHeight: 200)
                        HStack {
                            Text("\(MeasureFormat.area(scanner.coveredArea, units: units)) covered")
                            Spacer()
                            Text("Worst gap \(MeasureFormat.height(preview.worstGap, units: units))")
                        }
                        .font(.caption.monospacedDigit())
                    }
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                HStack(spacing: 12) {
                    Button("Cancel", role: .cancel) {
                        scanner.stop()
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button(scanner.phase == .paused ? "Resume" : "Pause") {
                        scanner.setPaused(scanner.phase != .paused)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!scanner.foundFloor)

                    Button("Done") {
                        onFinish(scanner.finish())
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(scanner.sampleCount == 0)
                }
                .controlSize(.large)
            }
            .padding()
        }
        .onAppear {
            scanner.spec = spec
            scanner.start()
        }
        .onDisappear { scanner.stop() }
        .statusBarHidden()
    }
}

/// Live camera feed for the scan. The scanner owns the session; this view only shows it.
struct ARCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
