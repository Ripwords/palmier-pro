import AVFoundation
import AppKit

enum ExportFormat {
    case h264, h265, prores, xml
    /// HEVC Main10, BT.2020 + HLG — preserves 10-bit HDR (via AVAssetWriter).
    case hevcHDR

    var fileExtension: String {
        switch self {
        case .h264, .h265: "mp4"
        case .prores, .hevcHDR: "mov"
        case .xml: "xml"
        }
    }

    var utType: AVFileType? {
        switch self {
        case .h264, .h265: .mp4
        case .prores, .hevcHDR: .mov
        case .xml: nil
        }
    }

    var isHDR: Bool { self == .hevcHDR }
}

enum ExportResolution: String, CaseIterable, Identifiable {
    case r720p = "720p"
    case r1080p = "1080p"
    case r4k = "4K"

    var id: String { rawValue }

    var shortSidePixels: Int {
        switch self {
        case .r720p: 720
        case .r1080p: 1080
        case .r4k: 2160
        }
    }

    func renderSize(for canvas: CGSize) -> CGSize {
        let canvasShort = min(canvas.width, canvas.height)
        guard canvasShort > 0 else { return canvas }
        let scale = Double(shortSidePixels) / Double(canvasShort)
        let w = (Int((canvas.width * scale).rounded()) / 2) * 2
        let h = (Int((canvas.height * scale).rounded()) / 2) * 2
        return CGSize(width: max(2, w), height: max(2, h))
    }
}

enum ExportError: LocalizedError {
    case unsupportedPreset
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedPreset: "Export preset not supported on this system"
        case .invalidFormat: "Invalid export format"
        }
    }
}

@Observable
@MainActor
final class ExportService {
    var progress: Double = 0
    var isExporting = false {
        didSet {
            guard isExporting != oldValue else { return }
            isExporting ? SearchIndexCoordinator.exportDidBegin() : SearchIndexCoordinator.exportDidEnd()
        }
    }
    var error: String?

    func export(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution,
        outputURL: URL
    ) async {
        if format == .xml {
            XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outputURL)
            progress = 1.0
            return
        }
        if format.isHDR {
            await exportHDR(timeline: timeline, resolver: resolver, resolution: resolution, outputURL: outputURL)
            return
        }

        isExporting = true
        progress = 0
        error = nil

