import AVFoundation

/// A loaded source asset+track. `@unchecked Sendable`: AVURLAsset/AVAssetTrack are immutable
/// for reads, used the same single-threaded way the built-in compositor uses them.
struct LoadedSource: @unchecked Sendable {
    let asset: AVURLAsset
    let track: AVAssetTrack
}

/// Caches loaded source assets+tracks across composition rebuilds. AVURLAsset is immutable
/// and reusable; keeping the instance preserves its already-loaded track properties, so
/// repeat rebuilds (e.g. while grading) skip re-resolving every clip's media.
actor SourceAssetCache {
    static let shared = SourceAssetCache()

    private var cache: [String: LoadedSource] = [:]
    private var order: [String] = []
    private let cap = 64

    func assetAndTrack(url: URL, mediaType: AVMediaType) async -> LoadedSource? {
        let key = "\(url.path)#\(mediaType.rawValue)"
        if let hit = cache[key], FileManager.default.fileExists(atPath: url.path) {
            touch(key)
            return hit
        }
        cache[key] = nil
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: mediaType).first else {
            return nil
        }
        let loaded = LoadedSource(asset: asset, track: track)
        cache[key] = loaded
        touch(key)
        evict()
        return loaded
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evict() {
        while order.count > cap {
            let stale = order.removeFirst()
            cache[stale] = nil
        }
    }
}
