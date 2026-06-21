import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

/// End-to-end smoke test for the AVFoundation-backed video export path.
///
/// Slow (~1–2s) — runs a real AVAssetExportSession against a black-video fixture generated
/// by `ImageVideoGenerator.blackVideo`. Catches the worst-case "exported file is corrupt or
/// missing" bug. Pure-logic tests for the input math live in CompositionBuilderTests and
/// ExportResolutionTests.
@Suite("ExportService — round-trip")
@MainActor
struct ExportServiceRoundTripTests {

    @Test func h264ExportProducesPlayableMp4ContainingVideoTrack() async throws {
        // 1. Generate fixture via production code path.
        let renderSize = CGSize(width: 320, height: 180)
        let blackURL = try await ImageVideoGenerator.blackVideo(size: renderSize)

        // 2. Manifest + resolver point at the fixture file.
        let mediaRef = "black-fixture"
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: mediaRef, name: "black", type: .video,
            source: .external(absolutePath: blackURL.path), duration: 5.0
        )]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        // 3. Tiny timeline: one 1-second clip at 30fps.
        let clip = Fixtures.clip(id: "c1", mediaRef: mediaRef, start: 0, duration: 30)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.width = Int(renderSize.width)
        timeline.height = Int(renderSize.height)

        // 4. Export to a temp .mp4.
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let svc = ExportService()
        await svc.export(
            timeline: timeline, resolver: resolver,
            format: .h264, resolution: .r720p,
            outputURL: outURL
        )

        // 5. Verify success state on the service.
        #expect(svc.error == nil, "export reported error: \(svc.error ?? "")")
        #expect(svc.progress == 1.0)
        #expect(FileManager.default.fileExists(atPath: outURL.path))

        // 6. Round-trip: load the exported file and verify it's a real video.
        let asset = AVURLAsset(url: outURL)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0)
        // Approximately 1 second (the clip we exported). Tolerance for encoder rounding.
        #expect(abs(duration.seconds - 1.0) < 0.5,
                "expected ~1s exported, got \(duration.seconds)s")

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(!videoTracks.isEmpty, "exported file has no video tracks")
    }

    /// A non-identity timeline grade forces the second (color) export pass. Guards that the
    /// graded path runs to completion, reaches 100%, and surfaces no error — the regression
    /// where the grade pass was untracked (bar froze) and its failures were swallowed silently.
    @Test func gradedExportRunsColorPassAndCompletes() async throws {
        let renderSize = CGSize(width: 320, height: 180)
        let blackURL = try await ImageVideoGenerator.blackVideo(size: renderSize)
        let mediaRef = "black-fixture"
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: mediaRef, name: "black", type: .video,
            source: .external(absolutePath: blackURL.path), duration: 5.0
        )]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        let clip = Fixtures.clip(id: "c1", mediaRef: mediaRef, start: 0, duration: 30)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.width = Int(renderSize.width)
        timeline.height = Int(renderSize.height)
        timeline.primaries = PrimaryGrade(temperature: 20, contrast: 15)
        // Precondition: this grade actually triggers the color pass.
        #expect(!GradePipeline.filters(primaries: timeline.primaries, lut: timeline.lut).isEmpty)

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-graded-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let svc = ExportService()
        await svc.export(
            timeline: timeline, resolver: resolver,
            format: .h264, resolution: .r720p,
            outputURL: outURL
        )

        #expect(svc.error == nil, "graded export reported error: \(svc.error ?? "")")
        #expect(svc.progress == 1.0)
        #expect(FileManager.default.fileExists(atPath: outURL.path))

        let asset = AVURLAsset(url: outURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(!videoTracks.isEmpty, "graded export has no video tracks")
    }

    /// Diagnostic: the bar must move off 0% during a real encode (states sequence emits).
    @Test func exportReportsIntermediateProgress() async throws {
        let renderSize = CGSize(width: 3840, height: 2160)
        let blackURL = try await ImageVideoGenerator.blackVideo(size: renderSize)
        let mediaRef = "black-fixture"
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: mediaRef, name: "black", type: .video,
            source: .external(absolutePath: blackURL.path), duration: 30.0
        )]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })
        let clip = Fixtures.clip(id: "c1", mediaRef: mediaRef, start: 0, duration: 300)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.width = 3840
        timeline.height = 2160

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-prog-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let svc = ExportService()
        let sampler = Task { @MainActor () -> Bool in
            var sawIntermediate = false
            while svc.progress < 1.0 {
                if svc.progress > 0 { sawIntermediate = true }
                try? await Task.sleep(for: .milliseconds(20))
                if !svc.isExporting && svc.progress == 0 { /* not started yet */ }
            }
            return sawIntermediate
        }
        await svc.export(
            timeline: timeline, resolver: resolver,
            format: .h264, resolution: .r4k, outputURL: outURL
        )
        let saw = await sampler.value
        #expect(svc.error == nil, "export error: \(svc.error ?? "")")
        #expect(saw, "progress never moved off 0 during the encode — states sequence not emitting")
    }

    /// HDR export uses the AVAssetReader→AVAssetWriter pump, a separate path from the
    /// AVAssetExportSession one. Guards that it too reports progress instead of sitting at 0%.
    @Test func hdrExportReportsIntermediateProgress() async throws {
        let renderSize = CGSize(width: 3840, height: 2160)
        let blackURL = try await ImageVideoGenerator.blackVideo(size: renderSize)
        let mediaRef = "black-fixture"
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: mediaRef, name: "black", type: .video,
            source: .external(absolutePath: blackURL.path), duration: 30.0
        )]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })
        let clip = Fixtures.clip(id: "c1", mediaRef: mediaRef, start: 0, duration: 300)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.width = 3840
        timeline.height = 2160

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-hdr-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let svc = ExportService()
        let sampler = Task { @MainActor () -> Bool in
            var sawIntermediate = false
            while svc.progress < 1.0 {
                if svc.progress > 0 { sawIntermediate = true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return sawIntermediate
        }
        await svc.export(
            timeline: timeline, resolver: resolver,
            format: .hevcHDR, resolution: .r4k, outputURL: outURL
        )
        let saw = await sampler.value
        #expect(svc.error == nil, "HDR export error: \(svc.error ?? "")")
        #expect(FileManager.default.fileExists(atPath: outURL.path))
        #expect(saw, "HDR progress never moved off 0 during the encode")
    }

    /// Regression for the AVFoundation crash where a transform keyframe at clip-offset 0
    /// caused `emitTransform`'s leading setTransform to overlap the first ramp's time range.
    @Test func exportSurvivesTransformKeyframeAtClipOffsetZero() async throws {
        let renderSize = CGSize(width: 320, height: 180)
        let blackURL = try await ImageVideoGenerator.blackVideo(size: renderSize)
        let mediaRef = "black-fixture"
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: mediaRef, name: "black", type: .video,
            source: .external(absolutePath: blackURL.path), duration: 5.0
        )]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        // Ken-Burns–style scale + position keyframes, both starting at clip offset 0.
        // Mirrors the agent input that crashed: scale (1,1)→(1.08,1.08), position (0,0)→(-0.04,0).
        var clip = Fixtures.clip(id: "c1", mediaRef: mediaRef, start: 0, duration: 30)
        clip.scaleTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 1.0, b: 1.0), interpolationOut: .linear),
            Keyframe(frame: 30, value: AnimPair(a: 1.08, b: 1.08), interpolationOut: .linear),
        ])
        clip.positionTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 0, b: 0), interpolationOut: .linear),
            Keyframe(frame: 30, value: AnimPair(a: -0.04, b: 0), interpolationOut: .linear),
        ])

        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.width = Int(renderSize.width)
        timeline.height = Int(renderSize.height)

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let svc = ExportService()
        await svc.export(
            timeline: timeline, resolver: resolver,
            format: .h264, resolution: .r720p,
            outputURL: outURL
        )
        #expect(svc.error == nil, "export reported error: \(svc.error ?? "")")
        #expect(FileManager.default.fileExists(atPath: outURL.path))
    }
}
