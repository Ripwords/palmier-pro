import Foundation

extension ToolExecutor {
    /// `list_color_grades` — the built-in look catalog.
    func listColorGrades() -> ToolResult {
        .ok(Self.jsonString(["looks": ColorGradeCatalog.catalogJSON]) ?? "{}")
    }

    /// `apply_color_grade` — set a project-wide grade (built-in look or a .cube file path).
    func applyColorGrade(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let look = (args["look"] as? String)?.trimmingCharacters(in: .whitespaces)
        let lutPath = (args["lutPath"] as? String)?.trimmingCharacters(in: .whitespaces)
        let intensityRaw = (args["intensity"] as? NSNumber)?.doubleValue ?? 1.0
        let intensity = min(1.0, max(0.0, intensityRaw))

        let ref: LUTRef
        switch (look?.isEmpty == false ? look : nil, lutPath?.isEmpty == false ? lutPath : nil) {
        case let (lookID?, nil):
            guard ColorGradeCatalog.look(id: lookID) != nil else {
                let ids = ColorGradeCatalog.all.map(\.id).joined(separator: ", ")
                throw ToolError("Unknown look '\(lookID)'. Available: \(ids). Call list_color_grades.")
            }
            ref = .look(lookID, intensity: intensity)
        case let (nil, path?):
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension.lowercased() == "cube" else {
                throw ToolError("lutPath must point at a .cube file (got '\(url.lastPathComponent)').")
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ToolError("Could not read .cube file at \(path)")
            }
            let cube: CubeLUT
            do { cube = try CubeLUTParser.parse(text) }
            catch { throw ToolError("Invalid .cube: \(error.localizedDescription)") }
            ref = .cube(cube, name: url.deletingPathExtension().lastPathComponent, intensity: intensity)
        default:
            throw ToolError("Provide exactly one of 'look' or 'lutPath'.")
        }

        editor.setColorGrade(ref)
        var out = ref.summary
        out["appliesAt"] = "export"
        return .ok(Self.jsonString(out) ?? "{}")
    }

    /// `clear_color_grade` — remove the project grade.
    func clearColorGrade(_ editor: EditorViewModel) throws -> ToolResult {
        editor.setColorGrade(nil)
        return .ok(Self.jsonString(["cleared": true]) ?? "{}")
    }
}
