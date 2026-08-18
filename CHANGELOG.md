# Changelog

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
