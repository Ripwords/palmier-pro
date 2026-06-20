import AVFoundation
import CoreImage

/// Bakes a clip's grade into a cached copy of its source, swapped in by `CompositionBuilder`.
actor ClipGradeBaker {
    static let shared = ClipGradeBaker()

    private var cache: [String: URL] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]
    /// LRU order, most-recent last. Bounds disk/memory so slider drags don't spew temp files.
    private var order: [String] = []
    private let cap = 24

    /// Returns a graded copy of `sourceURL` for `grade`, reusing a cached bake when possible.
    /// `renderSize` downscales the output (preview proxies); nil bakes at full source resolution.
    func bakedURL(forSource sourceURL: URL, grade: ClipGrade, renderSize: CGSize? = nil) async throws -> URL {
        guard !grade.isIdentity else { return sourceURL }
        let filters = GradePipeline.filters(primaries: grade.primaries, lut: grade.lut)
        guard !filters.isEmpty else { return sourceURL }

        let key = Self.cacheKey(sourceURL: sourceURL, grade: grade, renderSize: renderSize)
        if let cached = cache[key], FileManager.default.fileExists(atPath: cached.path) {
            touch(key)
            return cached
        }
        if let running = inFlight[key] {
            return try await running.value
        }

        let task = Task<URL, Error> {
            try await Self.bake(sourceURL: sourceURL, filters: filters, key: key, renderSize: renderSize)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let url = try await task.value
        cache[key] = url
        touch(key)
        evictIfNeeded()
        return url
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > cap {
            let stale = order.removeFirst()
            if let url = cache.removeValue(forKey: stale) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func bake(sourceURL: URL, filters: [CIFilter], key: String, renderSize: CGSize?) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-grade-\(key).mov")
        Log.preview.notice("clip-grade bake start key=\(key)")
        let graded = try await LUTExportPass.apply(
            processor: FilterChainProcessor(filters: filters),
            to: sourceURL,
            fileType: .mov,
            preset: AVAssetExportPresetHighestQuality,
            outputURL: outputURL,
            renderSize: renderSize
        )
        Log.preview.notice("clip-grade bake ok key=\(key)")
        return graded
    }

    /// FNV-1a over the source path, grade bytes, and render size; stable across runs.
    static func cacheKey(sourceURL: URL, grade: ClipGrade, renderSize: CGSize? = nil) -> String {
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
        if let renderSize {
            mix("\(Int(renderSize.width))x\(Int(renderSize.height))".utf8)
        }
        return String(hash, radix: 16)
    }
}
