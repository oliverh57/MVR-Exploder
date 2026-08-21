import XCTest
@testable import MVR_Exploder

/// Proves the harness itself works before anything relies on it: a rig
/// written by `MVRTestRig` must load back with the fixtures it was given,
/// at the positions it was given.
final class SmokeTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    func testSyntheticRigLoadsBack() throws {
        let url = try MVRTestRig.write(MVRTestRig.bar("Spot", count: 6, y: 0))
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")

        XCTAssertEqual(document.fixtures.count, 6)
        XCTAssertEqual(Set(document.fixtures.map(\.gdtfSpec)), ["Spot.gdtf"])

        let positions = document.fixtures.compactMap(\.position3D)
        XCTAssertEqual(positions.count, 6)
        // Six at 1.5 m centres spans 7.5 m, centred on zero.
        XCTAssertEqual(positions.map(\.x).min() ?? 0, -3750, accuracy: 0.5)
        XCTAssertEqual(positions.map(\.x).max() ?? 0, 3750, accuracy: 0.5)
        XCTAssertEqual(positions.map(\.z).max() ?? 0, 8000, accuracy: 0.5)
    }
}
