import CoreImage
import Foundation

/// A curated set of built-in color looks the agent can apply by name — no asset
/// import required. Each look is a small Core Image primary chain, so it composes
/// with the same export pass as imported `.cube` LUTs.
///
/// Looks are intentionally restrained (gentle primaries, not heavy stylization) so
/// "apply a good grade" produces a tasteful default rather than something garish.
enum ColorGradeCatalog {

    struct Look: Sendable, Equatable {
        let id: String
        let name: String
        let summary: String
        /// Ordered Core Image filter steps, each a (name, params) applied in turn.
        let steps: [Step]

        struct Step: Sendable, Equatable {
            let filter: String
            let params: [String: Double]
            // Tone curve points, when the step is a CIToneCurve.
            let curve: [CGPoint]?
            init(_ filter: String, _ params: [String: Double] = [:], curve: [CGPoint]? = nil) {
                self.filter = filter
                self.params = params
                self.curve = curve
            }
        }
    }

    static let all: [Look] = [
        Look(
            id: "warm-cinematic",
            name: "Warm Cinematic",
            summary: "Warm highlights, gentle contrast, slightly lifted blacks. A safe, filmic default for daylight/outdoor footage.",
            steps: [
                .init("CITemperatureAndTint", ["neutralX": 6800, "neutralY": 0, "targetX": 6500, "targetY": 0]),
                .init("CIColorControls", ["saturation": 1.06, "contrast": 1.05, "brightness": 0.0]),
                .init("CIToneCurve", curve: [.init(x: 0, y: 0.03), .init(x: 0.25, y: 0.23),
                                             .init(x: 0.5, y: 0.5), .init(x: 0.75, y: 0.78), .init(x: 1, y: 0.98)]),
            ]
        ),
        Look(
            id: "teal-orange",
            name: "Teal & Orange",
            summary: "Warm skin/midtones against cooler shadows — the classic travel/adventure blockbuster look.",
            steps: [
                .init("CITemperatureAndTint", ["neutralX": 6500, "neutralY": 0, "targetX": 6200, "targetY": 12]),
                .init("CIColorControls", ["saturation": 1.12, "contrast": 1.08]),
                .init("CIVibrance", ["amount": 0.2]),
            ]
        ),
        Look(
            id: "moody-forest",
            name: "Moody Forest",
            summary: "Deeper greens, cooler shadows, muted highlights. Suits hikes, jungle, overcast nature footage.",
            steps: [
                .init("CITemperatureAndTint", ["neutralX": 6500, "neutralY": 0, "targetX": 6900, "targetY": -8]),
                .init("CIColorControls", ["saturation": 0.94, "contrast": 1.1, "brightness": -0.02]),
                .init("CIToneCurve", curve: [.init(x: 0, y: 0.0), .init(x: 0.25, y: 0.2),
                                             .init(x: 0.5, y: 0.47), .init(x: 0.75, y: 0.72), .init(x: 1, y: 0.92)]),
            ]
        ),
        Look(
            id: "vibrant-travel",
            name: "Vibrant Travel",
            summary: "Punchy, bright, saturated — pops skies and landscapes for social/vlog delivery.",
            steps: [
                .init("CIColorControls", ["saturation": 1.18, "contrast": 1.06, "brightness": 0.01]),
                .init("CIVibrance", ["amount": 0.35]),
            ]
        ),
        Look(
            id: "vintage-film",
            name: "Vintage Film",
            summary: "Faded blacks, softened highlights, warm cast — a nostalgic Super-8 feel.",
            steps: [
                .init("CITemperatureAndTint", ["neutralX": 6500, "neutralY": 0, "targetX": 6100, "targetY": 6]),
                .init("CIColorControls", ["saturation": 0.9, "contrast": 0.95]),
                .init("CIToneCurve", curve: [.init(x: 0, y: 0.08), .init(x: 0.25, y: 0.27),
                                             .init(x: 0.5, y: 0.5), .init(x: 0.75, y: 0.73), .init(x: 1, y: 0.92)]),
            ]
        ),
        Look(
            id: "clean-neutral",
            name: "Clean Neutral",
            summary: "A light, true-to-life polish — minor contrast and vibrance only. Use when the footage is already good.",
            steps: [
                .init("CIColorControls", ["saturation": 1.03, "contrast": 1.03]),
                .init("CIVibrance", ["amount": 0.1]),
            ]
        ),
    ]

    static func look(id: String) -> Look? { all.first { $0.id == id } }

    /// Catalog as JSON-ready dictionaries for `list_color_grades`.
    static var catalogJSON: [[String: Any]] {
        all.map { ["id": $0.id, "name": $0.name, "summary": $0.summary] }
    }
}

extension ColorGradeCatalog.Look: ColorGradeProcessor {
    func process(_ image: CIImage, colorSpace: CGColorSpace) -> CIImage {
        var result = image
        for step in steps {
            let filter = CIFilter(name: step.filter)
            filter?.setValue(result, forKey: kCIInputImageKey)
            for (key, value) in step.params {
                switch key {
                case "neutralX", "neutralY", "targetX", "targetY":
                    // Temperature/tint take CIVectors.
                    let isNeutral = key.hasPrefix("neutral")
                    let vecKey = isNeutral ? "inputNeutral" : "inputTargetNeutral"
                    let existing = filter?.value(forKey: vecKey) as? CIVector
                    let x = key.hasSuffix("X") ? value : (existing?.x ?? 6500)
                    let y = key.hasSuffix("Y") ? value : (existing?.y ?? 0)
                    filter?.setValue(CIVector(x: x, y: y), forKey: vecKey)
                default:
                    filter?.setValue(value, forKey: "input" + key.prefix(1).uppercased() + key.dropFirst())
                }
            }
            if let curve = step.curve, curve.count == 5 {
                for (i, pt) in curve.enumerated() {
                    filter?.setValue(CIVector(cgPoint: pt), forKey: "inputPoint\(i)")
                }
            }
            if let out = filter?.outputImage { result = out }
        }
        return result
    }
}
