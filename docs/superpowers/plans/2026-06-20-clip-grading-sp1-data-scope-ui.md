# Clip-Based Color Grading — SP1 (Data Model + Scope + UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store an optional per-clip color grade, let the Color inspector edit either the selected clip's grade or the timeline grade (selection-driven), badge graded clips, and let the agent target a clip — with **no change to the render pipeline yet** (clip grades are stored and editable but not visible until SP2).

**Architecture:** A reusable `ClipGrade` value type (primaries + LUT) lives on `Clip` as an optional field. A `GradingScope` abstraction on `EditorViewModel` resolves the current edit target from selection; the Color inspector and curve editor read/write through scope-aware accessors instead of reaching into `timeline.*` directly. Clip-grade mutations register undo but do **not** rebuild the composition (grade isn't rendered in SP1, and we avoid a black-flash on every slider tick — mirroring the existing `setColorPrimaries` lightweight path). The agent's color tools gain an optional `clipId`.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, AVFoundation. Tests use the `swift-testing` framework (`import Testing`, `@Suite`, `@Test`, `#expect`). Build: `swift build`. Test: `swift test`.

## Global Constraints

- **No `any` to fix type errors; no gratuitous `as unknown as`/`as!`.** Prefer correct types.
- **All UI styling uses `AppTheme` constants** (`AppTheme.Spacing.*`, `FontSize.*`, `IconSize.*`, `Text.*`, `Border.*`, `Opacity.*`, etc.). Never hardcode numeric style values; if a token is missing, add it to `Sources/PalmierPro/UI/AppTheme.swift` first.
- **Comments minimal** — one short line only when the *why* is non-obvious. No restating what code does, no change breadcrumbs.
- **Conventional Commits** (`feat:`, `fix:`, `test:`, `chore:`, scope `color`).
- **Voice** (user-facing copy): direct, technical, terse, HIG-style. Lead with the action verb for actions; name the thing for state.
- **No format migration:** `Timeline.lut` / `Timeline.primaries` stay untouched. `Clip.grade` is additive and optional; old projects decode with `grade == nil` and behave exactly as today.
- **TDD:** write the failing test first, watch it fail, implement minimally, watch it pass, commit.

---

### Task 1: `ClipGrade` model + `Clip.grade` field

**Files:**
- Modify: `Sources/PalmierPro/Models/ColorGrade.swift` (add `ClipGrade` after `PrimaryGrade`/before `FilterChainProcessor`)
- Modify: `Sources/PalmierPro/Models/Timeline.swift` (add field + CodingKey + decoder line to `Clip`)
- Test: `Tests/PalmierProTests/Timeline/ClipGradeTests.swift` (create)

**Interfaces:**
- Produces:
  - `struct ClipGrade: Codable, Sendable, Equatable { var primaries: PrimaryGrade?; var lut: LUTRef?; var isIdentity: Bool }`
  - `Clip.grade: ClipGrade?` (new stored property, optional, defaults `nil`)

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/Timeline/ClipGradeTests.swift`:

```swift
import Testing
import Foundation
@testable import PalmierPro

@Suite("ClipGrade model")
struct ClipGradeTests {

    @Test func isIdentityWhenEmpty() {
        #expect(ClipGrade().isIdentity)
        #expect(ClipGrade(primaries: nil, lut: nil).isIdentity)
    }

    @Test func isNotIdentityWithPrimaries() {
        var p = PrimaryGrade()
        p.exposure = 20
        #expect(!ClipGrade(primaries: p, lut: nil).isIdentity)
    }

    @Test func isNotIdentityWithLUT() {
        #expect(!ClipGrade(primaries: nil, lut: .look("warm-cinematic", intensity: 1)).isIdentity)
    }

    @Test func clipRoundTripsWithGrade() throws {
        var clip = Clip(mediaRef: "m1", startFrame: 0, durationFrames: 30)
        var p = PrimaryGrade()
        p.temperature = 30
        clip.grade = ClipGrade(primaries: p, lut: .look("teal-orange", intensity: 0.8))

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)
        #expect(decoded.grade == clip.grade)
    }

    @Test func clipRoundTripsWithoutGrade() throws {
        let clip = Clip(mediaRef: "m1", startFrame: 0, durationFrames: 30)
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)
        #expect(decoded.grade == nil)
    }

    @Test func legacyClipDecodesWithNilGrade() throws {
        // A clip JSON saved before this feature has no "grade" key.
        let json = #"{"id":"c1","mediaRef":"m1","startFrame":0,"durationFrames":30}"#
        let decoded = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(decoded.grade == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClipGradeTests`
Expected: FAIL — `ClipGrade` is undefined / `Clip` has no member `grade`.

- [ ] **Step 3: Add `ClipGrade` to `ColorGrade.swift`**

Insert after `PrimaryGrade` (after line 111, before `FilterChainProcessor`):

```swift
/// Per-clip grade: a local correction (primaries + curves) and look (LUT) that
/// stacks *under* the project-wide timeline grade. `nil` field = none.
struct ClipGrade: Codable, Sendable, Equatable {
    var primaries: PrimaryGrade?
    var lut: LUTRef?

    var isIdentity: Bool {
        (primaries?.isIdentity ?? true) && (lut == nil || lut?.clampedIntensity == 0)
    }
}
```

- [ ] **Step 4: Add `grade` to `Clip`**

In `Sources/PalmierPro/Models/Timeline.swift`:

1. Add the stored property in the `Clip` struct, after `var crop: Crop = Crop()` (line 98):

```swift
    var grade: ClipGrade?
```

2. Add `grade` to `Clip.CodingKeys` (line 118 region) — append to the `opacity, transform, crop` line:

```swift
        case opacity, transform, crop, grade
```

3. Add the decode line in `Clip.init(from:)` after the `crop:` line (line 354):

```swift
            grade: (try? c.decode(ClipGrade.self, forKey: .grade)),
```

Note: the memberwise initializer used by the decoder gains a `grade` parameter automatically (struct synthesises it). Place the `grade:` argument in the same position as the property (after `crop:`). Verify the `self.init(...)` argument order matches the property declaration order.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ClipGradeTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/PalmierPro/Models/ColorGrade.swift Sources/PalmierPro/Models/Timeline.swift Tests/PalmierProTests/Timeline/ClipGradeTests.swift
git commit -m "feat(color): add ClipGrade model and Clip.grade field"
```

---

### Task 2: Grading scope resolution + resolved getters

**Files:**
- Modify: `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Color.swift`
- Test: `Tests/PalmierProTests/Timeline/GradingScopeTests.swift` (create)

**Interfaces:**
- Consumes: `EditorViewModel.selectedClipIds: Set<String>`, `clipFor(id:) -> Clip?`, `mediaAssets: [MediaAsset]` (has `.name`), `timeline.primaries`, `timeline.lut`.
- Produces:
  - `enum GradingScope: Equatable { case timeline; case clip(String) }`
  - `EditorViewModel.gradingScope: GradingScope`
  - `EditorViewModel.gradingScopeLabel: String`
  - `EditorViewModel.gradedPrimaries: PrimaryGrade?` (get)
  - `EditorViewModel.gradedLUT: LUTRef?` (get)

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/Timeline/GradingScopeTests.swift`:

```swift
import Testing
@testable import PalmierPro

@MainActor
@Suite("Grading scope resolution")
struct GradingScopeTests {

    private func editorWithVideoClip() -> (EditorViewModel, String) {
        let vm = EditorViewModel()
        var track = Track(type: .video)
        let clip = Clip(mediaRef: "m1", mediaType: .video, startFrame: 0, durationFrames: 30)
        track.clips = [clip]
        vm.timeline.tracks = [track]
        return (vm, clip.id)
    }

    @Test func timelineScopeWhenNothingSelected() {
        let (vm, _) = editorWithVideoClip()
        vm.selectedClipIds = []
        #expect(vm.gradingScope == .timeline)
        #expect(vm.gradingScopeLabel == "Timeline")
    }

    @Test func clipScopeWhenSingleVideoClipSelected() {
        let (vm, id) = editorWithVideoClip()
        vm.selectedClipIds = [id]
        #expect(vm.gradingScope == .clip(id))
    }

    @Test func timelineScopeWhenMultipleSelected() {
        let (vm, id) = editorWithVideoClip()
        vm.selectedClipIds = [id, "other"]
        #expect(vm.gradingScope == .timeline)
    }

    @Test func timelineScopeForAudioClip() {
        let vm = EditorViewModel()
        var track = Track(type: .audio)
        let clip = Clip(mediaRef: "a1", mediaType: .audio, startFrame: 0, durationFrames: 30)
        track.clips = [clip]
        vm.timeline.tracks = [track]
        vm.selectedClipIds = [clip.id]
        #expect(vm.gradingScope == .timeline)
    }

    @Test func gradedGettersFollowScope() {
        let (vm, id) = editorWithVideoClip()
        var tp = PrimaryGrade(); tp.exposure = 10
        vm.timeline.primaries = tp

        var cp = PrimaryGrade(); cp.contrast = 40
        if let loc = vm.findClip(id: id) {
            vm.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].grade =
                ClipGrade(primaries: cp, lut: nil)
        }

        vm.selectedClipIds = []
        #expect(vm.gradedPrimaries?.exposure == 10)

        vm.selectedClipIds = [id]
        #expect(vm.gradedPrimaries?.contrast == 40)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GradingScopeTests`
Expected: FAIL — `gradingScope` / `GradingScope` undefined.

- [ ] **Step 3: Add scope resolution to `EditorViewModel+Color.swift`**

Append to `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Color.swift` (after the existing `setColorPrimaries`):

```swift
/// What the Color inspector currently edits.
enum GradingScope: Equatable {
    case timeline
    case clip(String)
}

extension EditorViewModel {
    /// A single selected non-audio clip edits that clip's grade; otherwise the timeline grade.
    var gradingScope: GradingScope {
        guard selectedClipIds.count == 1, let id = selectedClipIds.first,
              let clip = clipFor(id: id), clip.mediaType != .audio else {
            return .timeline
        }
        return .clip(id)
    }

    var gradingScopeLabel: String {
        switch gradingScope {
        case .timeline:
            return "Timeline"
        case .clip(let id):
            guard let clip = clipFor(id: id) else { return "Clip" }
            let name = mediaAssets.first(where: { $0.id == clip.mediaRef })?.name
            return name.map { "Clip — \($0)" } ?? "Clip"
        }
    }

    var gradedPrimaries: PrimaryGrade? {
        switch gradingScope {
        case .timeline: return timeline.primaries
        case .clip(let id): return clipFor(id: id)?.grade?.primaries
        }
    }

    var gradedLUT: LUTRef? {
        switch gradingScope {
        case .timeline: return timeline.lut
        case .clip(let id): return clipFor(id: id)?.grade?.lut
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GradingScopeTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Color.swift Tests/PalmierProTests/Timeline/GradingScopeTests.swift
git commit -m "feat(color): resolve grading scope from selection"
```

---

### Task 3: Clip-grade setters with undo (no rebuild) + scope routers

**Files:**
- Modify: `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Color.swift`
- Test: `Tests/PalmierProTests/Timeline/ClipGradeSetterTests.swift` (create)

**Interfaces:**
- Consumes: `findClip(id:)`, `clipFor(id:)`, `undoManager`, `videoEngine?.refreshGrade()`, `GradingScope`, `setColorPrimaries(_:)`, `setColorGrade(_:)` (existing timeline setters).
- Produces:
  - `EditorViewModel.setClipPrimaries(clipId:_:)`
  - `EditorViewModel.setClipLUT(clipId:_:)`
  - `EditorViewModel.setGradedPrimaries(_:)` (routes by scope)
  - `EditorViewModel.setGradedLUT(_:)` (routes by scope)

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/Timeline/ClipGradeSetterTests.swift`:

```swift
import Testing
@testable import PalmierPro

@MainActor
@Suite("Clip grade setters")
struct ClipGradeSetterTests {

    private func editorWithVideoClip() -> (EditorViewModel, String) {
        let vm = EditorViewModel()
        var track = Track(type: .video)
        let clip = Clip(mediaRef: "m1", mediaType: .video, startFrame: 0, durationFrames: 30)
        track.clips = [clip]
        vm.timeline.tracks = [track]
        return (vm, clip.id)
    }

    @Test func setClipPrimariesStoresGrade() {
        let (vm, id) = editorWithVideoClip()
        var p = PrimaryGrade(); p.exposure = 25
        vm.setClipPrimaries(clipId: id, p)
        #expect(vm.clipFor(id: id)?.grade?.primaries?.exposure == 25)
    }

    @Test func identityPrimariesClearsGradeToNil() {
        let (vm, id) = editorWithVideoClip()
        var p = PrimaryGrade(); p.exposure = 25
        vm.setClipPrimaries(clipId: id, p)
        vm.setClipPrimaries(clipId: id, PrimaryGrade())   // identity
        #expect(vm.clipFor(id: id)?.grade == nil)
    }

    @Test func clipLUTAndPrimariesCoexist() {
        let (vm, id) = editorWithVideoClip()
        var p = PrimaryGrade(); p.contrast = 15
        vm.setClipPrimaries(clipId: id, p)
        vm.setClipLUT(clipId: id, .look("warm-cinematic", intensity: 1))
        #expect(vm.clipFor(id: id)?.grade?.primaries?.contrast == 15)
        #expect(vm.clipFor(id: id)?.grade?.lut?.lookID == "warm-cinematic")
    }

    @Test func undoRestoresPreviousGrade() {
        let (vm, id) = editorWithVideoClip()
        let undo = UndoManager()
        vm.undoManager = undo
        var p = PrimaryGrade(); p.exposure = 25
        vm.setClipPrimaries(clipId: id, p)
        undo.undo()
        #expect(vm.clipFor(id: id)?.grade == nil)
    }

    @Test func setGradedPrimariesRoutesToClipOrTimeline() {
        let (vm, id) = editorWithVideoClip()

        vm.selectedClipIds = [id]
        var cp = PrimaryGrade(); cp.saturation = 30
        vm.setGradedPrimaries(cp)
        #expect(vm.clipFor(id: id)?.grade?.primaries?.saturation == 30)
        #expect(vm.timeline.primaries == nil)

        vm.selectedClipIds = []
        var tp = PrimaryGrade(); tp.saturation = -20
        vm.setGradedPrimaries(tp)
        #expect(vm.timeline.primaries?.saturation == -20)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClipGradeSetterTests`
Expected: FAIL — `setClipPrimaries` undefined.

- [ ] **Step 3: Implement the setters**

Append to `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Color.swift`:

```swift
extension EditorViewModel {
    /// Route inspector edits to the current scope's grade.
    func setGradedPrimaries(_ primaries: PrimaryGrade?) {
        switch gradingScope {
        case .timeline: setColorPrimaries(primaries)
        case .clip(let id): setClipPrimaries(clipId: id, primaries)
        }
    }

    func setGradedLUT(_ lut: LUTRef?) {
        switch gradingScope {
        case .timeline: setColorGrade(lut)
        case .clip(let id): setClipLUT(clipId: id, lut)
        }
    }

    func setClipPrimaries(clipId: String, _ primaries: PrimaryGrade?) {
        let next = (primaries?.isIdentity ?? true) ? nil : primaries
        updateClipGrade(clipId: clipId, actionName: "Adjust Clip Color") { $0.primaries = next }
    }

    func setClipLUT(clipId: String, _ lut: LUTRef?) {
        let next = (lut?.clampedIntensity ?? 0) > 0 ? lut : nil
        updateClipGrade(clipId: clipId, actionName: next == nil ? "Clear Clip Grade" : "Apply Clip Grade") {
            $0.lut = next
        }
    }

    /// Mutate a clip's grade, clearing it to nil when the result is identity, and
    /// register a bidirectional undo. No composition rebuild: SP1 doesn't render
    /// clip grades, and per-tick rebuilds would only cause a black flash.
    private func updateClipGrade(clipId: String, actionName: String, _ mutate: (inout ClipGrade) -> Void) {
        guard let loc = findClip(id: clipId) else { return }
        let before = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].grade
        var grade = before ?? ClipGrade()
        mutate(&grade)
        let after: ClipGrade? = grade.isIdentity ? nil : grade
        guard before != after else { return }
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].grade = after
        registerClipGradeSwap(clipId: clipId, undo: before, redo: after, actionName: actionName)
        videoEngine?.refreshGrade()
    }

    private func registerClipGradeSwap(clipId: String, undo: ClipGrade?, redo: ClipGrade?, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { vm in
            if let loc = vm.findClip(id: clipId) {
                vm.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].grade = undo
            }
            vm.registerClipGradeSwap(clipId: clipId, undo: redo, redo: undo, actionName: actionName)
            vm.videoEngine?.refreshGrade()
        }
        undoManager?.setActionName(actionName)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClipGradeSetterTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Color.swift Tests/PalmierProTests/Timeline/ClipGradeSetterTests.swift
git commit -m "feat(color): clip-grade setters with undo and scope routing"
```

---

### Task 4: Rebind Color inspector + curve editor to grading scope, add scope header

**Files:**
- Modify: `Sources/PalmierPro/Inspector/ColorGradeInspector.swift`
- Modify: `Sources/PalmierPro/Inspector/CurveEditorView.swift`

No unit test (SwiftUI view wiring); verified by build + by the scope/setter tests from Tasks 2–3 that back these bindings. Manual check at the end.

- [ ] **Step 1: Add the scope header + rebind `ColorGradeInspector`**

In `Sources/PalmierPro/Inspector/ColorGradeInspector.swift`:

1. Replace the `grade` computed property (line 9) to read scope:

```swift
    private var grade: LUTRef? { editor.gradedLUT }
```

2. Add a scope header as the first child of the top `VStack` (before the `InspectorRow(icon: "camera.filters" …)` at line 16):

```swift
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: editor.gradingScope == .timeline ? "timeline.selection" : "film")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(editor.gradingScopeLabel)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Divider().opacity(AppTheme.Opacity.faint)
```

3. Rebind every timeline access to the scope accessors. Apply these exact replacements:

- Line 56 `editor.setColorGrade(nil)` → `editor.setGradedLUT(nil)`
- Line 91 `editor.setColorGrade(nil)` → `editor.setGradedLUT(nil)`
- In `primaryBinding` (lines 142–147): `editor.timeline.primaries` → `editor.gradedPrimaries` (both occurrences), and `editor.setColorPrimaries(p)` → `editor.setGradedPrimaries(p)`.
- In `sliderRow` (line 131): `editor.timeline.primaries?[keyPath: kp]` → `editor.gradedPrimaries?[keyPath: kp]`.
- In `lookBinding` (lines 158–164): `grade?...` already uses `grade` (now scoped). Replace `editor.setColorGrade(nil)` → `editor.setGradedLUT(nil)` and `editor.setColorGrade(.look(...))` → `editor.setGradedLUT(.look(...))`.
- In `intensityBinding` (lines 171–175): `editor.timeline.lut` → `editor.gradedLUT`; `editor.setColorGrade(updated)` → `editor.setGradedLUT(updated)`.
- In `applyCube` (line 193): `editor.setColorGrade(.cube(...))` → `editor.setGradedLUT(.cube(...))`.
- "Reset adjustments" block (lines 113–120): `editor.timeline.primaries != nil` → `editor.gradedPrimaries != nil`; `editor.setColorPrimaries(nil)` → `editor.setGradedPrimaries(nil)`.

- [ ] **Step 2: Rebind `CurveEditorView`**

In `Sources/PalmierPro/Inspector/CurveEditorView.swift`:

- `channelPoints` (line 137): `editor.timeline.primaries?.curve` → `editor.gradedPrimaries?.curve`.
- `commit(_:)` (line 184): `editor.timeline.primaries ?? PrimaryGrade()` → `editor.gradedPrimaries ?? PrimaryGrade()`, and `editor.setColorPrimaries(p)` → `editor.setGradedPrimaries(p)`.

The histogram (`refreshHistogram`) stays as-is — it samples the playhead frame and is scope-independent.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Manual verification**

Run: `swift run`
Verify:
1. With nothing selected, the Color inspector header reads "Timeline" and editing sliders affects the timeline grade (preview changes — timeline grade still renders via the existing layer filter).
2. Select a single video clip → header reads "Clip — <name>". Adjusting a slider stores on the clip (no crash, no black flash). Preview does **not** change yet (expected; clip grades render in SP2).
3. Deselect → header returns to "Timeline" and shows the timeline grade values.
4. Undo (⌘Z) after a clip edit reverts the clip's grade.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Inspector/ColorGradeInspector.swift Sources/PalmierPro/Inspector/CurveEditorView.swift
git commit -m "feat(color): scope Color inspector to selected clip or timeline"
```

---

### Task 5: Badge graded clips on the timeline

**Files:**
- Modify: `Sources/PalmierPro/Models/Timeline.swift` (add `Clip.hasVisibleGrade` predicate)
- Modify: `Sources/PalmierPro/Timeline/ClipRenderer.swift` (draw the badge)
- Test: `Tests/PalmierProTests/Timeline/ClipGradeBadgeTests.swift` (create — predicate only)

**Interfaces:**
- Produces: `Clip.hasVisibleGrade: Bool` (true when `grade != nil && !grade.isIdentity`).

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/Timeline/ClipGradeBadgeTests.swift`:

```swift
import Testing
@testable import PalmierPro

@Suite("Clip grade badge predicate")
struct ClipGradeBadgeTests {

    @Test func noBadgeWithoutGrade() {
        let clip = Clip(mediaRef: "m1", startFrame: 0, durationFrames: 30)
        #expect(!clip.hasVisibleGrade)
    }

    @Test func noBadgeForIdentityGrade() {
        var clip = Clip(mediaRef: "m1", startFrame: 0, durationFrames: 30)
        clip.grade = ClipGrade(primaries: PrimaryGrade(), lut: nil)
        #expect(!clip.hasVisibleGrade)
    }

    @Test func badgeWhenGraded() {
        var clip = Clip(mediaRef: "m1", startFrame: 0, durationFrames: 30)
        var p = PrimaryGrade(); p.exposure = 10
        clip.grade = ClipGrade(primaries: p, lut: nil)
        #expect(clip.hasVisibleGrade)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClipGradeBadgeTests`
Expected: FAIL — `hasVisibleGrade` undefined.

- [ ] **Step 3: Add the predicate**

In `Sources/PalmierPro/Models/Timeline.swift`, add to the `Clip` computed-property area (near `endFrame`, line 124):

```swift
    /// True when the clip carries a non-identity grade — drives the timeline badge.
    var hasVisibleGrade: Bool {
        guard let grade else { return false }
        return !grade.isIdentity
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClipGradeBadgeTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Draw the badge in `ClipRenderer`**

`ClipRenderer` is an AppKit Core Graphics renderer drawing into a `CGContext` for an `NSRect` clip body. Locate the main per-clip draw function (the one that receives the clip and its `rect: NSRect` and draws the body/label — the same function that calls the fade/keyframe overlays around lines 320–360). At the end of that function, after the existing overlays, add a guarded badge draw:

```swift
        if clip.hasVisibleGrade {
            drawGradeBadge(in: rect, ctx: ctx, alpha: alpha)
        }
```

Then add the helper (alongside the other `private static func` overlay drawers). It draws a small filled circle with a contrasting ring in the top-right of the clip body, using `AppTheme` tokens — no SF Symbol (this is a raw CG context):

```swift
    /// Small grade indicator dot in the clip's top-right corner.
    private static func drawGradeBadge(in rect: NSRect, ctx: CGContext, alpha: CGFloat) {
        let d = AppTheme.IconSize.xs
        let inset = AppTheme.Spacing.xxs
        let badgeRect = CGRect(
            x: rect.maxX - d - inset,
            y: rect.maxY - d - inset,
            width: d, height: d
        )
        ctx.saveGState()
        ctx.setFillColor(AppTheme.Accent.primary.withAlphaComponent(alpha).cgColor)
        ctx.fillEllipse(in: badgeRect)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha * AppTheme.Opacity.strong).cgColor)
        ctx.setLineWidth(AppTheme.BorderWidth.thin)
        ctx.strokeEllipse(in: badgeRect.insetBy(dx: AppTheme.BorderWidth.thin / 2, dy: AppTheme.BorderWidth.thin / 2))
        ctx.restoreGState()
    }
```

Notes for the implementer:
- Match the surrounding code's parameter names: if the draw function exposes the context as `ctx` and an `alpha` for dimming, reuse them; if it uses a different name (e.g. `context`), adapt the call and helper signature to match exactly.
- `AppTheme.IconSize.xs`, `AppTheme.Spacing.xxs`, `AppTheme.BorderWidth.thin`, `AppTheme.Opacity.strong`, and `AppTheme.Accent.primary` must all exist — confirm in `Sources/PalmierPro/UI/AppTheme.swift`. If any is missing, add it there (don't hardcode).

- [ ] **Step 6: Build + manual check**

Run: `swift build`
Then `swift run`: grade a clip → a small accent dot appears in its top-right on the timeline; remove the grade (reset adjustments / clear) → the dot disappears.

- [ ] **Step 7: Commit**

```bash
git add Sources/PalmierPro/Models/Timeline.swift Sources/PalmierPro/Timeline/ClipRenderer.swift Tests/PalmierProTests/Timeline/ClipGradeBadgeTests.swift
git commit -m "feat(color): badge clips that carry a grade"
```

---

### Task 6: Agent `clipId` targeting for color tools

**Files:**
- Modify: `Sources/PalmierPro/Agent/Tools/ToolExecutor+Color.swift`
- Modify: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift` (add `clipId` param to the 4 color tools' schemas)
- Test: `Tests/PalmierProTests/Agent/ColorToolClipIdTests.swift` (create)

**Interfaces:**
- Consumes: `setGradedPrimaries`/`setGradedLUT` are *not* used here (the agent passes an explicit id, not the UI selection). Instead use `setClipPrimaries(clipId:_:)`, `setClipLUT(clipId:_:)` (Task 3) and the existing `setColorPrimaries`/`setColorGrade` for the timeline path. Reads `clipFor(id:)` to validate the id and to seed edits from existing clip primaries.
- Produces: `applyColorGrade`, `clearColorGrade`, `adjustColor`, `setColorCurve` accept optional `clipId`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/Agent/ColorToolClipIdTests.swift`:

```swift
import Testing
@testable import PalmierPro

@MainActor
@Suite("Agent color tools clipId targeting")
struct ColorToolClipIdTests {

    private func setup() -> (ToolExecutor, EditorViewModel, String) {
        let vm = EditorViewModel()
        var track = Track(type: .video)
        let clip = Clip(mediaRef: "m1", mediaType: .video, startFrame: 0, durationFrames: 30)
        track.clips = [clip]
        vm.timeline.tracks = [track]
        let exec = ToolExecutor(editor: vm)
        return (exec, vm, clip.id)
    }

    @Test func adjustColorWithClipIdTargetsClip() throws {
        let (exec, vm, id) = setup()
        _ = try exec.adjustColor(vm, ["clipId": id, "exposure": 30.0])
        #expect(vm.clipFor(id: id)?.grade?.primaries?.exposure == 30)
        #expect(vm.timeline.primaries == nil)
    }

    @Test func adjustColorWithoutClipIdTargetsTimeline() throws {
        let (exec, vm, _) = setup()
        _ = try exec.adjustColor(vm, ["exposure": -15.0])
        #expect(vm.timeline.primaries?.exposure == -15)
    }

    @Test func applyColorGradeWithClipIdTargetsClip() throws {
        let (exec, vm, id) = setup()
        _ = try exec.applyColorGrade(vm, ["clipId": id, "look": "warm-cinematic"])
        #expect(vm.clipFor(id: id)?.grade?.lut?.lookID == "warm-cinematic")
        #expect(vm.timeline.lut == nil)
    }

    @Test func unknownClipIdThrows() {
        let (exec, vm, _) = setup()
        #expect(throws: ToolError.self) {
            _ = try exec.adjustColor(vm, ["clipId": "nope", "exposure": 10.0])
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ColorToolClipIdTests`
Expected: FAIL — current tools ignore `clipId`, so the clip assertions fail (grade stays nil, timeline gets set).

- [ ] **Step 3: Add a clip-id resolver + route each tool**

In `Sources/PalmierPro/Agent/Tools/ToolExecutor+Color.swift`, add a helper at the top of the `extension ToolExecutor` (after `listColorGrades`):

```swift
    /// Validates an optional `clipId`. Returns nil for the timeline scope, or throws if the id is unknown.
    private func resolveColorTarget(_ args: [String: Any], _ editor: EditorViewModel) throws -> String? {
        guard let id = (args["clipId"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
            return nil
        }
        guard editor.clipFor(id: id) != nil else {
            throw ToolError("clipId not found: \(id)")
        }
        return id
    }
```

Then update each tool to branch on the resolved target:

1. `applyColorGrade` — replace the `editor.setColorGrade(ref)` line (line 38) with:

```swift
        if let clipId = try resolveColorTarget(args, editor) {
            editor.setClipLUT(clipId: clipId, ref)
        } else {
            editor.setColorGrade(ref)
        }
```

2. `clearColorGrade` — change its signature to accept args and branch:

```swift
    func clearColorGrade(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        if let clipId = try resolveColorTarget(args, editor) {
            editor.setClipLUT(clipId: clipId, nil)
        } else {
            editor.setColorGrade(nil)
        }
        return .ok(Self.jsonString(["cleared": true]) ?? "{}")
    }
```

Update the dispatch in `ToolExecutor.swift` (line 106) to `return try clearColorGrade(editor, args)`.

3. `adjustColor` — change the seed source and the commit. Replace `var p = editor.timeline.primaries ?? PrimaryGrade()` (line 50) with:

```swift
        let clipId = try resolveColorTarget(args, editor)
        var p = (clipId.flatMap { editor.clipFor(id: $0)?.grade?.primaries } ?? editor.timeline.primaries) ?? PrimaryGrade()
```

Replace `editor.setColorPrimaries(p)` (line 68) with:

```swift
        if let clipId {
            editor.setClipPrimaries(clipId: clipId, p)
        } else {
            editor.setColorPrimaries(p)
        }
```

4. `setColorCurve` — replace `var p = editor.timeline.primaries ?? PrimaryGrade()` (line 95) with:

```swift
        let clipId = try resolveColorTarget(args, editor)
        var p = (clipId.flatMap { editor.clipFor(id: $0)?.grade?.primaries } ?? editor.timeline.primaries) ?? PrimaryGrade()
```

Replace `editor.setColorPrimaries(p)` (line 105) with:

```swift
        if let clipId {
            editor.setClipPrimaries(clipId: clipId, p)
        } else {
            editor.setColorPrimaries(p)
        }
```

- [ ] **Step 4: Add `clipId` to the tool schemas**

In `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift`, find the schema definitions for `apply_color_grade`, `clear_color_grade`, `adjust_color`, and `set_color_curve`. Add an optional `clipId` string property to each (not in the `required` list), following the existing property-definition style in that file. Example shape to match the file's existing convention:

```swift
"clipId": ["type": "string", "description": "Optional. Target this clip's grade instead of the timeline grade. Omit for the project-wide timeline grade."]
```

Implementer: mirror the exact dictionary/struct format already used for other optional params in that file (e.g. how `intensity` or `reset` are declared). Do not invent a new schema style.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ColorToolClipIdTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Run the full suite + build**

Run: `swift build && swift test`
Expected: build clean; all tests pass (no regressions in existing agent/color tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/PalmierPro/Agent/Tools/ToolExecutor+Color.swift Sources/PalmierPro/Agent/Tools/ToolExecutor.swift Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift Tests/PalmierProTests/Agent/ColorToolClipIdTests.swift
git commit -m "feat(color): let agent color tools target a clip via clipId"
```

---

## Out of scope for SP1 (handled in SP2 / SP3)

- Rendering clip grades in preview/export. SP1 stores and edits them; they become visible only with the custom video compositor (SP2) and export wiring (SP3). The manual checks above explicitly note preview does not yet reflect clip grades.
- The custom `GradingVideoCompositor` and frame-parity gate — see the spec's delivery decomposition.

## Self-Review notes

- **Spec coverage:** ClipGrade + Clip.grade (Task 1) ✓; selection-driven scope + header (Tasks 2, 4) ✓; stacking model — clip grade stored separately from timeline, no migration (Task 1) ✓; clip badge (Task 5) ✓; agent clipId (Task 6) ✓. Rendering (compositor) is deliberately deferred to SP2 per the spec's decomposition.
- **Type consistency:** `setClipPrimaries(clipId:_:)` / `setClipLUT(clipId:_:)` defined in Task 3 are the exact names consumed in Task 6; `gradedPrimaries`/`gradedLUT`/`gradingScope`/`gradingScopeLabel` from Task 2 are the exact names consumed in Task 4; `Clip.hasVisibleGrade` from Task 5 step 3 is consumed in step 5.
- **Compatibility:** legacy decode test (Task 1) guards the no-migration guarantee.
