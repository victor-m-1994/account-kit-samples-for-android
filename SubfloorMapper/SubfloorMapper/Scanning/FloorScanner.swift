import ARKit
import Observation
import SubfloorCore
import simd

/// Turns LiDAR depth frames into averaged floor heights.
///
/// Every frame, depth pixels that land on the floor are projected into world space (ARKit's Y
/// axis is aligned with gravity, so world Y is height) and binned into ~1" cells. A few seconds of
/// sweeping puts dozens to hundreds of samples in each cell, which averages out most per-pixel noise.
@Observable
final class FloorScanner: NSObject, ARSessionDelegate {
    enum Phase: Equatable {
        case findingFloor
        case scanning
        case paused
    }

    private(set) var phase: Phase = .findingFloor
    private(set) var guidance = "Point the camera at the floor and move slowly."
    private(set) var sampleCount = 0
    private(set) var coveredArea = 0.0
    /// Live analysis in raw world coordinates (x = world X, y = world Z), so it can be drawn on the floor.
    private(set) var preview: FlatnessReport?
    /// Bumps every time `preview` changes, so the AR overlay only rebuilds when it has to.
    private(set) var previewVersion = 0
    /// World height (Y) of the detected floor.
    private(set) var floorLevel: Float?
    var foundFloor: Bool { floorLevel != nil }

    @ObservationIgnored let session = ARSession()
    @ObservationIgnored var spec = FlatnessSpec.threeSixteenthsPerTenFeet

    // Everything below is only touched on `queue`.
    @ObservationIgnored private let queue = DispatchQueue(label: "SubfloorMapper.depth", qos: .userInitiated)
    @ObservationIgnored private var accumulator = PointAccumulator(binSize: Length.inches(1))
    @ObservationIgnored private var floorHeight: Float?
    @ObservationIgnored private var capturing = true
    @ObservationIgnored private var lastFrameTime: TimeInterval = 0
    @ObservationIgnored private var lastPreviewTime: TimeInterval = 0
    @ObservationIgnored private var previewInFlight = false

    /// Depth accuracy falls off with distance and at grazing angles, so only keep close, steep returns.
    private let maxRange: Float = 2.0
    private let minDownwardness: Float = 0.6
    /// Only points this close to the detected floor height count as floor (skips baseboards, furniture).
    private let floorBand: Float = 0.05

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    func start() {
        guard Self.isSupported else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.frameSemantics = [.sceneDepth]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        session.delegate = self
        session.delegateQueue = queue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        queue.async {
            self.accumulator.reset()
            self.floorHeight = nil
            self.capturing = true
        }
        phase = .findingFloor
        floorLevel = nil
        sampleCount = 0
        coveredArea = 0
        preview = nil
        previewVersion += 1
    }

    func setPaused(_ paused: Bool) {
        queue.async { self.capturing = !paused }
        phase = paused ? .paused : (foundFloor ? .scanning : .findingFloor)
    }

    func stop() {
        session.pause()
    }

    /// The finished survey, squared up to the room so walls run along the map edges.
    func finish() -> [SurveyPoint] {
        session.pause()
        let raw = queue.sync { accumulator.points() }
        return PointCloudAlignment.alignedToAxes(raw)
    }

    // MARK: ARSessionDelegate (called on `queue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ~6 frames a second is plenty and keeps the phone cool.
        guard frame.timestamp - lastFrameTime >= 0.15 else { return }
        lastFrameTime = frame.timestamp

        guard case .normal = frame.camera.trackingState else {
            publish(guidance: "Hold on — tracking is catching up. Move slowly over textured areas.")
            return
        }
        if floorHeight == nil {
            floorHeight = detectFloor(in: frame)
            guard floorHeight != nil else {
                publish(guidance: "Point the camera at the floor and move slowly.")
                return
            }
            let level = floorHeight
            DispatchQueue.main.async {
                self.floorLevel = level
                if self.phase == .findingFloor { self.phase = .scanning }
            }
        }
        guard capturing, let floorHeight else { return }

