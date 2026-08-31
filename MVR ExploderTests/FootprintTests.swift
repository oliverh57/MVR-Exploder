import XCTest
@testable import MVR_Exploder

/// Reading a fixture's channel count out of its GDTF.
final class FootprintTests: XCTestCase {

    private func gdtf(_ modes: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
        <FixtureType Name="Test">
          <DMXModes>\(modes)</DMXModes>
        </FixtureType>
        """, options: [])
    }

    /// The footprint is the highest offset reached, not the number of
    /// channels: a 16-bit channel is one element carrying two offsets.
    func testAModesFootprintIsItsHighestOffset() throws {
        let document = try gdtf("""
        <DMXMode Name="Standard">
          <DMXChannels>
            <DMXChannel DMXBreak="1" Offset="1"/>
            <DMXChannel DMXBreak="1" Offset="2,3"/>
            <DMXChannel DMXBreak="1" Offset="4"/>
          </DMXChannels>
        </DMXMode>
        """)
        let modes = GDTFFootprintParser.modes(description: document)
        XCTAssertEqual(modes.count, 1)
        XCTAssertEqual(modes[0].mode, "Standard")
        XCTAssertEqual(modes[0].channels, 4)
        XCTAssertTrue(modes[0].isKnown)
    }

    /// Virtual channels exist in the fixture's logic and take no DMX.
    func testChannelsWithNoOffsetDoNotCount() throws {
        let document = try gdtf("""
        <DMXMode Name="Standard">
          <DMXChannels>
            <DMXChannel DMXBreak="1" Offset="1"/>
            <DMXChannel DMXBreak="1" Offset=""/>
            <DMXChannel DMXBreak="1"/>
          </DMXChannels>
        </DMXMode>
        """)
        XCTAssertEqual(GDTFFootprintParser.modes(description: document)[0].channels, 1)
    }

    /// Real files ship placeholder GDTFs whose channels are all declared
    /// with an empty offset. That is "unknown", and must not be read as a
    /// zero-width fixture that overlaps nothing.
    func testAModeWithNoOffsetsAtAllIsUnknownRatherThanZeroWide() throws {
        let document = try gdtf("""
        <DMXMode Name="DMX Mode">
          <DMXChannels>
            <DMXChannel DMXBreak="1" Offset=""/>
            <DMXChannel DMXBreak="1" Offset=""/>
          </DMXChannels>
        </DMXMode>
        """)
        let mode = GDTFFootprintParser.modes(description: document)[0]
        XCTAssertEqual(mode.channels, 0)
        XCTAssertFalse(mode.isKnown)
    }

    func testEveryModeIsListedSeparately() throws {
        let document = try gdtf("""
        <DMXMode Name="Basic">
          <DMXChannels><DMXChannel DMXBreak="1" Offset="12"/></DMXChannels>
        </DMXMode>
        <DMXMode Name="Extended">
          <DMXChannels><DMXChannel DMXBreak="1" Offset="42"/></DMXChannels>
        </DMXMode>
        """)
        let modes = GDTFFootprintParser.modes(description: document)
        XCTAssertEqual(modes.map(\.mode), ["Basic", "Extended"])
        XCTAssertEqual(modes.map(\.channels), [12, 42])
    }

    /// A fixture addressed on more than one break takes an address per
    /// break; the first is the one a single-address patch uses.
    func testEachBreakIsCountedSeparately() throws {
        let document = try gdtf("""
        <DMXMode Name="Pixel">
          <DMXChannels>
            <DMXChannel DMXBreak="1" Offset="8"/>
            <DMXChannel DMXBreak="2" Offset="96"/>
          </DMXChannels>
        </DMXMode>
        """)
        let mode = GDTFFootprintParser.modes(description: document)[0]
        XCTAssertEqual(mode.channelsByBreak, [1: 8, 2: 96])
        XCTAssertEqual(mode.channels, 8, "the first break")
    }

    /// Files in the wild number a lone break 0 rather than 1.
    func testABreakNumberedZeroIsStillTheFirstBreak() throws {
        let document = try gdtf("""
        <DMXMode Name="Standard">
          <DMXChannels><DMXChannel DMXBreak="0" Offset="16"/></DMXChannels>
        </DMXMode>
        """)
        let mode = GDTFFootprintParser.modes(description: document)[0]
        XCTAssertEqual(mode.channels, 16, "a break numbered 0 must not read as no channels")
    }

    func testNonsenseGivesNoModesRatherThanCrashing() {
        XCTAssertEqual(GDTFFootprintParser.modes(packageData: Data("not a zip".utf8)), [])
        XCTAssertEqual(GDTFFootprintParser.modes(packageData: Data()), [])
    }
}
