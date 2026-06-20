import CoreImage
import Foundation

/// Built-in color looks the agent applies by name. Each is a small Core Image
/// primary chain, so it composes with the same export pass as imported `.cube` LUTs.
enum ColorGradeCatalog {

    struct Look: Sendable, Equatable {
        let id: String
        let name: String
        let summary: String
        let steps: [Step]

        struct Step: Sendable, Equatable {
            let filter: String
            let params: [String: Double]
            let curve: [CGPoint]?
            init(_ filter: String, _ params: [String: Double] = [:], curve: [CGPoint]? = nil) {
                self.filter = filter
                self.params = params
                self.curve = curve
            }
        }
    }

    /// Maps input `floor` to black and steepens mids — dehazes hazy footage.
    private static func dehazeCurve(floor: Double, shoulder: Double = 0.97) -> [CGPoint] {
        [
            .init(x: floor, y: 0.0),
            .init(x: floor + (0.5 - floor) * 0.5, y: 0.24),
            .init(x: 0.5, y: 0.5),
            .init(x: 0.5 + (shoulder - 0.5) * 0.5, y: 0.78),
            .init(x: shoulder, y: 1.0),
        ]
    }

    static let all: [Look] = [
        Look(
            id: "warm-cinematic",
            name: "Warm Cinematic",
            summary: "Warm highlights, real contrast, dehazed blacks. A filmic default for daylight/outdoor footage.",
            steps: [
                .init("CITemperatureAndTint", ["neutralX": 7200, "neutralY": 0, "targetX": 6500, "targetY": 0]),
                .init("CIToneCurve", curve: dehazeCurve(floor: 0.08)),
                .init("CIColorControls", ["saturation": 1.12, "contrast": 1.12]),
                .init("CIVibrance", ["amount": 0.2]),
            ]
        ),
        Look(
            id: "teal-orange",
            name: "Teal & Orange",
            summary: "Warm mids against cooler shadows — the classic travel/adventure blockbuster look.",
            steps: [
                .init("CITemperatureAndTint", ["neutralX": 6500, "neutralY": 0, "targetX": 6050, "targetY": 16]),
                .init("CIToneCurve", curve: dehazeCurve(floor: 0.1)),
                .init("CIColorControls", ["saturation": 1.22, "contrast": 1.14]),
                .init("CIVibrance", ["amount": 0.35]),
            ]
        ),
        Look(
            id: "moody-forest",
            name: "Moody Forest",
            summary: "Deeper greens, cooler shadows, dehazed and contrasty. Suits hikes, jungle, overcast nature.",
            steps: [
                .init("CITemperatureAndTint", ["neutralX": 6200, "neutralY": 0, "targetX": 7000, "targetY": -10]),
                .init("CIToneCurve", curve: dehazeCurve(floor: 0.12)),
                .init("CIColorControls", ["saturation": 1.0, "contrast": 1.18, "brightness": -0.02]),
            ]
        ),
        Look(
            id: "vibrant-travel",
            name: "Vibrant Travel",
            summary: "Punchy, bright, saturated, dehazed — pops skies and landscapes for social/vlog delivery.",
            steps: [
                .init("CIToneCurve", curve: dehazeCurve(floor: 0.1)),
                .init("CIColorControls", ["saturation": 1.32, "contrast": 1.16, "brightness": 0.01]),
                .init("CIVibrance", ["amount": 0.5]),
            ]
        ),
        Look(
            id: "vintage-film",
            name: "Vintage Film",
            summary: "Faded, lifted blacks and softened highlights with a warm cast — a nostalgic Super-8 feel.",
            steps: [
                .init("CITemperatureAndTint", ["neutralX": 6500, "neutralY": 0, "targetX": 6000, "targetY": 8]),
                .init("CIColorControls", ["saturation": 0.88, "contrast": 0.96]),
                .init("CIToneCurve", curve: [.init(x: 0, y: 0.1), .init(x: 0.25, y: 0.28),
                                             .init(x: 0.5, y: 0.5), .init(x: 0.75, y: 0.72), .init(x: 1, y: 0.9)]),
            ]
        ),
        Look(
            id: "clean-neutral",
            name: "Clean Neutral",
            summary: "A light, true-to-life polish — modest dehaze, contrast and vibrance. Use when footage is already good.",
            steps: [
                .init("CIToneCurve", curve: dehazeCurve(floor: 0.05)),
                .init("CIColorControls", ["saturation": 1.08, "contrast": 1.06]),
                .init("CIVibrance", ["amount": 0.18]),
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
