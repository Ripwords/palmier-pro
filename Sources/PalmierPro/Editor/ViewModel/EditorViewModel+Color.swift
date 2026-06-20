import Foundation

extension EditorViewModel {
    func setColorGrade(_ lut: LUTRef?) {
        let prev = timeline.lut
        guard prev != lut else { return }
        timeline.lut = lut
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.setColorGrade(prev)
        }
        undoManager?.setActionName(lut == nil ? "Clear Color Grade (Agent)" : "Apply Color Grade (Agent)")
        // Grade renders via CALayer.filters, not the composition; rebuilding would only cause a black flash.
        videoEngine?.refreshGrade()
    }

    func setColorPrimaries(_ primaries: PrimaryGrade?) {
        let next = (primaries?.isIdentity ?? true) ? nil : primaries
        let prev = timeline.primaries
        guard prev != next else { return }
        timeline.primaries = next
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.setColorPrimaries(prev)
        }
        undoManager?.setActionName("Adjust Color")
        videoEngine?.refreshGrade()
    }
}

/// What the Color inspector currently edits.
enum GradingScope: Equatable {
    case timeline
    case clip(String)
}

extension EditorViewModel {
    /// A single selected non-audio clip edits that clip's grade; otherwise the timeline grade.
    var gradingScope: GradingScope {
        guard selectedClipIds.count == 1, let id = selectedClipIds.first,
              let clip = clipFor(id: id), clip.mediaType != .audio else {
            return .timeline
        }
        return .clip(id)
    }

    var gradingScopeLabel: String {
        switch gradingScope {
        case .timeline:
            return "Timeline"
        case .clip(let id):
            guard let clip = clipFor(id: id) else { return "Clip" }
            let name = mediaAssets.first(where: { $0.id == clip.mediaRef })?.name
            return name.map { "Clip — \($0)" } ?? "Clip"
        }
    }

    var gradedPrimaries: PrimaryGrade? {
        switch gradingScope {
        case .timeline: return timeline.primaries
        case .clip(let id): return clipFor(id: id)?.grade?.primaries
        }
    }

    var gradedLUT: LUTRef? {
        switch gradingScope {
        case .timeline: return timeline.lut
        case .clip(let id): return clipFor(id: id)?.grade?.lut
        }
    }
}
