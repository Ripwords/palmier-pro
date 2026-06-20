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
