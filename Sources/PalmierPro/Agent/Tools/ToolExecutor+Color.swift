import Foundation

extension ToolExecutor {
    /// `list_color_grades` — the built-in look catalog.
    func listColorGrades() -> ToolResult {
        .ok(Self.jsonString(["looks": ColorGradeCatalog.catalogJSON]) ?? "{}")
    }

    /// `apply_color_grade` — set a project-wide grade (built-in look or imported .cube).
    func applyColorGrade(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let look = (args["look"] as? String)?.trimmingCharacters(in: .whitespaces)
        let lutMediaRef = (args["lutMediaRef"] as? String)?.trimmingCharacters(in: .whitespaces)
        let intensityRaw = (args["intensity"] as? NSNumber)?.doubleValue ?? 1.0
        let intensity = min(1.0, max(0.0, intensityRaw))

        let source: LUTRef.Source
        switch (look?.isEmpty == false ? look : nil, lutMediaRef?.isEmpty == false ? lutMediaRef : nil) {
        case let (lookID?, nil):
            guard ColorGradeCatalog.look(id: lookID) != nil else {
                let ids = ColorGradeCatalog.all.map(\.id).joined(separator: ", ")
                throw ToolError("Unknown look '\(lookID)'. Available: \(ids). Call list_color_grades.")
            }
            source = .look(id: lookID)
        case let (nil, mediaRef?):
            guard editor.mediaAssets.contains(where: { $0.id == mediaRef }) else {
                throw ToolError("LUT media not found: \(mediaRef). Import the .cube file first.")
            }
            source = .cube(mediaRef: mediaRef)
        default:
            throw ToolError("Provide exactly one of 'look' or 'lutMediaRef'.")
        }

        editor.setColorGrade(LUTRef(source: source, intensity: intensity))

        var out: [String: Any] = ["intensity": intensity, "appliesAt": "export"]
        switch source {
        case .look(let id): out["look"] = id
        case .cube(let mediaRef): out["lutMediaRef"] = mediaRef
        }
        return .ok(Self.jsonString(out) ?? "{}")
    }

    /// `clear_color_grade` — remove the project grade.
    func clearColorGrade(_ editor: EditorViewModel) throws -> ToolResult {
        editor.setColorGrade(nil)
        return .ok(Self.jsonString(["cleared": true]) ?? "{}")
    }
}
