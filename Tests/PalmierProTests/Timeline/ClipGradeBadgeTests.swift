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
