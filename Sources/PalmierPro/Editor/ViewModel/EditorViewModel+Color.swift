import Foundation

extension EditorViewModel {
    /// Set or clear the project-wide color grade. Undoable, mirrors the other
    /// project-level setting mutations.
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
}
