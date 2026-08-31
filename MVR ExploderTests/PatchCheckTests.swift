import XCTest
@testable import MVR_Exploder

/// Overlapping addresses and fixtures running off the end of a universe.
final class PatchCheckTests: XCTestCase {

    private func patch(
        _ id: String, universe: Int = 1, channel: Int, footprint: Int
    ) -> MVRPatchCheck.Patch {
        .init(fixtureID: id, name: id, universe: universe, channel: channel, footprint: footprint)
    }

    // MARK: - The off-by-one

    /// A 40-channel fixture at 100 occupies 100–139, so 140 is free.
    func testAFixtureEndsOnItsLastChannelNotOnePast() {
        XCTAssertEqual(patch("a", channel: 100, footprint: 40).lastChannel, 139)
        XCTAssertEqual(patch("a", channel: 1, footprint: 1).lastChannel, 1)
    }

    func testTouchingFixturesDoNotOverlap() {
        let findings = MVRPatchCheck.findings(in: [
            patch("a", channel: 100, footprint: 40),
            patch("b", channel: 140, footprint: 10),
        ])
        XCTAssertEqual(findings, [])
    }

    // MARK: - Overlaps

    func testAnOverlapIsReportedWithTheChannelsInvolved() {
        let findings = MVRPatchCheck.findings(in: [
            patch("a", channel: 100, footprint: 40),
            patch("b", channel: 120, footprint: 10),
        ])
        XCTAssertEqual(findings, [.overlap(universe: 1, channels: 120...129, fixtureIDs: ["a", "b"])])
    }

    func testAFixtureFullyInsideAnotherIsAnOverlap() {
        let findings = MVRPatchCheck.findings(in: [
            patch("wide", channel: 1, footprint: 100),
            patch("inside", channel: 40, footprint: 4),
        ])
        XCTAssertEqual(findings, [.overlap(universe: 1, channels: 40...43, fixtureIDs: ["inside", "wide"])])
    }

    /// A stack is one finding naming everyone in it, not one per pair.
    /// A real file with 670 fixtures on one address produced 224,115
    /// pairwise findings — all true, none readable.
    func testAStackIsOneFindingNamingEveryFixtureInIt() {
        let findings = MVRPatchCheck.findings(in: [
            patch("a", channel: 1, footprint: 10),
            patch("b", channel: 2, footprint: 10),
            patch("c", channel: 3, footprint: 10),
        ])
        XCTAssertEqual(findings, [.overlap(universe: 1, channels: 2...11, fixtureIDs: ["a", "b", "c"])])
    }

    func testATallStackIsStillOneFinding() {
        let stack = (0..<200).map { patch("f\($0)", channel: 1, footprint: 40) }
        let findings = MVRPatchCheck.findings(in: stack)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.fixtureIDs.count, 200)
    }

    /// Two separate clashes in one universe stay separate.
    func testTwoUnrelatedOverlapsAreTwoFindings() {
        let findings = MVRPatchCheck.findings(in: [
            patch("a", channel: 1, footprint: 10),
            patch("b", channel: 5, footprint: 10),
            patch("c", channel: 100, footprint: 10),
            patch("d", channel: 105, footprint: 10),
        ])
        XCTAssertEqual(findings.count, 2)
        XCTAssertEqual(findings.compactMap { finding -> ClosedRange<Int>? in
            if case let .overlap(_, channels, _) = finding { return channels }
            return nil
        }, [5...10, 105...109])
    }

    func testTheSameChannelInAnotherUniverseIsFine() {
        let findings = MVRPatchCheck.findings(in: [
            patch("a", universe: 1, channel: 100, footprint: 40),
            patch("b", universe: 2, channel: 100, footprint: 40),
        ])
        XCTAssertEqual(findings, [])
    }

    // MARK: - Overruns

    func testAFixtureRunningPastTheEndOfItsUniverseIsReported() {
        let findings = MVRPatchCheck.findings(in: [patch("a", channel: 500, footprint: 40)])
        XCTAssertEqual(findings, [.overrun(fixtureID: "a", universe: 1, lastChannel: 539)])
    }

    func testAFixtureEndingExactlyOn512IsFine() {
        XCTAssertEqual(MVRPatchCheck.findings(in: [patch("a", channel: 473, footprint: 40)]), [])
    }

    func testOverrunsAreListedBeforeOverlaps() {
        let findings = MVRPatchCheck.findings(in: [
            patch("a", channel: 10, footprint: 10),
            patch("b", channel: 12, footprint: 10),
            patch("off", channel: 510, footprint: 10),
        ])
        guard case .overrun = findings.first else {
            return XCTFail("expected the overrun first, got \(findings)")
        }
        XCTAssertEqual(findings.count, 2)
    }

    // MARK: - Usage

    func testUsageCountsChannelsOnceEvenWhenTheyOverlap() {
        let usage = MVRPatchCheck.usage(in: [
            patch("a", channel: 1, footprint: 10),
            patch("b", channel: 5, footprint: 10),
        ])
        XCTAssertEqual(usage.map(\.used), [14], "1–14 covered, not 20")
    }

    func testUsageStopsAtTheEndOfTheUniverse() {
        let usage = MVRPatchCheck.usage(in: [patch("a", channel: 500, footprint: 100)])
        XCTAssertEqual(usage.map(\.used), [13], "500–512")
    }

    func testAnEmptyPatchHasNothingToSay() {
        XCTAssertEqual(MVRPatchCheck.findings(in: []), [])
        XCTAssertTrue(MVRPatchCheck.usage(in: []).isEmpty)
    }
}

