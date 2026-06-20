# Clip-Based Color Grading — Design

**Date:** 2026-06-20
**Status:** Approved, ready for implementation planning
**Branch:** `feat/global-lut` (or a new `feat/clip-grading`)

## Goal

Add per-clip color grading on top of the existing project-wide (timeline) grade. A clip
can carry its own correction and look, which **stacks under** the timeline grade. This
solidifies the grading workflow by letting editors match cameras and shape individual
shots without abandoning a global look.

## Decisions (locked)

1. **Relationship:** Clip grade and timeline grade **stack**. Final look of a clip =
   clip grade applied first, then the timeline grade composited on top.
2. **Scope of a clip grade:** Full parity with the timeline grade — primaries
   (`PrimaryGrade`), tone curves, and a `LUTRef` (built-in look or `.cube`).
3. **Inspector targeting:** Selection-driven. A clip selected → Color inspector edits
   that clip's grade. Nothing selected → it edits the timeline grade. A scope header
   shows which is active.
4. **Clip badge:** Graded clips show a small grade glyph on their timeline clip view.
5. **Overlaps (v1):** Topmost video clip's grade wins for the region it covers. Full
   per-layer grading through transitions is deferred; the simplification is logged/noted,
   not silent.
6. **Agent tools:** Existing color tools gain an optional `clipId`. Omitted → timeline
   grade (unchanged). Provided → that clip's grade.

## Out of scope

- HDR export grading (HEVC Main10 path already skips grading today; unchanged here).
- Per-layer grading through transitions / overlapping clips beyond topmost-wins.
- Replacing or migrating the existing `Timeline.lut` / `Timeline.primaries` format.

## Rendering architecture

The locked stacking order (clip → then timeline) maps onto the existing two-stage
pipeline, so we **bake clip grades into the composition and keep the timeline grade as a
post-pass on top**.

### Preview
- **Today:** `PreviewNSView.applyGrade(primaries:lut:)`
  (`Sources/PalmierPro/Preview/PreviewView.swift:81`) sets `playerLayer.filters` for the
  whole `AVPlayerLayer` from `GradePipeline.filters(primaries:lut:)`.
- **Change:** Keep the layer-filter path for the **timeline** grade. Add an
  `AVVideoComposition` with a Core Image handler that, per frame, looks up the active
  video clip by time, builds a `GradePipeline` chain from that clip's `grade`, and applies
  it. Net effect: composition bakes the clip grade → layer filter applies the timeline
  grade on top. Stacking order falls out for free.
- **Cost to watch:** preview moves from a cheap GPU layer filter to per-frame Core Image
  compositing for clip grades. Standard AVFoundation grading path; expected fine on the
  M-series target, but this is the performance-sensitive part.
- **Text overlays** continue to stay ungraded (they are composited separately, above the
  graded video — the existing guarantee is preserved because the timeline grade remains a
  layer filter under the overlay layers).

### Export (SDR)
- `CompositionBuilder` attaches the same `AVVideoComposition` so clip grades are baked
  into the main encode.
- `LUTExportPass` / `applyLUTPassIfNeeded()`
  (`Sources/PalmierPro/Export/ExportService.swift:229`) continues to apply the **timeline**
  grade as the second pass. No change to the post-pass logic.

### Export (HDR)
- Unchanged. `HDRVideoExporter` still skips grading (pre-existing limitation, explicitly
  out of scope).

### Rejected alternative
Baking **both** clip and timeline grades into the compositor and dropping the layer-filter
path. Cleaner conceptually but discards the working preview path, complicates the
"text overlays stay ungraded" guarantee, and rewrites export's post-pass. Not worth it
for v1.

## Data model

Factor the grade into a reusable value type shared by clip-level state.

**New `ClipGrade`** (in `Sources/PalmierPro/Models/ColorGrade.swift`):

```swift
struct ClipGrade: Codable, Sendable, Equatable {
    var primaries: PrimaryGrade?
    var lut: LUTRef?
    var isIdentity: Bool { primaries == nil && lut == nil }
}
```

**`Clip`** (`Sources/PalmierPro/Models/Timeline.swift`) gains one optional field:

```swift
var grade: ClipGrade?   // nil = no clip grade; renders identically to today
```

