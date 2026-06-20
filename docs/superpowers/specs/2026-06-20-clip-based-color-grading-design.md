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

> **Revision 2 (implementation outcome):** the custom-compositor approach below was
> **abandoned during implementation** for two concrete, code-verified reasons:
> (1) a `customVideoCompositorClass` disables `AVVideoCompositionCoreAnimationTool`
> (`ExportService.makeExportSession`), which bakes text into exports — using it would
> silently drop text from every export; (2) it would require reimplementing the entire
> proven transform/opacity/crop/PiP geometry path. **Shipped instead: pre-baked graded
> intermediates** (the rejected-alternative below, revived). `ClipGradeBaker` bakes each
> graded clip's *source* into a cached temp asset; `CompositionBuilder.loadSource` inserts
> the graded copy in place of the original. Because `CompositionBuilder` derives all
> geometry from whatever track it inserts, the composition geometry and the text-export
> `CoreAnimationTool` are untouched — zero regression — and clip grades render in preview
> and SDR export through the existing pipeline. Cost: a re-bake on grade edits, mitigated
> by an in-actor + on-disk cache keyed by `(sourcePath, grade)` and a debounced rebuild.
> HDR export opts out (`build(bakeGrades: false)`) so HDR is unchanged per scope. The
> stacking order is preserved: clip grade baked into the source, timeline grade still the
> post-pass on top. The sections below are retained as the original design record.

The locked stacking order (clip → then timeline): **clip grades are baked into the
composited frame by a custom video compositor; the timeline grade stays a post-pass on
top** (preview `CALayer.filters`, export second pass). Both preview and export render
through the same compositor, so they match.

### Why a custom compositor (correction to original assumption)

The original spec assumed we could attach an `AVVideoComposition` "with a Core Image
handler" to bake clip grades while keeping the existing per-clip transforms/opacity/crop.
**That is not possible in AVFoundation.** The two construction paths are mutually
exclusive:

- `AVVideoComposition(configuration:)` + `AVVideoCompositionLayerInstruction`s → the
  built-in compositor. This is what `CompositionBuilder.buildVisuals`
  (`CompositionBuilder.swift:375`) uses today for all geometry (transform/opacity ramps,
  crop, PiP stacking, black background). It has **no color hook**.
- `AVVideoComposition.videoComposition(with:applyingCIFiltersWithHandler:)` → a CI color
  hook, but it **discards layer instructions** and hands you a single flattened source
  image (no transforms/opacity/crop).

You cannot have both on one composition. Per-clip CI grading that respects geometry
therefore requires a **custom `AVVideoCompositing` compositor** that does the geometry
*and* the per-clip grade itself. Today's preview global grade is a whole-layer
`CALayer.filters` pass (`PreviewView.swift:81`); a single layer filter cannot grade just
one clip's pixels when clips overlap (PiP / multi-track), which is the second reason the
layer-filter approach can't carry clip grades.

### Custom compositor design

A new `GradingVideoCompositor: NSObject, AVVideoCompositing` replaces the built-in
compositor for the project's video composition. Per frame request it:

1. Reads each video composition track's source frame via
   `request.sourceFrame(byTrackID:)`.
2. From a per-time-range custom instruction
   (`GradingCompositionInstruction: AVVideoCompositionInstructionProtocol`) carrying the
   resolved render info, for each active clip **bottom track → top track**:
   - applies the clip's `preferredTransform` normalization (`clipTransforms`), crop
     (`clip.cropAt(frame:)`), and placement affine
     (`CompositionBuilder.affineTransform(for: clip.transformAt(frame:), …)`) — the **same
     math** the built-in path uses, reused, not reinvented;
   - applies the clip's grade via `GradePipeline.filters(primaries:lut:)` built from
     `clip.grade` (identity → skip);
   - applies opacity (`clip.opacityAt(frame:)`) and composites source-over onto the
     accumulator.
3. Returns the composited buffer via `request.finish(withComposedVideoFrame:)`.

Sampling per-frame directly (`clip.transformAt(frame:)`, `opacityAt`, `cropAt`) replaces
the built-in path's ramp emission — simpler and frame-exact. The timeline grade is **not**
applied here; it stays the post-pass.

**Parity gate (risk control):** the compositor is a rewrite of a proven path, so geometry
correctness is validated by rendering identical frames with **no grades present** through
both the old built-in composition and the new compositor and asserting they match within a
small per-pixel tolerance. The new compositor does not ship until parity holds. See the
plan's frame-parity task.

