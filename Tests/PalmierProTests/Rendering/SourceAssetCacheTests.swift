import Testing
import AVFoundation
import Foundation
@testable import PalmierPro

@Suite("Source asset cache")
struct SourceAssetCacheTests {

    @Test func returnsSameInstanceOnRepeatLoad() async throws {
        let url = try await Self.makeTinyVideo()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try #require(await SourceAssetCache.shared.assetAndTrack(url: url, mediaType: .video))
        let second = try #require(await SourceAssetCache.shared.assetAndTrack(url: url, mediaType: .video))
        #expect(first.asset === second.asset, "asset instance should be reused from cache")
        #expect(first.track === second.track, "track instance should be reused from cache")
    }

    @Test func missingFileReturnsNil() async {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mov")
        let result = await SourceAssetCache.shared.assetAndTrack(url: url, mediaType: .video)
        #expect(result == nil)
    }

    private static func makeTinyVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sac-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        for f in 0..<3 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 500_000) }
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        input.markAsFinished(); await writer.finishWriting()
        return url
    }
}
