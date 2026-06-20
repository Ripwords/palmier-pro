import Foundation

struct ResolveLUT: Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let url: URL
}

/// Scans the local DaVinci Resolve LUT folders for `.cube` files, read in place (nothing copied).
enum ResolveLUTLibrary {
    static let roots: [URL] = [
        URL(fileURLWithPath: "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT"),
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT"),
    ]

    static let groups: [(category: String, luts: [ResolveLUT])] = scan()
    static var isAvailable: Bool { !groups.isEmpty }

    private static func scan() -> [(String, [ResolveLUT])] {
        var byCategory: [String: [ResolveLUT]] = [:]
        let fm = FileManager.default
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "cube" {
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let category = rel.contains("/") ? String(rel.prefix(while: { $0 != "/" })) : "LUT"
                byCategory[category, default: []].append(
                    ResolveLUT(id: url.path, name: url.deletingPathExtension().lastPathComponent,
                               category: category, url: url)
                )
            }
        }
        return byCategory
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
    }
}
