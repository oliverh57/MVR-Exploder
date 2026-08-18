# MVR Exploder

A native macOS app for working with **MVR** (My Virtual Rig) lighting show files — importing, editing, comparing two files against each other, exporting cleaned-up versions, viewing the show in 3D, and exporting patch documentation.

MVR files are zip archives containing a `GeneralSceneDescription.xml` plus `.gdtf` fixture-type packages (themselves zips, potentially containing 3D mesh geometry) and, optionally, separate 3D geometry for set pieces, staging, video walls, etc.

## Requirements

- Xcode (macOS 13+ deployment target; some 3D-viewer work assumes a recent SceneKit/SwiftUI toolchain)
- No external tools beyond Xcode — the one dependency (ZIPFoundation) resolves automatically via Swift Package Manager when you open the project

## Setup

1. Open `MVR Exploder.xcodeproj` in Xcode.
2. Xcode resolves the SPM dependency (**ZIPFoundation**, pinned via the committed `Package.resolved`) automatically.
3. Build and run.

The app is sandboxed. It needs the **File Access → User Selected File → Read/Write** capability (already configured in the target's entitlements) — read is needed for drag-and-drop import, write for export; read-only will crash the save panel.

## What it does

### Single Edit mode
Import one `.mvr` file, edit it, export a cleaned-up copy:
- Fixture table with sortable columns, live edit highlighting (original vs. current value)
- Offset Fixture IDs or DMX universes across the whole file
- Regenerate UUIDs, edit individual Fixture ID / address / UUID / name / layer / classing
- Fixture ID Map — grid visualization of ID usage, gaps, and clashes, with click-to-jump
- Remove unpatched fixtures (no DMX address, no Fixture ID, or both)
- Export options: include/exclude scene geometry, reassign layers by fixture type, generate dummy GDTFs for missing references, clean up empty classes/layers, normalize `UnitNumber`→`FixtureID`
- **Import field detection**: automatically figures out whether `FixtureID` or `UnitNumber` holds the real per-fixture ID by checking which field actually has non-zero data, and only asks when the file is genuinely ambiguous (both fields populated). Reports a post-import summary — fixture count, which field was used, type/universe counts, unpatched counts.
- **Patch PDF export** — paginated patch list (Fixture ID, Fixture Type, Mode, Universe, Address), grouped by fixture type or flat by fixture ID, with page numbers.

### Compare mode
Load two `.mvr` files side by side, match fixtures by UUID or Fixture ID, and copy individual attributes (name, ID, address, UUID, GDTF reference + underlying `.gdtf` bytes, layer, classing, matrix/position) from one file's fixture to the other's.

### 3D Viewer
A spatial view of the whole show, opened as its own resizable window (not a sheet, so it can be sized/zoomed/full-screened independently):

- **Real GDTF fixture geometry** — parses each fixture's actual `.3ds` mesh files and geometry hierarchy (Base/Yoke/Head, etc.) rather than showing placeholder shapes, with a box/sphere fallback when a fixture's GDTF has no parseable mesh
- **Real MVR scene geometry** — set pieces, staging, video walls, etc., parsed from both legacy `.3ds` and glTF-binary (`.glb`) formats (both formats are used in the wild; the app auto-detects and handles their different units/axis conventions)
- **Scene Explorer** — toggle individual layers on/off (for both fixtures and scene geometry), with fixture/object counts per layer
- **Geometry export selection** — click objects in the 3D view or click a whole layer in the explorer to mark scene geometry for export (selected objects tint blue); export the selection as an **OBJ** file (one group per object, real-world scale, normals included)
- Custom orbit camera (drag to orbit, right/middle/Shift-drag to pan, scroll/pinch to zoom toward the cursor), camera presets that frame whatever's currently visible, a "Fit All" button, screen-space ambient occlusion, and 4x multisampling
- Hover any fixture for a glowing highlight and an info card (name, GDTF spec, mode, Fixture ID, patch, layer)

### App icon
Generated in-repo (no external asset files) — see `Assets.xcassets/AppIcon.appiconset`.

## Architecture

| File | Role |
|---|---|
| `AppMode.swift` | Enum for the two top-level modes |
| `ModeSelectionView.swift` | Launch screen — picks Single Edit or Compare |
| `ContentView.swift` | Dispatcher/router between modes |
| `SingleEditView.swift` | Main single-file editor |
| `CompareView.swift` | Two-file comparison/matching/attribute-copy tool |
| `MVRDocument.swift` | Core model — loads an `.mvr` into a live, mutable `XMLDocument`, exposes `fixtures: [MVRFixture]`, and all mutation methods |
| `MVRFixture.swift` | Per-fixture struct — tracks original vs. current values, sort-proxy properties, unpatched-detection helpers |
| `MVRExporter.swift` | Writes a new `.mvr` from an `MVRDocument` + export options |
| `MVRComparator.swift` | Compare-mode matching logic + `MVRComparisonRow` model |
| `MVRPatchPDFExporter.swift` | Paginated patch-list PDF export |
| `MVROBJExporter.swift` | Wavefront OBJ export of selected scene geometry |
| `FixtureFilter.swift` | Shared search/filter field enum + matching logic |
| `UUIDCell.swift` | Shared "UUID" placeholder cell that reveals the real value on hover |
| `DeleteRowButton.swift` | Shared grey→red-on-hover delete button |
| `FixtureIDMapView.swift` | Grid visualization of Fixture ID usage, gaps, and clashes |
| `Fixture3DView.swift` / `Fixture3DWindow.swift` | SceneKit-based 3D viewer and its hosting window |
| `GDTFModel.swift` | `.3ds` binary parser + GDTF geometry-tree parser (fixture meshes) |
| `MVRSceneGeometry.swift` | `.glb` (glTF 2.0) parser + MVR SceneObject/Symdef scene-geometry loader (set, staging, video walls) |

## MVR-schema assumptions

The MVR/GDTF spec is large; this app was built and tested against real show files rather than the spec document, so treat the following as things to verify against your own files rather than ground truth:

- XML nesting: `<Layers><Layer name uuid><ChildList><Fixture/>...</ChildList></Layer></Layers>`
- Fixture ID lives in `<FixtureID>` or `<UnitNumber>`
- DMX address is a single absolute value in `<Addresses><Address>` (1–512 per universe)
- "Class" is read/written via a `classing` attribute on `<Fixture>`
- Fixture 3D position comes from `<Matrix>` (12 numbers, column-major: 3 axis vectors + translation); GDTF's internal `<Geometry>`/`<Axis> Position` matrices are a *different* format (16 numbers, row-major)
- GDTF `.3ds` fixture models are unit-normalized; real-world size comes from the `<Model>` XML's Width/Height/Length attributes
- MVR scene `.3ds` geometry is millimetres, Z-up (MVR's own convention); `.glb` scene geometry is metres, Y-up (glTF's convention) — these are genuinely different per format, not a bug

## Known limitations

- **No rotation applied anywhere in the 3D viewer** — both a fixture's own placement and GDTF's internal part-to-part stacking (Base→Yoke→Head) are translation-only. A fixture tilted in the show file, or a kinematic part with a rotated rest pose, renders axis-aligned. This is the most likely next thing to tackle.
- SwiftUI's `Table` has no documented API for scrolling to a row programmatically; the Fixture ID Map's "click to jump" relies on `Table`'s undocumented auto-scroll-on-selection behavior, with a flashing highlight as a fallback.
- No automated tests.
- Very large scene geometry (thousands of meshes) can make 3D navigation feel heavy; merging meshes by material would help if this becomes a real problem.

## Building a release

```bash
xcodebuild -project "MVR Exploder.xcodeproj" -scheme "MVR Exploder" -configuration Release \
  -destination 'platform=macOS' ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" build
```

The project uses automatic signing with no assigned team, so local builds are ad-hoc signed ("Sign to Run Locally"). Anyone you share the built `.app` with will need to right-click → Open the first time (Gatekeeper flags unsigned/unnotarized apps) — this needs a paid Apple Developer Program membership to avoid.
