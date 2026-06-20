import Testing
import AVFoundation
import CoreImage
import Foundation
@testable import PalmierPro

@Suite("Clip grade baker")
struct ClipGradeBakerTests {

    @Test func identityGradeReturnsSourceUnchanged() async throws {
        let src = URL(fileURLWithPath: "/tmp/whatever.mov")
        let out = try await ClipGradeBaker.shared.bakedURL(forSource: src, grade: ClipGrade())
        #expect(out == src)
    }

    @Test func cacheKeyIsStableAndGradeSensitive() {
        let src = URL(fileURLWithPath: "/tmp/a.mov")
        var warm = PrimaryGrade(); warm.temperature = 50
        let g1 = ClipGrade(primaries: warm, lut: nil)
        let g2 = ClipGrade(primaries: warm, lut: nil)
        var cool = PrimaryGrade(); cool.temperature = -50
        let g3 = ClipGrade(primaries: cool, lut: nil)

        let k1 = ClipGradeBaker.cacheKey(sourceURL: src, grade: g1)
        let k2 = ClipGradeBaker.cacheKey(sourceURL: src, grade: g2)
        let k3 = ClipGradeBaker.cacheKey(sourceURL: src, grade: g3)
        #expect(k1 == k2)
        #expect(k1 != k3)
    }

    @Test func cacheKeyVariesBySource() {
        var p = PrimaryGrade(); p.temperature = 50
        let g = ClipGrade(primaries: p, lut: nil)
        let a = ClipGradeBaker.cacheKey(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"), grade: g)
        let b = ClipGradeBaker.cacheKey(sourceURL: URL(fileURLWithPath: "/tmp/b.mov"), grade: g)
        #expect(a != b)
    }

    @Test func bakesAndWarmsTheSource() async throws {
        let src = try await Self.makeSolidGrayVideo()
        defer { try? FileManager.default.removeItem(at: src) }

        let base = try Self.averageColor(of: src)

        var warm = PrimaryGrade(); warm.temperature = 80
        let baked = try await ClipGradeBaker.shared.bakedURL(
            forSource: src, grade: ClipGrade(primaries: warm, lut: nil)
        )
        #expect(baked != src)
        #expect(FileManager.default.fileExists(atPath: baked.path))

        let graded = try Self.averageColor(of: baked)
        #expect((graded.r - graded.b) > (base.r - base.b), "warm grade should raise R−B")
    }

    // MARK: - Helpers

    private static func makeSolidGrayVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baker-src-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let size = 32
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let buffer = try makeGrayBuffer(size: size)
        let fps: Int32 = 30
        for frame in 0..<6 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "writer failed: \(String(describing: writer.error))"])
        }
        return url
    }

    private static func makeGrayBuffer(size: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, attrs, &pb)
        guard let buffer = pb else { throw NSError(domain: "test", code: 2) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<size {
            for x in 0..<size {
                let o = y * bytesPerRow + x * 4
                ptr[o] = 128; ptr[o + 1] = 128; ptr[o + 2] = 128; ptr[o + 3] = 255  // BGRA mid-gray
            }
        }
        return buffer
    }

    private static func averageColor(of url: URL) throws -> (r: Double, g: Double, b: Double) {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let cg = try gen.copyCGImage(at: CMTime(value: 1, timescale: 30), actualTime: nil)
        let image = CIImage(cgImage: cg)
        let ctx = CIContext(options: nil)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let f = CIFilter(name: "CIAreaAverage")!
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(CIVector(cgRect: image.extent), forKey: "inputExtent")
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(f.outputImage!, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: srgb)
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }
}