        do {
            let session = try await makeExportSession(
                timeline: timeline, resolver: resolver,
                format: format, resolution: resolution
            )
            guard let fileType = format.utType else { throw ExportError.invalidFormat }

            // AVAssetExportSession fails if the file already exists
            try? FileManager.default.removeItem(at: outputURL)

            nonisolated(unsafe) let unsafeSession = session
            let progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    let p = Double(unsafeSession.progress)
                    if p != self.progress { self.progress = p }
                }
            }

            do {
                Log.export.notice("export start format=\(String(describing: format)) resolution=\(resolution.rawValue) url=\(outputURL.lastPathComponent)")
                try await session.export(to: outputURL, as: fileType)
                try await applyLUTPassIfNeeded(
                    timeline: timeline, format: format,
                    resolution: resolution, fileType: fileType, outputURL: outputURL
                )
                progress = 1.0
                Log.export.notice("export ok")
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError {
                    self.error = "Export was cancelled"
                    Log.export.notice("export cancelled")
                } else {
                    self.error = Log.detail(error)
                    Log.export.error("export failed: \(Log.detail(error))")
                }
            }

            progressTask.cancel()
        } catch {
            self.error = Log.detail(error)
            Log.export.error("export setup failed: \(Log.detail(error))")
        }

        isExporting = false
    }

    /// Writes a self-contained `.palmier` bundle (all media collected internally).
    @discardableResult
    func exportPalmierProject(
        timeline: Timeline,
        manifest: MediaManifest,
        generationLog: GenerationLog,
        sourceProjectURL: URL?,
        outputURL: URL
    ) async -> PalmierProjectExporter.Report? {
        isExporting = true
        progress = 0
        error = nil
        defer { isExporting = false }

        do {
            Log.export.notice("palmier export start url=\(outputURL.lastPathComponent)")
            let report = try await Task.detached(priority: .userInitiated) {
                try PalmierProjectExporter.export(
                    timeline: timeline, manifest: manifest, generationLog: generationLog,
                    sourceProjectURL: sourceProjectURL, to: outputURL,
                    progress: { p in Task { @MainActor in self.progress = p } }
                )
            }.value
            progress = 1.0
            Log.export.notice("palmier export ok collected=\(report.collected.count) missing=\(report.missing.count)")
            return report
        } catch {
            self.error = Log.detail(error)
            Log.export.error("palmier export failed: \(Log.detail(error))")
            return nil
        }
    }

    /// Grade the just-exported file in place when the timeline carries a LUT.
    private func applyLUTPassIfNeeded(
        timeline: Timeline,
        format: ExportFormat,
        resolution: ExportResolution,
        fileType: AVFileType,
        outputURL: URL
    ) async throws {
        guard let lutRef = timeline.lut, lutRef.clampedIntensity > 0,
              let processor = lutRef.makeProcessor() else { return }
        do {
            let gradedURL = try await LUTExportPass.apply(
                processor: processor, intensity: lutRef.clampedIntensity,
                to: outputURL, fileType: fileType,
                preset: exportPresetName(format: format, resolution: resolution)
            )
            // Swap the graded file over the original export.
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: gradedURL, to: outputURL)
        } catch {
            // Don't fail the whole export over a bad LUT — keep the ungraded file.
            Log.export.error("lut-pass skipped: \(Log.detail(error))")
        }
    }

    /// Build the composition, then encode HEVC Main10 HDR (no text/LUT on this path yet).
    private func exportHDR(
        timeline: Timeline,
        resolver: MediaResolver,
        resolution: ExportResolution,
        outputURL: URL
    ) async {
        isExporting = true
        progress = 0
        error = nil
        defer { isExporting = false }
        do {
            let renderSize = resolution.renderSize(for: CGSize(width: timeline.width, height: timeline.height))
            let result = try await CompositionBuilder.build(
                timeline: timeline,
                resolveURL: { resolver.resolveURL(for: $0) },
                renderSize: renderSize
            )
            try? FileManager.default.removeItem(at: outputURL)
            Log.export.notice("hdr export start size=\(Int(renderSize.width))x\(Int(renderSize.height)) url=\(outputURL.lastPathComponent)")
            let inputs = HDRVideoExporter.Inputs(
                composition: result.composition,
                videoComposition: result.videoComposition,
                audioMix: result.audioMix
            )
            try await HDRVideoExporter.export(
                inputs, renderSize: renderSize, fps: timeline.fps, transfer: .hlg, to: outputURL
            )
            progress = 1.0
            Log.export.notice("hdr export ok")
        } catch {
            self.error = Log.detail(error)
            Log.export.error("hdr export failed: \(Log.detail(error))")
        }
    }

    private func makeExportSession(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution
    ) async throws -> AVAssetExportSession {
        let timelineCanvas = CGSize(width: timeline.width, height: timeline.height)
        let renderSize = resolution.renderSize(for: timelineCanvas)

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { resolver.resolveURL(for: $0) },
            renderSize: renderSize
        )

        let presetName = exportPresetName(format: format, resolution: resolution)
        guard let session = AVAssetExportSession(asset: result.composition, presetName: presetName) else {
            throw ExportError.unsupportedPreset
        }
        session.audioMix = result.audioMix

        // Bake text clips into the export via AVVideoCompositionCoreAnimationTool
        let (parent, videoLayer) = TextLayerController.buildForExport(
            timeline: timeline,
            fps: timeline.fps,
            renderSize: renderSize
        )
        let mutableVC = result.videoComposition.mutableCopy() as! AVMutableVideoComposition
        mutableVC.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parent
        )
        session.videoComposition = mutableVC
        return session
    }

    // MARK: - Export preset mapping

    private func exportPresetName(format: ExportFormat, resolution: ExportResolution) -> String {
        switch format {
        case .h264:
            switch resolution {
            case .r720p: AVAssetExportPreset1280x720
            case .r1080p: AVAssetExportPreset1920x1080
            case .r4k: AVAssetExportPreset3840x2160
            }
        case .h265:
            switch resolution {
            case .r720p: AVAssetExportPresetHEVC1920x1080
            case .r1080p: AVAssetExportPresetHEVC1920x1080
            case .r4k: AVAssetExportPresetHEVC3840x2160
            }
        case .prores:
            AVAssetExportPresetAppleProRes422LPCM
        case .xml, .hevcHDR:
            AVAssetExportPresetPassthrough // unreachable — XML and HDR return early
        }
    }
}