### Text overlays
Unchanged. Text composites via a separate `CALayer` tree above the player layer
(`PreviewNSView`), so it stays ungraded; the timeline grade remains a layer filter under
the overlay layers.

### Export (SDR)
- The export composition uses the same `GradingVideoCompositor`
  (`videoComposition.customVideoCompositorClass`), so clip grades bake into the main
  encode with correct geometry.
- `LUTExportPass` / `applyLUTPassIfNeeded()`
  (`Sources/PalmierPro/Export/ExportService.swift:229`) continues to apply the **timeline**
  grade as the second pass. No change to the post-pass logic.

### Export (HDR)
- Unchanged. `HDRVideoExporter` still skips grading (pre-existing limitation, explicitly
  out of scope).

### Rejected alternatives
- **CI-filter-handler composition** (original assumption): impossible alongside the
  geometry layer instructions, as above.
- **Pre-baked graded intermediates** (render each graded clip's source to a temp asset,
  point the composition at it): correct and geometry-free, but re-renders on every grade
  edit — interactive slider/curve dragging would not be live. Rejected for the custom
  compositor, which grades in the live render path.
- **Export-only v1** (clip grades bake only at export, preview shows timeline grade only):
  smallest, but preview gives no feedback on clip grades. Rejected — weakens the workflow
  this feature exists to strengthen.

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

## Compositor clip resolution

The custom compositor resolves, per frame request time, the active clip on **each** video
composition track (clips within a track are sequential, so exactly one is active per
track at a time) using the same timeline→frame math `CompositionBuilder` already uses. It
applies each active clip's geometry + grade and composites bottom-track → top-track, so a
PiP/overlay clip is graded independently of the clip beneath it — correct overlap
handling, not just "topmost wins." Transitions (cross-track blends) are out of scope for
v1 and grade per their own clip; this is noted, not silently chosen.

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
| Custom compositor (new) | `Sources/PalmierPro/Preview/GradingVideoCompositor.swift` (new), `GradingCompositionInstruction.swift` (new) |
| Composition build (attach compositor) | `Sources/PalmierPro/Preview/CompositionBuilder.swift` (`buildVisuals`) |
| Preview timeline-grade layer filter (unchanged role) | `Sources/PalmierPro/Preview/PreviewView.swift` |
| Export SDR post-pass (unchanged) | `Sources/PalmierPro/Export/ExportService.swift`, `LUTExportPass.swift` |
| Inspector scope + scope header | `Sources/PalmierPro/Inspector/ColorGradeInspector.swift`, `CurveEditorView.swift`, LUT panel |
| EditorViewModel grading scope accessor | `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Color.swift` |
| Clip badge | timeline clip view |
| Agent tools `clipId` | `Sources/PalmierPro/Agent/Tools/ToolExecutor+Color.swift` |

## Delivery decomposition

Because the custom compositor is a large rewrite of a proven render path, the work splits
into three sub-projects, each with its own implementation plan and each independently
reviewable:

1. **SP1 — Data model + scope plumbing + UI** (this spec's first plan). `ClipGrade`,
   `Clip.grade`, EditorViewModel grading-scope accessor, inspector rebinding + scope
   header, clip badge, agent `clipId`. No render-pipeline change; clip grades are stored
   and editable but not yet visible. Fully unit-testable on its own.
2. **SP2 — Custom video compositor.** `GradingVideoCompositor` +
   `GradingCompositionInstruction`, wired into `buildVisuals`, gated by the frame-parity
   test, then layering in per-clip grade. Makes clip grades visible in preview.
3. **SP3 — Export integration.** Wire the compositor into the SDR export composition;
   timeline-grade post-pass unchanged; HDR still out of scope.

SP2 gets its own brainstorm/spec pass before implementation, since its risk and surface
area warrant dedicated design (compositor color management, performance, parity).

## Testing strategy

- **Data model:** `ClipGrade.isIdentity`; `Clip` round-trip `Codable` with and without a
  grade; old-project decode yields `grade == nil`.
- **Stacking:** a clip grade + timeline grade produces the clip grade applied before the
  timeline grade (verify filter chain order / sampled output).
- **Scope resolution:** selection → correct grade target; reset-to-identity clears
  `clip.grade` back to `nil`.
- **Agent tools:** `clipId` omitted vs provided routes to timeline vs clip grade.
- **Compatibility:** a project saved before this change loads and renders identically.
- **Compositor (SP2):** frame-parity — no-grade render through old vs new compositor
  matches within tolerance; per-clip grade resolution selects the active clip per track at
  a given time; a graded PiP clip is graded independently of the clip beneath it.
