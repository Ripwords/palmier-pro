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
    /// A single selected visual clip edits that clip's grade; otherwise the timeline grade.
    /// Counts visual clips only, so a linked video+audio selection still resolves to the video.
    var gradingScope: GradingScope {
        var visualId: String?
        var count = 0
        for track in timeline.tracks {
            for clip in track.clips
            where selectedClipIds.contains(clip.id) && clip.mediaType.isVisual && clip.mediaType != .text {
                count += 1
                visualId = clip.id
            }
        }
        guard count == 1, let id = visualId else { return .timeline }
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

    /// Route inspector edits to the current scope's grade.
    func setGradedPrimaries(_ primaries: PrimaryGrade?) {
        switch gradingScope {
        case .timeline: setColorPrimaries(primaries)
        case .clip(let id): setClipPrimaries(clipId: id, primaries)
        }
    }

    func setGradedLUT(_ lut: LUTRef?) {
        switch gradingScope {
        case .timeline: setColorGrade(lut)
        case .clip(let id): setClipLUT(clipId: id, lut)
        }
    }

    func setClipPrimaries(clipId: String, _ primaries: PrimaryGrade?) {
        let next = (primaries?.isIdentity ?? true) ? nil : primaries
        updateClipGrade(clipId: clipId, actionName: "Adjust Clip Color") { $0.primaries = next }
    }

    func setClipLUT(clipId: String, _ lut: LUTRef?) {
        let next = (lut?.clampedIntensity ?? 0) > 0 ? lut : nil
        updateClipGrade(clipId: clipId, actionName: next == nil ? "Clear Clip Grade" : "Apply Clip Grade") {
            $0.lut = next
        }
    }

    /// Mutate a clip's grade (nil when identity), register undo, and rebuild to re-bake the source.
    private func updateClipGrade(clipId: String, actionName: String, _ mutate: (inout ClipGrade) -> Void) {
        guard let loc = findClip(id: clipId) else { return }
        let before = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].grade
        var grade = before ?? ClipGrade()
        mutate(&grade)
        let after: ClipGrade? = grade.isIdentity ? nil : grade
        guard before != after else { return }
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].grade = after
        registerClipGradeSwap(clipId: clipId, undo: before, redo: after, actionName: actionName)
        videoEngine?.gradeEdited(clipId: clipId)
    }

    private func registerClipGradeSwap(clipId: String, undo: ClipGrade?, redo: ClipGrade?, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { vm in
            if let loc = vm.findClip(id: clipId) {
                vm.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].grade = undo
            }
            vm.registerClipGradeSwap(clipId: clipId, undo: redo, redo: undo, actionName: actionName)
            vm.notifyTimelineChanged()
        }
        undoManager?.setActionName(actionName)
    }
}
