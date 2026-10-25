import SceneKit
import SwiftUI

/// Four articulated panels per side match the web model's head, seat, knee and foot profile.
struct PositionBedScene: UIViewRepresentable {
    let head: Double
    let feet: Double
    let mattress: Bool
    var rightHead: Double? = nil
    var rightFeet: Double? = nil
    var cameraReset = 0

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 2; pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Rotatable bed model"
        view.accessibilityHint = "Drag horizontally to rotate, use two fingers to tilt, or pinch to zoom"
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Rotate left", target: context.coordinator, selector: #selector(Coordinator.rotateLeft)),
            UIAccessibilityCustomAction(name: "Rotate right", target: context.coordinator, selector: #selector(Coordinator.rotateRight)),
            UIAccessibilityCustomAction(name: "Zoom in", target: context.coordinator, selector: #selector(Coordinator.zoomIn)),
            UIAccessibilityCustomAction(name: "Zoom out", target: context.coordinator, selector: #selector(Coordinator.zoomOut)),
            UIAccessibilityCustomAction(name: "Reset view", target: context.coordinator, selector: #selector(Coordinator.resetView))
        ]
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(heads: [head, rightHead ?? head], feet: [feet, rightFeet ?? feet], mattress: mattress)
        if context.coordinator.resetToken != cameraReset {
            context.coordinator.resetToken = cameraReset
            context.coordinator.resetView()
        }
    }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let scene = SCNScene()
        let camera = SCNNode()
        var resetToken = 0
        private var yaw = 0.7
        private var pitch = 0.6
        private var zoom = 1.55
        private var headHinges: [SCNNode] = []
        private var kneeHinges: [SCNNode] = []
        private var footHinges: [SCNNode] = []
        private var mattresses: [SCNNode] = []

        override init() {
            super.init()
            camera.camera = SCNCamera()
            camera.camera?.usesOrthographicProjection = true
            scene.rootNode.addChildNode(camera)
            positionCamera()
            let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
            ambient.light?.intensity = 450; scene.rootNode.addChildNode(ambient)
            let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni
            light.light?.intensity = 900; light.position = SCNVector3(-2, 5, 3); scene.rootNode.addChildNode(light)
            let plinth = box(width: 1.88, height: 0.16, length: 1.92, shade: 0.17)
            plinth.position.y = 0.1; scene.rootNode.addChildNode(plinth)
            for horizontal in [-0.49, 0.49] {
                let seat = SCNNode(); seat.position = SCNVector3(horizontal, 0.3, 0)
                scene.rootNode.addChildNode(seat)
                segment(length: 0.36, depth: 0, parent: seat)
                let head = SCNNode(); head.position = SCNVector3(0, 0, -0.18)
                seat.addChildNode(head); headHinges.append(head)
                segment(length: 0.8, depth: -0.4, parent: head)
                let pillow = box(width: 0.55, height: 0.09, length: 0.25, shade: 0.82)
                pillow.position = SCNVector3(0, 0.28, -0.59); head.addChildNode(pillow); mattresses.append(pillow)
                let knee = SCNNode(); knee.position.z = 0.18
                seat.addChildNode(knee); kneeHinges.append(knee)
                segment(length: 0.36, depth: 0.18, parent: knee)
                let foot = SCNNode(); foot.position.z = 0.36
                knee.addChildNode(foot); footHinges.append(foot)
                segment(length: 0.56, depth: 0.28, parent: foot)
            }
        }
        func update(heads: [Double], feet: [Double], mattress: Bool) {
            for index in headHinges.indices {
                headHinges[index].eulerAngles.x = Float(heads[index] * .pi / 180)
                kneeHinges[index].eulerAngles.x = -Float(feet[index] * .pi / 180)
                // The knee rises while the hanging foot stays nearly level.
                footHinges[index].eulerAngles.x = Float(feet[index] * 1.25 * .pi / 180)
            }
            for cover in mattresses { cover.isHidden = !mattress }
        }
        private func segment(length: Double, depth: Double, parent: SCNNode) {
            let base = box(width: 0.96, height: 0.07, length: length - 0.008, shade: 0.28)
            base.position.z = Float(depth); parent.addChildNode(base)
            let cover = box(width: 0.95, height: 0.18, length: length - 0.01, shade: 0.62)
            cover.position.y = 0.125; base.addChildNode(cover); mattresses.append(cover)
        }
        private func box(width: Double, height: Double, length: Double, shade: CGFloat) -> SCNNode {
            let geometry = SCNBox(width: width, height: height, length: length, chamferRadius: min(0.035, height / 3))
            geometry.firstMaterial?.diffuse.contents = UIColor(white: shade, alpha: 1)
            geometry.firstMaterial?.roughness.contents = 0.9
            return SCNNode(geometry: geometry)
        }
        private func positionCamera() {
            camera.position = SCNVector3(sin(yaw) * cos(pitch) * 5, sin(pitch) * 5 + 0.45, cos(yaw) * cos(pitch) * 5)
            camera.look(at: SCNVector3(0, 0.45, 0))
            camera.camera?.orthographicScale = zoom
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.numberOfTouches < 2 else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let movement = gesture.translation(in: gesture.view)
            yaw -= Double(movement.x) * 0.009
            if gesture.numberOfTouches > 1 { pitch = min(1.3, max(0.15, pitch + Double(movement.y) * 0.006)) }
            gesture.setTranslation(.zero, in: gesture.view); positionCamera()
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            zoom = min(2.5, max(0.9, zoom / Double(gesture.scale))); gesture.scale = 1; positionCamera()
        }
        @objc @discardableResult func resetView() -> Bool { yaw = 0.7; pitch = 0.6; zoom = 1.55; positionCamera(); return true }
        @objc func rotateLeft() -> Bool { yaw -= .pi / 8; positionCamera(); return true }
        @objc func rotateRight() -> Bool { yaw += .pi / 8; positionCamera(); return true }
        @objc func zoomIn() -> Bool { zoom = max(0.9, zoom - 0.2); positionCamera(); return true }
        @objc func zoomOut() -> Bool { zoom = min(2.5, zoom + 0.2); positionCamera(); return true }
    }
}
