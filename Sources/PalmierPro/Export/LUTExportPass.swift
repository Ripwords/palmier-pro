import AVFoundation
import CoreImage

/// Grades the flattened export via `applyingCIFiltersWithHandler` (the compositor has no color hook).
/// The filter chain already bakes in LUT intensity, so this is a straight apply.
enum LUTExportPass {
    static func apply(
        processor: ColorGradeProcessor,
        to inputURL: URL,
        fileType: AVFileType,
        preset: String,
        outputURL: URL? = nil,
        renderSize: CGSize? = nil,
        onProgress: (@Sendable (Float) -> Void)? = nil
    ) async throws -> URL {
        let colorSpace = GradePipeline.workingColorSpace
        let asset = AVURLAsset(url: inputURL)

        var videoComposition = try await AVVideoComposition.videoComposition(
            with: asset
        ) { request in
            let graded = processor.process(request.sourceImage.clampedToExtent(), colorSpace: colorSpace)
            request.finish(with: graded.cropped(to: request.sourceImage.extent), context: nil)
        }

        // Downscale the graded output (preview proxies) by overriding the render size.
        if let renderSize, let mutable = videoComposition.mutableCopy() as? AVMutableVideoComposition {
            mutable.renderSize = renderSize
            videoComposition = mutable
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw LUTPassError.unsupportedPreset
        }
        session.videoComposition = videoComposition

        let outputURL = outputURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("grade-pass-\(UUID().uuidString).\(inputURL.pathExtension)")
        try? FileManager.default.removeItem(at: outputURL)

        Log.export.notice("grade-pass start")
        var probe: Task<Void, Never>?
        if let onProgress {
            nonisolated(unsafe) let unsafeSession = session
            probe = Task {
                for await state in unsafeSession.states(updateInterval: 0.2) {
                    if case .exporting(let p) = state { onProgress(Float(p.fractionCompleted)) }
                }
            }
        }
        defer { probe?.cancel() }
        try await session.export(to: outputURL, as: fileType)
        Log.export.notice("grade-pass ok url=\(outputURL.lastPathComponent)")
        return outputURL
    }

    enum LUTPassError: LocalizedError {
        case unsupportedPreset
        var errorDescription: String? {
            switch self {
            case .unsupportedPreset: "Export preset unsupported for the color pass"
            }
        }
    }
}
