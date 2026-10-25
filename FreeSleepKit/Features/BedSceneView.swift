import SwiftUI

struct BedSceneView: View {
    let head: Double
    let feet: Double
    @Environment(\.colorScheme) private var scheme
    @State private var rotation = -0.65
    @GestureState private var drag = 0.0

    var body: some View {
        Canvas { context, size in
            let azimuth = min(-0.2, max(-1.1, rotation + drag))
            let scale = min(size.width / 3.7, size.height / 2.6)
            let elevation = 0.62
            let faces = BedSceneGeometry.faces(head: head, feet: feet)
            func depth(_ point: BedSceneGeometry.Point) -> Double {
                (sin(azimuth) * point.x + cos(azimuth) * point.z) * cos(elevation) - point.y * sin(elevation)
            }
            func project(_ point: BedSceneGeometry.Point) -> CGPoint {
                CGPoint(x: size.width / 2 + (cos(azimuth) * point.x - sin(azimuth) * point.z) * scale,
                        y: size.height * 0.61 + ((sin(azimuth) * point.x + cos(azimuth) * point.z) * sin(elevation) - point.y * cos(elevation)) * scale)
            }
            // Draw supporting layers first: a large floor or frame face must not
            // cover smaller mattress faces merely because its center is nearer.
            let ordered = faces.sorted {
                if layer($0.material) != layer($1.material) { return layer($0.material) < layer($1.material) }
                return $0.vertices.map(depth).reduce(0, +) > $1.vertices.map(depth).reduce(0, +)
            }
            for face in ordered where visible(face, azimuth: azimuth, elevation: elevation) {
                var path = Path()
                path.addLines(face.vertices.map(project))
                path.closeSubpath()
                context.fill(path, with: .color(color(face.material)))
                context.fill(path, with: .color(.black.opacity(face.shade)))
                context.stroke(path, with: .color(SleepTheme.border(scheme).opacity(0.35)), lineWidth: 0.5)
            }
        }
        .frame(height: 250)
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 12)
            .updating($drag) { value, state, _ in
                if abs(value.translation.width) > abs(value.translation.height) { state = value.translation.width / 220 }
            }
            .onEnded { value in
                if abs(value.translation.width) > abs(value.translation.height) {
                    rotation = min(-0.2, max(-1.1, rotation + value.translation.width / 220))
                }
            })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bed position preview")
        .accessibilityValue("Head \(Int(head)) degrees, feet \(Int(feet)) degrees. This is a preview, not confirmation of movement.")
    }

    private func layer(_ material: BedSceneGeometry.Material) -> Int {
        switch material {
        case .floor: 0
        case .wall: 1
        case .frame: 2
        case .mattress: 3
        case .pillow: 4
        }
    }

    /// Back-face culling keeps hidden box bottoms from painting over their tops.
    private func visible(_ face: BedSceneGeometry.Face, azimuth: Double, elevation: Double) -> Bool {
        let origin = face.vertices[0]
        let first = face.vertices[1]
        let second = face.vertices[2]
        let firstEdge = (x: first.x - origin.x, y: first.y - origin.y, z: first.z - origin.z)
        let secondEdge = (x: second.x - origin.x, y: second.y - origin.y, z: second.z - origin.z)
        let normal = (x: firstEdge.y * secondEdge.z - firstEdge.z * secondEdge.y,
                      y: firstEdge.z * secondEdge.x - firstEdge.x * secondEdge.z,
                      z: firstEdge.x * secondEdge.y - firstEdge.y * secondEdge.x)
        return normal.x * -sin(azimuth) * cos(elevation) + normal.y * sin(elevation)
            - normal.z * cos(azimuth) * cos(elevation) > 0
    }

    private func color(_ material: BedSceneGeometry.Material) -> Color {
        switch material {
        case .frame: scheme == .dark ? Color(red: 0.25, green: 0.3, blue: 0.38) : Color(red: 0.55, green: 0.58, blue: 0.63)
        case .mattress: scheme == .dark ? Color(red: 0.7, green: 0.77, blue: 0.83) : Color(red: 0.88, green: 0.91, blue: 0.94)
        case .pillow: Color(red: 0.96, green: 0.92, blue: 0.85)
        case .floor: scheme == .dark ? Color(red: 0.13, green: 0.17, blue: 0.23) : Color(red: 0.9, green: 0.88, blue: 0.84)
        case .wall: SleepTheme.canvas(scheme)
        }
    }
}
