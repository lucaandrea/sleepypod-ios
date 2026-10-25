import Foundation

/// Independent native mesh construction; no SleepyPod iOS implementation is imported.
enum BedSceneGeometry {
    struct Point {
        var x: Double
        var y: Double
        var z: Double
    }
    enum Material { case frame, mattress, pillow, floor, wall }
    struct Face {
        var vertices: [Point]
        var material: Material
        var shade: Double
    }

    static func faces(head: Double, feet: Double) -> [Face] {
        var result = box(center: Point(x: 0, y: 0.04, z: 0), size: Point(x: 3.7, y: 0.06, z: 2.8), material: .floor)
        result += box(center: Point(x: 0, y: 0.34, z: 0), size: Point(x: 2.1, y: 0.17, z: 1.45), material: .frame)
        for length in [-0.82, 0.82] {
            for width in [-0.56, 0.56] {
                result += box(center: Point(x: length, y: 0.2, z: width), size: Point(x: 0.09, y: 0.32, z: 0.09), material: .frame)
            }
        }
        result += box(center: Point(x: -1.12, y: 0.6, z: 0), size: Point(x: 0.13, y: 1.05, z: 1.63), material: .frame)
        let headAngle = -min(60, max(0, head)) * .pi / 180
        let feetAngle = min(45, max(0, feet)) * .pi / 180
        let headHinge = Point(x: -0.24, y: 0.47, z: 0)
        let feetHinge = Point(x: 0.34, y: 0.47, z: 0)
        for width in [-0.355, 0.355] {
            result += rotated(box(center: Point(x: -0.65, y: 0.52, z: width), size: Point(x: 0.8, y: 0.18, z: 0.69), material: .mattress), around: headHinge, angle: headAngle)
            result += box(center: Point(x: 0.05, y: 0.52, z: width), size: Point(x: 0.56, y: 0.18, z: 0.69), material: .mattress)
            result += rotated(box(center: Point(x: 0.69, y: 0.52, z: width), size: Point(x: 0.69, y: 0.18, z: 0.69), material: .mattress), around: feetHinge, angle: feetAngle)
            result += rotated(box(center: Point(x: -0.84, y: 0.67, z: width), size: Point(x: 0.3, y: 0.12, z: 0.52), material: .pillow), around: headHinge, angle: headAngle)
        }
        for width in [-1.03, 1.03] {
            result += box(center: Point(x: -0.8, y: 0.25, z: width), size: Point(x: 0.42, y: 0.4, z: 0.35), material: .frame)
            result += box(center: Point(x: -0.8, y: 0.5, z: width), size: Point(x: 0.15, y: 0.12, z: 0.15), material: .pillow)
        }
        return result
    }

    private static func rotated(_ faces: [Face], around hinge: Point, angle: Double) -> [Face] {
        faces.map { face in
            var transformed = face
            transformed.vertices = face.vertices.map { point in
                let horizontal = point.x - hinge.x
                let vertical = point.y - hinge.y
                return Point(x: hinge.x + horizontal * cos(angle) - vertical * sin(angle),
                             y: hinge.y + horizontal * sin(angle) + vertical * cos(angle), z: point.z)
            }
            return transformed
        }
    }

    private static func box(center: Point, size: Point, material: Material) -> [Face] {
        var vertices: [Point] = []
        for horizontal in [-1.0, 1.0] {
            for vertical in [-1.0, 1.0] {
                for depth in [-1.0, 1.0] {
                    let point = Point(x: center.x + horizontal * size.x / 2,
                                      y: center.y + vertical * size.y / 2,
                                      z: center.z + depth * size.z / 2)
                    vertices.append(point)
                }
            }
        }
        let polygons = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
        let shades = [0.25, 0.12, 0.32, 0.0, 0.18, 0.1]
        return polygons.enumerated().map { index, polygon in
            Face(vertices: polygon.map { vertices[$0] }, material: material, shade: shades[index])
        }
    }
}
