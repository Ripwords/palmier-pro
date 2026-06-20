import Testing
import Foundation
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
