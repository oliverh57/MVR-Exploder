# Changelog

## Unreleased

### Smart Auto ID
Auto ID is now **Smart Auto ID**, and the run survives the file.

- **Sessions persist.** Merges, splits, order overrides, per-group tolerance and spacing, names, pinned start IDs, linked types and gaps are written into the MVR's private `<UserData>` block and picked back up on open — a header line says so, with **Start fresh** to discard. Keyed by MVR uuid, so a correction lapses only if the fixtures it describes are gone. About 3 KB for a 573-fixture show, invisible to consoles.
- **ID gaps.** Two tickboxes: spare IDs after each group (room to add to a truss) and after each fixture (room to slot one in between). Blocks are sized from the span the gaps actually consume, so types can't run into each other.
- **Suggested families.** Two lengths of one product — a Sceptron 320 and a Sceptron 100 — are offered as one system to number in a single sequence. The rule is narrow on purpose: the same name once a trailing number is stripped, so a MAC Aura is not paired with a MAC Viper. Turning a suggestion down is remembered.
- **Bars now list downstage to upstage.** Row order banded depth by the *grouping* distance, which is about spacing along a bar, so bars 3 m apart fell in one band and were then ordered left-to-right — a type could read LX2, LX5, LX3, LX6, and the IDs were allocated in that order. Row order and LX numbering now share one banding rule. Affected 104 of 320 types across 49 of 143 real files.
- **LX numbering explained.** A caption says why a type starts at LX2 and which type carries LX1, instead of leaving it in a tooltip.
- **The attention badge lists what needs looking at.** Clicking "5 types need a look" opens the flagged groups, each named and each a click away from being opened. It used to step to the next one, which gave no sense of how many were left or what was on them.
- **Reset grouping moved to the foot of the groups panel**, under the groups it resets. Sitting directly beneath the LX note, it made that note read as a label explaining the button.
- **Tower mode.** A new numbering order, "Tower (down each column)", for a tower carrying more than one fixture at each height: all the way down one column, then down the next, rather than reading the pair at each height before dropping a level. Columns are derived from the height bands, not from horizontal position — the only distance available for "same column" is the ordering tolerance, which at 0.2 m is about the width of the tower itself.
- **Ordering and grouping are told apart.** The group's menu now reads *Numbering order* / *Ordering tolerance* together, then *Grouping distance* below: tolerance is how close fixtures must be to count as one position when numbering, grouping distance is how far apart they must be to be a separate truss. Tolerance used to sit next to the grouping controls, which is what made the two read as the same kind of setting. The Merge button has gone from the top of the groups column — merging is on the group's own right-click menu — and the fixture type's menu carries a greyed *Group fixtures together* pointing at it.
- **Escape asks first.** Closing with unsaved corrections confirms rather than binning the run silently; an untouched sitting still closes straight away, and Escape backs out of a rename or a split-in-progress before it means "close".
- **Reproducible numbering.** The same file with the same settings could produce different IDs between launches: `MVRFixture.id` is a per-load UUID and was being used to break ties between coincident fixtures and to key cluster buckets. Both now key off what the file says.

### Patch Check
- **New: Patch Check**, alongside the Fixture ID Map. Reads each fixture's channel count from its GDTF mode, turns every address into a range, and reports fixtures sharing channels, fixtures running off the end of their universe, and how full each universe is. Click a finding to find those fixtures in the table. Nothing in the app knew a fixture's width before, so an overlapping patch looked like two ordinary rows.
- Overlaps are reported per contested **run of channels**, not per pair of fixtures. One real file has 670 fixtures on a single address, which as pairs is 224,115 findings — all true, none readable.
- A type whose addresses are evenly spaced *tighter than its own declared footprint* is excluded and reported in its own right: a stand-in GDTF declaring 306 channels for fixtures patched 30 apart produced 35 overruns that were entirely artefacts. Needs three fixtures and a clear majority at one spacing, so an ordinary pair of clashing fixtures is never mistaken for it.
- Types whose GDTF gives no channel count at all — real placeholder GDTFs carry `Offset=""` — are counted and named rather than silently skipped, so a clean result never covers fixtures nobody looked at.
- Across 143 real files: 73 overlaps and 18 overruns, from 27,537 placed fixtures.

### Numbering
- **The default starting ID is 101**, and the first block now uses the number given rather than rounding it. A type with more than 100 fixtures takes a thousand-block, so a start of 101 was previously rounded straight back up to 1001, quietly ignoring it.

