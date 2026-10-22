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

    /// Pixel fixtures define one pixel's channels on a template and place
    /// it with `<GeometryReference>`s, each saying where its copy starts.
    /// Reading the template alone made a 117-channel Pixelline mode look
    /// 5 channels wide.
    func testEachPlacedPixelCountsAtItsOwnOffset() throws {
        let document = try XMLDocument(xmlString: """
        <FixtureType Name="Test">
          <Geometries>
            <Beam Name="Pixel"/>
            <Geometry Name="Body">
              <Geometry Name="Main">
                <GeometryReference Name="P1" Geometry="Pixel"><Break DMXBreak="1" DMXOffset="4"/></GeometryReference>
                <GeometryReference Name="P2" Geometry="Pixel"><Break DMXBreak="1" DMXOffset="7"/></GeometryReference>
                <GeometryReference Name="P3" Geometry="Pixel"><Break DMXBreak="1" DMXOffset="10"/></GeometryReference>
              </Geometry>
            </Geometry>
          </Geometries>
          <DMXModes>
            <DMXMode Name="12 channel" Geometry="Body">
              <DMXChannels>
                <DMXChannel DMXBreak="1" Offset="1" Geometry="Main"/>
                <DMXChannel DMXBreak="1" Offset="2,3" Geometry="Main"/>
                <DMXChannel DMXBreak="1" Offset="1" Geometry="Pixel"/>
                <DMXChannel DMXBreak="1" Offset="2" Geometry="Pixel"/>
                <DMXChannel DMXBreak="1" Offset="3" Geometry="Pixel"/>
              </DMXChannels>
            </DMXMode>
          </DMXModes>
        </FixtureType>
        """, options: [])
        // Three control channels, then the pixel at 4–6, 7–9 and 10–12:
        // the last copy ends at its template offset 3, plus 10, less 1.
        XCTAssertEqual(GDTFFootprintParser.modes(description: document)[0].channels, 12)
        // Two control attributes (one 16-bit), then three per pixel.
        XCTAssertEqual(GDTFFootprintParser.modes(description: document)[0].parameters, 11)
    }

    /// MA's own example: dimmer, pan, pan fine, tilt, tilt fine is five
    /// DMX channels but "only costs 3 parameters" — fine bytes are free.
    /// A virtual channel takes no DMX and isn't counted.
    func testGrandMA3ParametersCountEachAttributeOnce() throws {
        let document = try gdtf("""
        <DMXMode Name="Standard">
          <DMXChannels>
            <DMXChannel DMXBreak="1" Offset="1"/>
            <DMXChannel DMXBreak="1" Offset="2,3"/>
            <DMXChannel DMXBreak="1" Offset="4,5"/>
            <DMXChannel DMXBreak="1" Offset=""/>
          </DMXChannels>
        </DMXMode>
        """)
        let mode = GDTFFootprintParser.modes(description: document)[0]
        XCTAssertEqual(mode.channels, 5)
        XCTAssertEqual(mode.parameters, 3)
    }

    /// Exporters stand in for a missing GDTF with one byte per channel and
    /// a made-up attribute; that has to read as "parameters unknown", not
    /// as a fixture with no 16-bit channels.
    func testPlaceholderGDTFsAreRecognised() throws {
        func mode(_ attributes: [String], offsets: [String]) throws -> GDTFFootprint {
            let channels = zip(attributes, offsets).map { attribute, offset in
                "<DMXChannel DMXBreak=\"1\" Offset=\"\(offset)\"><LogicalChannel Attribute=\"\(attribute)\"/></DMXChannel>"
            }.joined()
            return GDTFFootprintParser.modes(description: try gdtf("<DMXMode Name=\"M\"><DMXChannels>\(channels)</DMXChannels></DMXMode>"))[0]
        }
        XCTAssertTrue(try mode(["Dummy", "Dummy", "Dummy"], offsets: ["1", "2", "3"]).isPlaceholder)
        XCTAssertTrue(try mode(["Dimmer1", "Dimmer2", "Dimmer3"], offsets: ["1", "2", "3"]).isPlaceholder)
        XCTAssertFalse(try mode(["Dimmer", "Pan", "Tilt"], offsets: ["1", "2", "3"]).isPlaceholder)
        XCTAssertFalse(try mode(["Dimmer1", "Dimmer2"], offsets: ["1", "2,3"]).isPlaceholder)
    }

    func testTheSmallestHardwareThatCoversTheRig() {
        XCTAssertEqual(ModeViewerView.hardware(for: 4_096), "fits 4,096 (onPC + wing or 4k node)")
        XCTAssertEqual(ModeViewerView.hardware(for: 4_097), "needs 8,192 (compact, PU L)")
        XCTAssertEqual(ModeViewerView.hardware(for: 16_385), "needs 20,480 (full-size)")
        XCTAssertEqual(ModeViewerView.hardware(for: 30_000), "over 20,480 — add processing units")
    }

    func testNonsenseGivesNoModesRatherThanCrashing() {
        XCTAssertEqual(GDTFFootprintParser.modes(packageData: Data("not a zip".utf8)), [])
        XCTAssertEqual(GDTFFootprintParser.modes(packageData: Data()), [])
    }
}
