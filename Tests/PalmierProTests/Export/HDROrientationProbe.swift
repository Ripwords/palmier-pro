import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("HDR orientation probe")
@MainActor
struct HDROrientationProbe {
    /// Bright-pixel centroid in normalized image space (x→right, y→down from top).
    private func centroid(format: ExportFormat) async throws -> (x: Double, y: Double) {
        let renderSize = CGSize(width: 1280, height: 720)
        let blackURL = try await ImageVideoGenerator.blackVideo(size: renderSize)
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "bg", name: "b", type: .video,
            source: .external(absolutePath: blackURL.path), duration: 30.0)]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })
        let bg = Fixtures.clip(id: "bg", mediaRef: "bg", start: 0, duration: 60)
        var t = Fixtures.clip(id: "t1", mediaRef: "", mediaType: .text, start: 0, duration: 60)
        t.textContent = "L"
        var st = TextStyle(); st.fontSize = 120; t.textStyle = st
        // place marker upper-left: centerX small, centerY small
        t.transform = Transform(centerX: 0.2, centerY: 0.2, width: 0.2, height: 0.2)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [bg]), Fixtures.videoTrack(clips: [t])])
        timeline.width = 1280; timeline.height = 720
        let ext = format == .hevcHDR ? "mov" : "mp4"
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ori-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: outURL) }
        let svc = ExportService()
        await svc.export(timeline: timeline, resolver: resolver, format: format, resolution: .r720p, outputURL: outURL)
        #expect(svc.error == nil, "\(svc.error ?? "")")
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: outURL))
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let cg = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 30)).image
        let w = cg.width, h = cg.height, bpr = w*4
        var buf = [UInt8](repeating: 0, count: bpr*h)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<h { for x in 0..<w {
            let i = y*bpr + x*4
            let l = Int(buf[i])+Int(buf[i+1])+Int(buf[i+2])
            if l > 300 { sx += Double(x); sy += Double(y); n += 1 }
        }}
        guard n > 0 else { return (-1, -1) }
        return (sx/n/Double(w), sy/n/Double(h))
    }

    /// HDR titles must land where the SDR path puts them — guards against axis flips.
    @Test func hdrTitleMatchesSDROrientation() async throws {
        let ref = try await centroid(format: .h264)
        let hdr = try await centroid(format: .hevcHDR)
        print(String(format: "ORIENT h264=(%.2f,%.2f) hdr=(%.2f,%.2f)", ref.x, ref.y, hdr.x, hdr.y))
        #expect(ref.x > 0 && hdr.x > 0, "title not found in one of the exports")
        #expect(abs(ref.x - hdr.x) < 0.05, "horizontal flip: h264 x=\(ref.x) hdr x=\(hdr.x)")
        #expect(abs(ref.y - hdr.y) < 0.05, "vertical flip: h264 y=\(ref.y) hdr y=\(hdr.y)")
    }
}