        let camera = frame.camera.transform
        let forward = -simd_make_float3(camera.columns.2)
        let cameraHeight = camera.columns.3.y - floorHeight
        let hint: String
        if forward.y > -0.5 {
            hint = "Tilt the phone down toward the floor."
        } else if cameraHeight > 1.5 {
            hint = "Lower the phone — about waist height works best."
        } else if cameraHeight < 0.4 {
            hint = "Raise the phone a little — about waist height works best."
        } else {
            hint = "Sweep slowly in overlapping passes. Watch the map fill in."
        }

        if let depth = frame.smoothedSceneDepth ?? frame.sceneDepth {
            integrate(depth, camera: frame.camera, floorHeight: floorHeight)
        }

        let count = accumulator.sampleCount
        let area = accumulator.coveredArea
        DispatchQueue.main.async {
            self.guidance = hint
            self.sampleCount = count
            self.coveredArea = area
        }

        if frame.timestamp - lastPreviewTime > 1.5, !previewInFlight {
            lastPreviewTime = frame.timestamp
            previewInFlight = true
            let points = accumulator.points()
            let spec = self.spec
            DispatchQueue.global(qos: .utility).async {
                let report = ElevationGrid.binning(points, cellSize: Length.inches(2), interpolationRadius: Length.inches(4))
                    .map { FlatnessAnalyzer.analyze($0, spec: spec, minimumHotspotCells: 3) }
                DispatchQueue.main.async {
                    self.preview = report
                    self.previewVersion += 1
                }
                self.queue.async { self.previewInFlight = false }
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        publish(guidance: "Scanning stopped: \(error.localizedDescription)")
    }

    private func publish(guidance: String) {
        DispatchQueue.main.async { self.guidance = guidance }
    }

    /// The lowest horizontal plane ARKit calls "floor", or failing classification, the lowest
    /// horizontal plane well below the phone.
    private func detectFloor(in frame: ARFrame) -> Float? {
        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }
        let floors = planes.filter { $0.classification == .floor }
        let cameraY = frame.camera.transform.columns.3.y
        let candidates = floors.isEmpty ? planes.filter { $0.transform.columns.3.y < cameraY - 0.4 } : floors
        return candidates.map { $0.transform.columns.3.y }.min()
    }

    private func integrate(_ depth: ARDepthData, camera: ARCamera, floorHeight: Float) {
        let depthMap = depth.depthMap
        guard let confidenceMap = depth.confidenceMap else { return }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap) else { return }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)

        // Intrinsics are for the full-size camera image; scale them to the depth map.
        let resolution = camera.imageResolution
        let sx = Float(width) / Float(resolution.width)
        let sy = Float(height) / Float(resolution.height)
        let k = camera.intrinsics
        let fx = k[0][0] * sx, fy = k[1][1] * sy
        let cx = k[2][0] * sx, cy = k[2][1] * sy
        let transform = camera.transform
        let origin = simd_make_float3(transform.columns.3)
        let high = UInt8(ARConfidenceLevel.high.rawValue)

        for v in stride(from: 0, to: height, by: 2) {
            let depthRow = (depthBase + v * depthRowBytes).assumingMemoryBound(to: Float32.self)
            let confidenceRow = (confidenceBase + v * confidenceRowBytes).assumingMemoryBound(to: UInt8.self)
            for u in stride(from: 0, to: width, by: 2) {
                guard confidenceRow[u] == high else { continue }
                let d = depthRow[u]
                guard d > 0.2, d < maxRange else { continue }
                // Camera space: +x right, +y up, looking down -z. Image rows run downward.
                let local = SIMD4<Float>((Float(u) - cx) * d / fx, -(Float(v) - cy) * d / fy, -d, 1)
                let world = simd_make_float3(transform * local)
                let h = world.y - floorHeight
                guard abs(h) < floorBand else { continue }
                let ray = simd_normalize(world - origin)
                guard -ray.y >= minDownwardness else { continue }
                accumulator.add(x: Double(world.x), y: Double(world.z), z: Double(h))
            }
        }
    }
}
