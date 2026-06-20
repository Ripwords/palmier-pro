import AVFoundation
import CoreImage

/// Bakes a clip's grade into a cached copy of its source asset. The graded copy is just
/// "another source" — `CompositionBuilder` derives all geometry (size, transform, trim,
/// speed) from whatever track it inserts, so swapping in the graded URL leaves the proven
/// composition + text-export path untouched while the grade renders in preview and export.
actor ClipGradeBaker {
    static let shared = ClipGradeBaker()

    private var cache: [String: URL] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]

    /// Returns a graded copy of `sourceURL` for `grade`, reusing a cached bake when possible.
    /// Identity grades return the original URL unchanged.
    func bakedURL(forSource sourceURL: URL, grade: ClipGrade) async throws -> URL {
        guard !grade.isIdentity else { return sourceURL }
        let filters = GradePipeline.filters(primaries: grade.primaries, lut: grade.lut)
        guard !filters.isEmpty else { return sourceURL }

        let key = Self.cacheKey(sourceURL: sourceURL, grade: grade)
        if let cached = cache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        if let running = inFlight[key] {
            return try await running.value
        }

        let task = Task<URL, Error> {
            try await Self.bake(sourceURL: sourceURL, filters: filters, key: key)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let url = try await task.value
        cache[key] = url
        return url
    }

    private static func bake(sourceURL: URL, filters: [CIFilter], key: String) async throws -> URL {
        let processor = FilterChainProcessor(filters: filters)
        let colorSpace = GradePipeline.workingColorSpace
        let asset = AVURLAsset(url: sourceURL)

        let videoComposition = try await AVVideoComposition.videoComposition(with: asset) { request in
            let graded = processor.process(request.sourceImage.clampedToExtent(), colorSpace: colorSpace)
            request.finish(with: graded.cropped(to: request.sourceImage.extent), context: nil)
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw BakeError.unsupportedPreset
        }
        session.videoComposition = videoComposition

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-grade-\(key).mov")
        try? FileManager.default.removeItem(at: outputURL)

        Log.preview.notice("clip-grade bake start key=\(key)")
        try await session.export(to: outputURL, as: .mov)
        Log.preview.notice("clip-grade bake ok key=\(key)")
        return outputURL
    }

    /// Stable within and across runs so the on-disk temp can be reused. FNV-1a over the
    /// source path and the grade's encoded bytes.
    static func cacheKey(sourceURL: URL, grade: ClipGrade) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ bytes: some Sequence<UInt8>) {
            for b in bytes {
                hash ^= UInt64(b)
                hash = hash &* 0x100000001b3
            }
        }
        mix(sourceURL.path.utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(grade) {
            mix(data)
        }
        return String(hash, radix: 16)
    }

    enum BakeError: LocalizedError {
        case unsupportedPreset
        var errorDescription: String? {
            switch self {
            case .unsupportedPreset: "Could not create a grade-bake export session"
            }
        }
    }
}