/// A stand-in GDTF is normal in these files, and a wrong footprint is
/// worse than none — one Sceptron declaring 306 channels while patched
/// every 30 produced 35 overruns that were entirely artefacts.
final class SuspectFootprintTests: XCTestCase {

    private func candidates(
        spec: String = "Sceptron.gdtf", declared: Int, addresses: [Int]
    ) -> [(spec: String, address: Int, declared: Int)] {
        addresses.map { (spec, $0, declared) }
    }

    func testEvenSpacingTighterThanTheFootprintIsSuspect() {
        let suspects = MVRPatchCheck.suspectFootprints(
            candidates(declared: 306, addresses: [1, 31, 61, 91, 121]))

        XCTAssertEqual(suspects.count, 1)
        XCTAssertEqual(suspects.first?.declared, 306)
        XCTAssertEqual(suspects.first?.spacing, 30)
        XCTAssertEqual(suspects.first?.fixtureCount, 5)
    }

    func testSpacingThatMatchesTheFootprintIsAnOrdinaryPackedPatch() {
        let suspects = MVRPatchCheck.suspectFootprints(
            candidates(declared: 30, addresses: [1, 31, 61, 91]))
        XCTAssertEqual(suspects, [])
    }

    func testGenerousSpacingIsNotSuspect() {
        let suspects = MVRPatchCheck.suspectFootprints(
            candidates(declared: 30, addresses: [1, 101, 201, 301]))
        XCTAssertEqual(suspects, [])
    }

    /// Two fixtures clashing is a clash, not evidence about the GDTF.
    func testTwoFixturesAreNeverEnoughToDoubtTheGDTF() {
        let suspects = MVRPatchCheck.suspectFootprints(
            candidates(declared: 306, addresses: [1, 31]))
        XCTAssertEqual(suspects, [])
    }

    /// Without a clear majority at one spacing the rig isn't telling us
    /// anything, so the GDTF stands.
    func testScatteredAddressesLeaveTheGDTFAlone() {
        let suspects = MVRPatchCheck.suspectFootprints(
            candidates(declared: 100, addresses: [1, 8, 40, 41, 90, 200, 260]))
        XCTAssertEqual(suspects, [])
    }

    func testEachTypeIsJudgedSeparately() {
        let suspects = MVRPatchCheck.suspectFootprints(
            candidates(spec: "a.gdtf", declared: 300, addresses: [1, 31, 61, 91])
                + candidates(spec: "b.gdtf", declared: 10, addresses: [1, 11, 21, 31]))
        XCTAssertEqual(suspects.map(\.spec), ["a.gdtf"])
    }
}