### 3D viewer
- **Fixture rotation is applied.** Only the position was read from each fixture's `<Matrix>`; the rotation was discarded, so a light hung upside down under a truss drew the right way up. The Z-up to Y-up change of basis is the same one scene geometry already used.
- **Export to FBX and DXF** alongside OBJ, from the same selection. FBX is written as binary 7.4 — Blender's importer rejects ASCII FBX outright — in centimetres, Y up. DXF is R12 with one layer per object, in metres, Z up, because CAD's plan view is the XY plane. DWG itself needs Autodesk's or the ODA's licence-gated libraries and cannot be shipped; DXF is the documented interchange format AutoCAD, Vectorworks and Rhino all open.

### Fixes
- **Export no longer deletes fixtures.** With scene geometry excluded, fixtures nested inside a `<SceneObject>` container were detached along with it — 328 of 328 on one real file, silently.
- Large exports no longer balloon: `String(format:)` leaves an autoreleased string per coordinate, which took a 10.8-million-triangle export to 6.8 GB; DXF also streams to disk instead of building the file in memory.

### Tests
- An `MVR ExploderTests` target, 46 tests. Rigs are built from scratch in the tests rather than checked-in show files. `RealFileCorpusTests` sweeps a real library when `TEST_RUNNER_MVR_CORPUS` points at one, and skips otherwise.

## v1.0.0

First tagged release. MVR Exploder imports, edits, compares, and exports MVR lighting show files, with a full 3D viewer.

### Single Edit
- Import an `.mvr`, edit fixtures in a sortable table with live edit highlighting (original vs. current value shown side by side)
- Offset every Fixture ID or DMX universe in the file at once
- Regenerate UUIDs; edit individual Fixture ID, address, UUID, name, layer, or classing
- **Fixture ID Map** — a grid visualization of ID usage, gaps, and clashes across the whole file, with click-to-jump to the row
- Remove unpatched fixtures (no DMX address, no Fixture ID, or both)
- **Import field detection** — automatically determines whether `FixtureID` or `UnitNumber` holds the real per-fixture ID by checking which one actually has non-zero data, and only asks when a file is genuinely ambiguous (both fields populated on overlapping fixtures — confirmed this happens in real files). A post-import summary reports fixture count, which field was used, type/universe counts, and unpatched counts.
- Export options: include/exclude scene geometry, reassign layers by fixture type, generate dummy GDTFs for missing references, clean up empty classes/layers, normalize `UnitNumber` → `FixtureID`

### Compare Mode
- Load two `.mvr` files side by side, matched by UUID or Fixture ID
- Copy individual attributes — name, Fixture ID, address, UUID, GDTF reference (including the underlying `.gdtf` bytes), layer, classing, matrix/position — from one file's fixture to the other's

### 3D Viewer
- Opens in its own resizable window, independent of the main editor
- **Real GDTF fixture geometry** — parses each fixture's actual `.3ds` mesh files and geometry hierarchy (base/yoke/head, etc.), with a box/sphere fallback when a fixture's GDTF has no parseable mesh. "Dummy" placeholder sub-meshes (a single fixture can reference dozens) are filtered out.
- **Real MVR scene geometry** — set pieces, staging, video walls, parsed from both the legacy `.3ds` format and glTF-binary (`.glb`), which use different units and axis conventions in the wild; both are detected and handled correctly
- **Scene Explorer** — toggle individual layers on or off, for fixtures and scene geometry alike, with per-layer object counts; click a layer's name to select every object in it
- **Geometry export selection** — click objects in the view, or a whole layer in the explorer, to mark scene geometry for export; selected objects tint blue
- **OBJ export** — writes the selected geometry as a Wavefront OBJ (one group per object, real-world scale, normals included), verified to load correctly in both Apple's ModelIO and SceneKit importers
- Custom orbit camera: drag to orbit, right-drag/middle-drag/Shift-drag to pan, scroll or pinch to zoom toward the cursor
- Camera presets and a "Fit All" button that frame whatever is currently visible (respecting hidden layers), not just the fixture positions captured at load
- Screen-space ambient occlusion and 4x multisampling for a less flat, less jagged render
- Hover any fixture for a glow highlight and an info card (name, GDTF spec, mode, Fixture ID, patch, layer)

### Patch Documentation
- **Patch PDF export** — a paginated patch list (Fixture ID, Fixture Type, Mode, Universe, Address) with page numbers, grouped by fixture type or listed flat by Fixture ID

### Known limitations
- Fixture and part rotation is not applied anywhere in the 3D viewer — placement is translation-only, so a tilted fixture renders axis-aligned. Most likely next thing to address.
- No automated test suite.
- Very large scene-geometry files (thousands of meshes) can make navigation feel heavy.

See `README.md` for architecture notes and MVR-schema assumptions.
