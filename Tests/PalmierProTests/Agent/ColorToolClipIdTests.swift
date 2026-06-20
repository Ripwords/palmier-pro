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

    @Test func clipGradeDoesNotInheritTimelineGrade() throws {
        let (exec, vm, id) = setup()
        var tp = PrimaryGrade(); tp.exposure = 50
        vm.timeline.primaries = tp
        _ = try exec.adjustColor(vm, ["clipId": id, "temperature": 20.0])
        let clipGrade = vm.clipFor(id: id)?.grade?.primaries
        #expect(clipGrade?.temperature == 20)
        #expect(clipGrade?.exposure == 0, "must not copy the timeline's exposure onto the clip")
    }

    @Test func gradingAudioClipThrows() {
        let vm = EditorViewModel()
        var track = Track(type: .audio)
        let clip = Clip(mediaRef: "a1", mediaType: .audio, startFrame: 0, durationFrames: 30)
        track.clips = [clip]
        vm.timeline.tracks = [track]
        let exec = ToolExecutor(editor: vm)
        #expect(throws: ToolError.self) {
            _ = try exec.adjustColor(vm, ["clipId": clip.id, "exposure": 10.0])
        }
    }
}
