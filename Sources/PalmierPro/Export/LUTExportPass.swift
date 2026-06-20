import AVFoundation
import CoreImage

/// Applies a project LUT to an already-rendered video file as a second pass.
///
/// Design: the main compositor (`CompositionBuilder`) stays a pure
/// `AVVideoCompositionLayerInstruction` pipeline — which has no color hook — so we
/// grade the *flattened* output instead via `AVVideoComposition(asset:applyingCIFiltersWithHandler:)`.
/// One extra encode; lossless-ish for ProRes, a small hit for HEVC presets.
enum LUTExportPass {
    /// Grades `inputURL` and returns a new file URL. Caller owns both files.
    static func apply(
        processor: ColorGradeProcessor,
        intensity: Double,
        to inputURL: URL,
        fileType: AVFileType,
        preset: String
    ) async throws -> URL {
        let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        let strength = CGFloat(min(1.0, max(0.0, intensity)))
        let asset = AVURLAsset(url: inputURL)

        let videoComposition = try await AVVideoComposition.videoComposition(
            with: asset
        ) { request in
            let source = request.sourceImage.clampedToExtent()
            let graded = processor.process(source, colorSpace: colorSpace)
            // Blend graded over original by intensity (1 = full grade, 0 = bypass).
            let mixed = strength >= 1.0
                ? graded
                : graded.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: source,
                    kCIInputTimeKey: 1.0 - strength,
                ])
            request.finish(with: mixed.cropped(to: request.sourceImage.extent), context: nil)
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw LUTPassError.unsupportedPreset
        }
        session.videoComposition = videoComposition

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lut-pass-\(UUID().uuidString).\(inputURL.pathExtension)")
        try? FileManager.default.removeItem(at: outputURL)

        Log.export.notice("lut-pass start intensity=\(intensity)")
        try await session.export(to: outputURL, as: fileType)
        Log.export.notice("lut-pass ok url=\(outputURL.lastPathComponent)")
        return outputURL
    }

    enum LUTPassError: LocalizedError {
        case filterUnavailable
        case unsupportedPreset

        var errorDescription: String? {
            switch self {
            case .filterUnavailable: "Could not build the color-cube filter"
            case .unsupportedPreset: "Export preset unsupported for the LUT pass"
            }
        }
    }
}
