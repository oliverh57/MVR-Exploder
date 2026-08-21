import XCTest
@testable import MVR_Exploder

/// The same file, the same settings, the same IDs — every time.
///
/// This was not true. `MVRFixture.id` is a fresh `UUID()` minted at load,
/// and it was being used to break ties between coincident fixtures and to
/// key the cluster buckets, so opening a show twice could hand fixtures
/// different IDs. Two loads in one process is enough to catch it: the ids
/// differ between loads exactly as they would between launches.
final class AutoIDDeterminismTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    func testTwoLoadsOfOneFileNumberIdentically() throws {
        let url = try MVRTestRig.write(
            MVRTestRig.bar("Spot", count: 12, y: 0)
                + MVRTestRig.bar("Spot", count: 12, y: 4000)
                + MVRTestRig.bar("Wash", count: 8, y: 2000))

        XCTAssertEqual(try plan(of: url), try plan(of: url))
    }

    /// Fixtures on exactly the same point have no geometry to order them
    /// by, so whatever breaks the tie has to come from the file.
    func testCoincidentFixturesNumberIdentically() throws {
        var fixtures = MVRTestRig.bar("Spot", count: 6, y: 0)
        // Three pairs, each pair sharing one point.
        for index in stride(from: 0, to: 6, by: 2) {
            fixtures[index + 1].x = fixtures[index].x
            fixtures[index + 1].y = fixtures[index].y
            fixtures[index + 1].z = fixtures[index].z
        }
        let url = try MVRTestRig.write(fixtures)

        XCTAssertEqual(try plan(of: url), try plan(of: url))
    }

    /// Keyed on the file's own uuid, since `fixture.id` is per-load by
    /// design and comparing on it would prove nothing.
    private func plan(of url: URL) throws -> [String: Int] {
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        let session = AutoIDSession(fixtures: document.fixtures)
        let uuids = Dictionary(
            document.fixtures.map { ($0.id, $0.originalUUID) }, uniquingKeysWith: { first, _ in first })
        return session.plan.assignments.reduce(into: [:]) { result, assignment in
            result[uuids[assignment.fixtureID] ?? assignment.fixtureID] = assignment.newID
        }
    }
}
