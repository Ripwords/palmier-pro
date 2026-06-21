import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import PalmierPro

/// HDR export must apply the timeline grade and bake in text titles, like the SDR path.
@Suite("HDR grade + text")
@MainActor
struct HDRGradeTextTests {

    private func render(format: ExportFormat, grade: PrimaryGrade?, title: Bool) async throws -> CGImage {
        let renderSize = CGSize(width: 1280, height: 720)
        let blackURL = try await ImageVideoGenerator.blackVideo(size: renderSize)
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: "bg-media", name: "black", type: .video,
            source: .external(absolutePath: blackURL.path), duration: 30.0
        )]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        let bg = Fixtures.clip(id: "bg", mediaRef: "bg-media", start: 0, duration: 60)
        var tracks = [Fixtures.videoTrack(clips: [bg])]
        if title {
            var t = Fixtures.clip(id: "t1", mediaRef: "", mediaType: .text, start: 0, duration: 60)
            t.textContent = "HELLO"
            var st = TextStyle(); st.fontSize = 200; t.textStyle = st
            tracks.append(Fixtures.videoTrack(clips: [t]))
        }
        var timeline = Fixtures.timeline(tracks: tracks)
        timeline.width = 1280; timeline.height = 720
        timeline.primaries = grade

        let ext = format == .hevcHDR ? "mov" : "mp4"
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hgt-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let svc = ExportService()
        await svc.export(timeline: timeline, resolver: resolver,
                         format: format, resolution: .r720p, outputURL: outURL)
        #expect(svc.error == nil, "error: \(svc.error ?? "")")

        let asset = AVURLAsset(url: outURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        return try await gen.image(at: CMTime(seconds: 1.0, preferredTimescale: 30)).image
    }

    private func peakLuma(_ cg: CGImage) -> Int {
        let w = cg.width, h = cg.height, bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var peak = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let l = Int(buf[i]) + Int(buf[i+1]) + Int(buf[i+2])
            if l > peak { peak = l }
        }
        return peak
    }

    private var liftGrade: PrimaryGrade {
        var g = PrimaryGrade()
        g.curve = GradeCurve(master: [CurvePoint(x: 0, y: 0.4), CurvePoint(x: 1, y: 1)])
        return g
    }

    @Test func hdrBakesTextTitle() async throws {
        let peak = peakLuma(try await render(format: .hevcHDR, grade: nil, title: true))
        print("HDR-TEXT peak=\(peak)")
        #expect(peak > 150, "HDR title missing (peak=\(peak))")
    }

    @Test func hdrAppliesTimelineGrade() async throws {
        let peak = peakLuma(try await render(format: .hevcHDR, grade: liftGrade, title: false))
        print("HDR-GRADE peak=\(peak)")
        #expect(peak > 80, "HDR grade not applied — black not lifted (peak=\(peak))")
    }
}