- `Timeline.lut` / `Timeline.primaries` stay as-is. No format migration. Old projects load
  with every clip's `grade == nil` and render identically to today — the key compatibility
  win.
- `grade` is **optional** (not default-empty): `nil` is meaningfully distinct from "empty
  grade" for the badge (`clip.grade?.isIdentity == false`), the inspector empty state, and
  keeping `Codable` output small for the common ungraded case.
- **Rejected:** reusing `ClipGrade` for the timeline too (replacing
  `Timeline.lut`/`primaries`). A gratuitous migration touching agent tools and
  serialization for no user benefit.

## UI and selection

### Inspector scope (selection-driven)
- Color inspector reads the current timeline selection:
  - Clip selected → edits `clip.grade`, lazily creating a `ClipGrade` on first edit and
    clearing back to `nil` when reset to identity.
  - Nothing selected → edits `Timeline.primaries` / `Timeline.lut` as today.
- **Scope header** at the top of the inspector: `"Clip — <name>"` vs `"Timeline"`, using
  existing `AppTheme` text tokens.
- `ColorGradeInspector`, `CurveEditorView`, and the LUT panel are rebound from
  "always timeline" to "current grade scope." Introduce a small accessor on the
  EditorViewModel (e.g. `gradingScope`) returning a binding-friendly target so the three
  inspector views don't each duplicate selection logic. This is the one piece of existing
  code tidied while here, since those views currently reach straight into `editor.timeline`.

### Clip badge
- Graded clips (`clip.grade?.isIdentity == false`) show a small grade glyph badge on the
  timeline clip view. Styled with `AppTheme.IconSize.xs` plus existing border/opacity
  tokens.

## Compositor clip lookup

The `AVVideoComposition` Core Image handler receives a frame `time` and maps it to the
active video clip via the same timeline→frame math `CompositionBuilder` already uses to
place clips. It fetches that clip's `grade`, builds a `GradePipeline` filter chain, and
applies it. For overlapping tracks/transitions, v1 grades per-clip in track order
(topmost video clip's grade wins for the region it covers); this simplification is
logged/noted rather than silently chosen.

## Agent tools

Existing tools in `Sources/PalmierPro/Agent/Tools/ToolExecutor+Color.swift`
(`applyColorGrade`, `adjustColor`, `setColorCurve`, `clearColorGrade`) gain an optional
`clipId` parameter:
- Omitted → operates on the timeline grade (today's behavior, unchanged — backward
  compatible for existing agent flows).
- Provided → operates on that clip's `grade`.

## Affected files (reference)

| Area | File |
|---|---|
| Data model — `ClipGrade`, `GradePipeline` | `Sources/PalmierPro/Models/ColorGrade.swift` |
| Data model — `Clip.grade` | `Sources/PalmierPro/Models/Timeline.swift` |
| Preview compositor + layer filter | `Sources/PalmierPro/Preview/PreviewView.swift` |
| Composition build (attach `AVVideoComposition`) | `CompositionBuilder` (composition build path) |
| Export SDR post-pass (unchanged) | `Sources/PalmierPro/Export/ExportService.swift`, `LUTExportPass.swift` |
| Inspector scope + scope header | `Sources/PalmierPro/Inspector/ColorGradeInspector.swift`, `CurveEditorView.swift`, LUT panel |
| EditorViewModel grading scope accessor | `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Color.swift` |
| Clip badge | timeline clip view |
| Agent tools `clipId` | `Sources/PalmierPro/Agent/Tools/ToolExecutor+Color.swift` |

## Testing strategy

- **Data model:** `ClipGrade.isIdentity`; `Clip` round-trip `Codable` with and without a
  grade; old-project decode yields `grade == nil`.
- **Stacking:** a clip grade + timeline grade produces the clip grade applied before the
  timeline grade (verify filter chain order / sampled output).
- **Scope resolution:** selection → correct grade target; reset-to-identity clears
  `clip.grade` back to `nil`.
- **Compositor lookup:** correct clip resolved for a given frame time, including the
  topmost-wins case for overlaps.
- **Agent tools:** `clipId` omitted vs provided routes to timeline vs clip grade.
- **Compatibility:** a project saved before this change loads and renders identically.
