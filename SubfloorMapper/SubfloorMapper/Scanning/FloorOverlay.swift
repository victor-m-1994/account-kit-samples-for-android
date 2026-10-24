import ARKit
import SceneKit
import SubfloorCore
import SwiftUI

/// Paints the live flatness map onto the real floor in the camera view, with a pin on each
/// high and low spot, so problem areas can be found and chalk-marked right where they are.
final class FloorOverlay {
    let root = SCNNode()
    private let surface = SCNNode()
    private let pins = SCNNode()
    private var renderedVersion = -1
    private var renderedLayer: MapLayer?

    init() {
        root.addChildNode(surface)
        root.addChildNode(pins)
    }

    func update(report: FlatnessReport?, version: Int, floorLevel: Float?, layer: MapLayer?, units: UnitSystem) {
        guard let layer, let report, let floorLevel else {
            root.isHidden = true
            return
        }
        root.isHidden = false
        guard version != renderedVersion || layer != renderedLayer else { return }
        renderedVersion = version
        renderedLayer = layer

        let grid = report.grid
        // The preview grid is in world coordinates: grid x = world X, grid y = world Z.
        root.simdPosition = SIMD3<Float>(0, floorLevel + 0.002, 0)

        if let image = HeatmapRenderer.image(for: report, layer: layer) {
            let plane = SCNPlane(width: grid.width, height: grid.length)
            let material = SCNMaterial()
            material.diffuse.contents = image
            material.diffuse.magnificationFilter = .linear
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.transparency = 0.6
            material.writesToDepthBuffer = false
            plane.materials = [material]
            surface.geometry = plane
            // SCNPlane stands in local XY; lay it flat so image row 0 points toward world -Z.
            surface.simdEulerAngles = SIMD3<Float>(-.pi / 2, 0, 0)
            surface.simdPosition = SIMD3<Float>(
                Float(grid.originX - grid.cellSize / 2 + grid.width / 2),
                0,
                Float(grid.originY - grid.cellSize / 2 + grid.length / 2)
            )
        }

        pins.childNodes.forEach { $0.removeFromParentNode() }
        for spot in report.highSpots.prefix(6) + report.lowSpots.prefix(6) {
            pins.addChildNode(pin(for: spot, units: units))
        }
    }

    private func pin(for spot: Hotspot, units: UnitSystem) -> SCNNode {
        let color: UIColor = spot.kind == .high ? .systemRed : .systemBlue
        let node = SCNNode()
        node.simdPosition = SIMD3<Float>(Float(spot.x), 0, Float(spot.y))

        let stem = SCNCylinder(radius: 0.006, height: 0.12)
        stem.firstMaterial?.diffuse.contents = color
        stem.firstMaterial?.lightingModel = .constant
        let stemNode = SCNNode(geometry: stem)
        stemNode.simdPosition = SIMD3<Float>(0, 0.06, 0)
        node.addChildNode(stemNode)

        let ring = SCNTorus(ringRadius: 0.05, pipeRadius: 0.005)
        ring.firstMaterial?.diffuse.contents = color
        ring.firstMaterial?.lightingModel = .constant
        node.addChildNode(SCNNode(geometry: ring))

        let sign = spot.kind == .high ? "+" : "−"
        let text = SCNText(string: "\(spot.label) \(sign)\(MeasureFormat.height(spot.magnitude, units: units))", extrusionDepth: 0)
        text.font = UIFont.systemFont(ofSize: 10, weight: .bold)
        text.flatness = 0.2
        text.firstMaterial?.diffuse.contents = color
        text.firstMaterial?.lightingModel = .constant
        text.firstMaterial?.isDoubleSided = true
        let label = SCNNode(geometry: text)
        let (minBound, maxBound) = text.boundingBox
        label.pivot = SCNMatrix4MakeTranslation((maxBound.x - minBound.x) / 2 + minBound.x, minBound.y, 0)
        label.scale = SCNVector3(0.004, 0.004, 0.004)
        label.simdPosition = SIMD3<Float>(0, 0.14, 0)
        // Keep labels facing the camera as you walk around.
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        label.constraints = [billboard]

        // White backing so the label reads over any floor.
        let backing = SCNPlane(width: CGFloat(maxBound.x - minBound.x) + 6, height: CGFloat(maxBound.y - minBound.y) + 4)
        backing.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(0.85)
        backing.firstMaterial?.lightingModel = .constant
        backing.firstMaterial?.isDoubleSided = true
        let backingNode = SCNNode(geometry: backing)
        backingNode.simdPosition = SIMD3<Float>(
            (maxBound.x - minBound.x) / 2 + minBound.x, (maxBound.y - minBound.y) / 2 + minBound.y, -0.5)
        label.addChildNode(backingNode)
        node.addChildNode(label)
        return node
    }
}

/// Live camera feed for the scan, with the flatness map drawn on the floor.
struct ARCameraView: UIViewRepresentable {
    let session: ARSession
    let report: FlatnessReport?
    let version: Int
    let floorLevel: Float?
    /// nil hides the overlay.
    let layer: MapLayer?
    let units: UnitSystem

    func makeCoordinator() -> FloorOverlay { FloorOverlay() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        view.scene.rootNode.addChildNode(context.coordinator.root)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.update(report: report, version: version, floorLevel: floorLevel, layer: layer, units: units)
    }
}
