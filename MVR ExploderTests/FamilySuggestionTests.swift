import XCTest
@testable import MVR_Exploder

/// Two lengths of one product should be offered as one system; two
/// different fixtures from one maker should not.
final class FamilySuggestionTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    // MARK: - The stem rule

    func testStripsATrailingLength() {
        XCTAssertEqual(GDTFSpecName.family(of: "Sceptron 320"), "sceptron")
        XCTAssertEqual(GDTFSpecName.family(of: "Sceptron 100"), "sceptron")
        XCTAssertEqual(GDTFSpecName.family(of: "Pixel Line IP 100"), "pixel line ip")
    }

    func testLeavesNamesWithoutALengthAlone() {
        XCTAssertNil(GDTFSpecName.family(of: "MAC Aura XIP"))
        XCTAssertNil(GDTFSpecName.family(of: "Rivale Profile"))
    }

    func testDoesNotMakeAFamilyOutOfATooShortStem() {
        // "IP 65" would leave "IP", which is not a product.
        XCTAssertNil(GDTFSpecName.family(of: "IP 65"))
        XCTAssertNil(GDTFSpecName.family(of: "12"))
    }

    // MARK: - The suggestion

    func testSuggestsTwoLengthsOfOneProduct() throws {
        let session = try makeSession(types: ["Sceptron 320", "Sceptron 100"])
        let suggestions = session.suggestedTypeMerges

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(Set(suggestions[0].map(session.displayName(for:))),
                       ["Sceptron 320", "Sceptron 100"])
        XCTAssertTrue(session.suggestedMergeDescription(suggestions[0]).contains("Sceptron"))
    }

    func testDoesNotSuggestDifferentFixturesFromOneMaker() throws {
        let session = try makeSession(types: ["MAC Aura XIP", "MAC Viper"])
        XCTAssertTrue(session.suggestedTypeMerges.isEmpty)
    }

    func testDoesNotSuggestAProfileAndAWashOfOneRange() throws {
        let session = try makeSession(types: ["Rivale Profile", "Rivale Wash"])
        XCTAssertTrue(session.suggestedTypeMerges.isEmpty)
    }

    func testAcceptingLinksTheTypesAndClearsTheSuggestion() throws {
        let session = try makeSession(types: ["Sceptron 320", "Sceptron 100"])
        let suggestion = try XCTUnwrap(session.suggestedTypeMerges.first)

        session.acceptSuggestedMerge(suggestion)

        XCTAssertTrue(session.suggestedTypeMerges.isEmpty)
        XCTAssertEqual(session.displayTypes.count, 1, "linked types collapse to one row")
        XCTAssertTrue(session.isMerged(session.displayTypes[0]))
        // One sequence, not two interleaved blocks.
        let ids = session.plan.assignments.map(\.newID).sorted()
        XCTAssertEqual(ids, Array(ids.first!...ids.last!))
    }

    func testDismissingIsRememberedAcrossAReopen() throws {
        let url = try MVRTestRig.write(
            MVRTestRig.bar("Sceptron 320", count: 4, y: 0)
                + MVRTestRig.bar("Sceptron 100", count: 4, y: 2000))
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")

        let session = AutoIDSession(fixtures: document.fixtures)
        let suggestion = try XCTUnwrap(session.suggestedTypeMerges.first)
        session.dismissSuggestedMerge(suggestion)
        XCTAssertTrue(session.suggestedTypeMerges.isEmpty)

        // Through the file and back.
        session.apply(to: document)
        let exported = try export(document)
        let reopened = MVRDocument()
        try reopened.load(from: exported, idFieldName: "FixtureID")
        let resumed = AutoIDSession(
            fixtures: reopened.fixtures,
            storedNames: reopened.groupNames,
            session: reopened.autoIDSession)

        XCTAssertTrue(resumed.suggestedTypeMerges.isEmpty, "a dismissed suggestion must not come back")
    }

    // MARK: - Helpers

    private func makeSession(types: [String]) throws -> AutoIDSession {
        var fixtures: [MVRTestRig.Fixture] = []
        for (index, type) in types.enumerated() {
            fixtures += MVRTestRig.bar(type, count: 4, y: Double(index) * 2000)
        }
        let url = try MVRTestRig.write(fixtures)
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        return AutoIDSession(fixtures: document.fixtures)
    }

    private func export(_ document: MVRDocument) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mvr")
        try MVRExporter.export(document, to: url, options: MVRExportOptions(
            includeSceneGeometry: true,
            assignLayersByFixtureType: false,
            replaceAllWithDummyGDTFs: false,
            cleanupEmptyClassesAndLayers: false))
        return url
    }
}
