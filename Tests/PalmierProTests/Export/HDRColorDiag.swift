import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import PalmierPro

/// Diagnostic: a 50% grey must be CONVERTED to HLG (not relabeled), or HDR blows out.
@Suite("HDR color diagnostic")
@MainActor
struct HDRColorDiag {
    private func greyImageURL(_ size: CGSize) throws -> URL {
        let w = Int(size.width), h = Int(size.height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cg = ctx.makeImage()!
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grey-\(UUID().uuidString).png")
        let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, cg, nil); CGImageDestinationFinalize(dst)
        return url
    }
    private func centerGrey(_ url: URL) async throws -> (g: Int, transfer: String) {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out); reader.startReading()
        guard let s = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(s) else { return (-1, "none") }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let g = Int(base[(h/2)*bpr + (w/2)*4 + 1])
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        var xf = "?"
        if let fmt = try await track.load(.formatDescriptions).first,
           let e = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_TransferFunction) { xf = "\(e)" }
        return (g, xf)
    }
    private func exportGrey(_ format: ExportFormat) async throws -> URL {
        let size = CGSize(width: 640, height: 360)
        let greyURL = try greyImageURL(size)
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "grey", name: "g", type: .image,
            source: .external(absolutePath: greyURL.path), duration: 5.0)]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })
        let clip = Fixtures.clip(id: "c", mediaRef: "grey", mediaType: .image, start: 0, duration: 30)
        var tl = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]); tl.width = 640; tl.height = 360
        let ext = format == .hevcHDR ? "mov" : "mp4"
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cd-\(UUID().uuidString).\(ext)")
        let svc = ExportService()
        await svc.export(timeline: tl, resolver: resolver, format: format, resolution: .r720p, outputURL: outURL)
        #expect(svc.error == nil, "\(svc.error ?? "")")
        return outURL
    }
    @Test func greyIsConvertedNotRelabeled() async throws {
        let sdr = try await centerGrey(try await exportGrey(.h264))
        let hdr = try await centerGrey(try await exportGrey(.hevcHDR))
        print("CD sdr g=\(sdr.g) xf=\(sdr.transfer) | hdr g=\(hdr.g) xf=\(hdr.transfer)")
        #expect(hdr.transfer.contains("HLG"))
        #expect(hdr.g <= sdr.g + 6, "HDR grey blown out (hdr=\(hdr.g) sdr=\(sdr.g))")
        #expect(hdr.g > 60, "HDR grey crushed (hdr=\(hdr.g))")
    }
}
