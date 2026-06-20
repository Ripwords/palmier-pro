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
        let json = #"{"id":"c1","mediaRef":"m1","startFrame":0,"durationFrames":30}"#
        let decoded = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(decoded.grade == nil)
    }
}
