import Foundation

extension EditorViewModel {
    /// Set or clear the project-wide color grade (undoable).
    func setColorGrade(_ lut: LUTRef?) {
        let prev = timeline.lut
        guard prev != lut else { return }
        timeline.lut = lut
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.setColorGrade(prev)
        }
        undoManager?.setActionName(lut == nil ? "Clear Color Grade (Agent)" : "Apply Color Grade (Agent)")
        notifyTimelineChanged()
    }

    /// Set or clear the project-wide primary correction (undoable).
    func setColorPrimaries(_ primaries: PrimaryGrade?) {
        let next = (primaries?.isIdentity ?? true) ? nil : primaries
        let prev = timeline.primaries
        guard prev != next else { return }
        timeline.primaries = next
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.setColorPrimaries(prev)
        }
        undoManager?.setActionName("Adjust Color")
        notifyTimelineChanged()
    }
}
