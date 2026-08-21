import XCTest
import SceneKit
@testable import MVR_Exploder

/// A fixture's `<Matrix>` carries its rotation as well as its position, and
/// the 3D view used to keep only the position — so a light hung upside down
/// under a truss drew the right way up.
final class FixtureOrientationTests: XCTestCase {

    /// MVR matrix text: three basis rows, then the translation.
    private func matrix(
        _ basis: [Double], translation: (Double, Double, Double) = (0, 0, 0)
    ) -> String {
        let rows = stride(from: 0, to: 9, by: 3)
            .map { "{\(basis[$0]),\(basis[$0 + 1]),\(basis[$0 + 2])}" }
            .joined()
        return rows + "{\(translation.0),\(translation.1),\(translation.2)}"
    }

    private func apply(_ transform: SCNMatrix4, to v: SCNVector3) -> SCNVector3 {
        SCNVector3(
            v.x * transform.m11 + v.y * transform.m21 + v.z * transform.m31,
            v.x * transform.m12 + v.y * transform.m22 + v.z * transform.m32,
            v.x * transform.m13 + v.y * transform.m23 + v.z * transform.m33)
    }

    private func assertVector(
        _ got: SCNVector3, _ want: (Double, Double, Double),
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(Double(got.x), want.0, accuracy: 0.0001, message, file: file, line: line)
        XCTAssertEqual(Double(got.y), want.1, accuracy: 0.0001, message, file: file, line: line)
        XCTAssertEqual(Double(got.z), want.2, accuracy: 0.0001, message, file: file, line: line)
    }

    func testAnUnrotatedFixtureIsLeftAlone() throws {
        let identity = matrix([1, 0, 0, 0, 1, 0, 0, 0, 1], translation: (1000, 2000, 3000))
        let orientation = try XCTUnwrap(
            MVRSceneGeometryLoader.orientation(fromMatrixText: identity))

        // Whatever the fixture points at, it still points at.
        assertVector(apply(orientation, to: SCNVector3(0, 1, 0)), (0, 1, 0))
        assertVector(apply(orientation, to: SCNVector3(1, 0, 0)), (1, 0, 0))
    }

    /// The case that matters: hung upside down. In MVR, Z is up, so a
    /// fixture flipped about X has its local Z pointing at −Z. In the
    /// viewer, Y is up, so it must come out pointing at −Y.
    func testAFixtureHungUpsideDownPointsDown() throws {
        let flipped = matrix([1, 0, 0, 0, -1, 0, 0, 0, -1])
        let orientation = try XCTUnwrap(
            MVRSceneGeometryLoader.orientation(fromMatrixText: flipped))

        // The fixture's local up (scene Y) ends up pointing down.
        assertVector(apply(orientation, to: SCNVector3(0, 1, 0)), (0, -1, 0),
                     "an upside-down fixture must render upside down")
        assertVector(apply(orientation, to: SCNVector3(1, 0, 0)), (1, 0, 0),
                     "and not be spun about its own axis on the way")
    }

    /// Rotation about the MVR up-axis — a fixture panned on a truss — has
    /// to come out as rotation about the *scene's* up-axis, not tipped into
    /// another plane by the Z-up to Y-up change of basis.
    func testAPannedFixtureStaysLevel() throws {
        // 90° about MVR Z.
        let panned = matrix([0, 1, 0, -1, 0, 0, 0, 0, 1])
        let orientation = try XCTUnwrap(
            MVRSceneGeometryLoader.orientation(fromMatrixText: panned))

        assertVector(apply(orientation, to: SCNVector3(0, 1, 0)), (0, 1, 0),
                     "panning must not tip the fixture over")
        // Stage-right becomes upstage, in the viewer's axes.
        let turned = apply(orientation, to: SCNVector3(1, 0, 0))
        XCTAssertEqual(Double(turned.y), 0, accuracy: 0.0001, "still level")
        XCTAssertEqual(
            (Double(turned.x) * Double(turned.x) + Double(turned.z) * Double(turned.z)).squareRoot(),
            1, accuracy: 0.0001, "still a unit vector, turned in the floor plane")
        XCTAssertEqual(Double(turned.x), 0, accuracy: 0.0001, "turned a full 90°")
    }

    func testAMatrixWithoutABasisLeavesTheFixtureUnrotated() {
        XCTAssertNil(MVRSceneGeometryLoader.orientation(fromMatrixText: ""))
        XCTAssertNil(MVRSceneGeometryLoader.orientation(fromMatrixText: "{1,2,3}"))
        XCTAssertNil(
            MVRSceneGeometryLoader.orientation(
                fromMatrixText: matrix([0, 0, 0, 0, 0, 0, 0, 0, 0])),
            "an all-zero basis says nothing; it is not a fixture squashed flat")
    }

    /// Position and rotation are read from the same string and must not
    /// interfere: the translation is the last three numbers, the basis the
    /// first nine.
    func testPositionIsStillReadCorrectlyFromARotatedMatrix() throws {
        let url = try MVRTestRig.write([
            MVRTestRig.Fixture(name: "Spot", type: "Spot", x: 1000, y: 2000, z: 3000)
        ])
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        defer { MVRTestRig.cleanUp() }

        let position = try XCTUnwrap(document.fixtures.first?.position3D)
        XCTAssertEqual(position.x, 1000, accuracy: 0.001)
        XCTAssertEqual(position.y, 2000, accuracy: 0.001)
        XCTAssertEqual(position.z, 3000, accuracy: 0.001)
    }
}
