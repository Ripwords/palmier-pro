import SwiftUI

struct CurveEditorView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var channel: Channel = .master

    enum Channel: String, CaseIterable, Identifiable {
        case master = "M", red = "R", green = "G", blue = "B"
        var id: String { rawValue }
        var tint: Color {
            switch self {
            case .master: AppTheme.Text.secondaryColor
            case .red: .red
            case .green: .green
            case .blue: .blue
            }
        }
    }

    private let height: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Picker("", selection: $channel) {
                ForEach(Channel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            GeometryReader { geo in
                let size = CGSize(width: geo.size.width, height: height)
                ZStack {
                    Canvas { ctx, _ in
                        // Frame + diagonal reference.
                        let border = Path(CGRect(origin: .zero, size: size))
                        ctx.stroke(border, with: .color(AppTheme.Border.subtleColor), lineWidth: AppTheme.BorderWidth.hairline)
                        var diag = Path()
                        diag.move(to: point(CurvePoint(x: 0, y: 0), size))
                        diag.addLine(to: point(CurvePoint(x: 1, y: 1), size))
                        ctx.stroke(diag, with: .color(AppTheme.Border.subtleColor), style: .init(lineWidth: AppTheme.BorderWidth.hairline, dash: [3, 3]))
                        // Curve.
                        var curve = Path()
                        let pts = sortedPoints
                        for i in stride(from: 0.0, through: 1.0, by: 0.02) {
                            let p = point(CurvePoint(x: i, y: GradeCurve.eval(pts, i)), size)
                            if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                        }
                        ctx.stroke(curve, with: .color(channel.tint), lineWidth: AppTheme.BorderWidth.medium)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in addPoint(at: location, size: size) }

                    ForEach(Array(sortedPoints.enumerated()), id: \.offset) { index, pt in
                        Circle()
                            .fill(channel.tint)
                            .frame(width: 9, height: 9)
                            .position(point(pt, size))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { drag(index: index, to: $0.location, size: size) }
                            )
                            .onTapGesture(count: 2) { removePoint(at: index) }
                    }
                }
            }
            .frame(height: height)

            Text("Click to add a point · drag to shape · double-click to remove")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
    }

    // MARK: - Points

    private var sortedPoints: [CurvePoint] {
        let raw = channelPoints
        return (raw.isEmpty ? GradeCurve.identityPoints : raw).sorted { $0.x < $1.x }
    }

    private var channelPoints: [CurvePoint] {
        let c = editor.timeline.primaries?.curve ?? GradeCurve()
        switch channel {
        case .master: return c.master
        case .red: return c.red
        case .green: return c.green
        case .blue: return c.blue
        }
    }

    private func point(_ p: CurvePoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
    }

    private func value(at location: CGPoint, _ size: CGSize) -> CurvePoint {
        CurvePoint(
            x: min(1, max(0, location.x / size.width)),
            y: min(1, max(0, 1 - location.y / size.height))
        )
    }

    private func drag(index: Int, to location: CGPoint, size: CGSize) {
        var pts = sortedPoints
        let v = value(at: location, size)
        let isEndpoint = index == 0 || index == pts.count - 1
        pts[index].y = v.y
        if !isEndpoint {
            let lo = pts[index - 1].x + 0.001
            let hi = pts[index + 1].x - 0.001
            pts[index].x = min(hi, max(lo, v.x))
        }
        commit(pts)
    }

    private func addPoint(at location: CGPoint, size: CGSize) {
        var pts = sortedPoints
        pts.append(value(at: location, size))
        commit(pts.sorted { $0.x < $1.x })
    }

    private func removePoint(at index: Int) {
        var pts = sortedPoints
        guard pts.count > 2, index > 0, index < pts.count - 1 else { return }
        pts.remove(at: index)
        commit(pts)
    }

    private func commit(_ pts: [CurvePoint]) {
        var p = editor.timeline.primaries ?? PrimaryGrade()
        var c = p.curve ?? GradeCurve()
        let value = (pts == GradeCurve.identityPoints) ? [] : pts
        switch channel {
        case .master: c.master = value
        case .red: c.red = value
        case .green: c.green = value
        case .blue: c.blue = value
        }
        p.curve = c.isIdentity ? nil : c
        editor.setColorPrimaries(p)
    }
}
