import XCTest
@testable import MVR_Exploder

/// Exporting must never lose a fixture. It once lost every one of them.
final class ExportIntegrityTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    /// The regression that matters: MVR uses `<SceneObject>` both for venue
    /// geometry and as a *container* with fixtures in its own `<ChildList>`.
    /// Stripping geometry used to detach the container and take the
    /// fixtures with it — 328 of 328 on one real file, silently.
    func testFixturesNestedInASceneObjectSurviveGeometryStripping() throws {
        let loose = MVRTestRig.bar("Spot", count: 3, y: 0)
        let nested = MVRTestRig.bar("Wash", count: 5, y: 3000)
        let url = try MVRTestRig.write(
            loose,
            sceneObjects: [MVRTestRig.SceneObject(name: "Downstage Truss", fixtures: nested)])

        for includeGeometry in [true, false] {
            let document = MVRDocument()
            try document.load(from: url, idFieldName: "FixtureID")
            XCTAssertEqual(document.fixtures.count, 8, "the source itself")

            let exported = try export(document, includeSceneGeometry: includeGeometry)
            let reopened = MVRDocument()
            try reopened.load(from: exported, idFieldName: "FixtureID")

            XCTAssertEqual(
                reopened.fixtures.count, 8,
                "includeSceneGeometry: \(includeGeometry) lost fixtures")
            XCTAssertEqual(
                Set(reopened.fixtures.map(\.name)), Set(document.fixtures.map(\.name)),
                "includeSceneGeometry: \(includeGeometry) lost the wrong ones")
        }
    }

    func testEveryExportOptionKeepsEveryFixture() throws {
        let url = try MVRTestRig.write(
            MVRTestRig.bar("Spot", count: 4, y: 0),
            sceneObjects: [MVRTestRig.SceneObject(
                name: "Floor Package", fixtures: MVRTestRig.bar("Bar", count: 2, y: 6000, z: 500))])

        for layers in [true, false] {
            for cleanup in [true, false] {
                let document = MVRDocument()
                try document.load(from: url, idFieldName: "FixtureID")
                let exported = try export(
                    document, includeSceneGeometry: false,
                    assignLayers: layers, cleanup: cleanup)
                let reopened = MVRDocument()
                try reopened.load(from: exported, idFieldName: "FixtureID")
                XCTAssertEqual(
                    reopened.fixtures.count, 6,
                    "layers: \(layers), cleanup: \(cleanup)")
            }
        }
    }

    private func export(
        _ document: MVRDocument, includeSceneGeometry: Bool,
        assignLayers: Bool = false, cleanup: Bool = false
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mvr")
        try MVRExporter.export(document, to: url, options: MVRExportOptions(
            includeSceneGeometry: includeSceneGeometry,
            assignLayersByFixtureType: assignLayers,
            replaceAllWithDummyGDTFs: false,
            cleanupEmptyClassesAndLayers: cleanup))
        return url
    }
}
