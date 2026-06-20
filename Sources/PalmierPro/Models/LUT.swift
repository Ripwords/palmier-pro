import CoreImage
import Foundation

/// Anything that can grade a frame: an imported `.cube` LUT or a built-in look.
/// Both flow through the same export pass so the agent can apply either by name.
protocol ColorGradeProcessor: Sendable {
    /// Return the graded image for `image` (assumed in the working color space).
    func process(_ image: CIImage, colorSpace: CGColorSpace) -> CIImage
}

/// A project-level color grade.
///
/// Phase 1 (global grade): one look applied to the whole timeline as a final Core
/// Image pass at export time. The source is either an imported `.cube` asset or a
/// curated built-in look (see `ColorGradeCatalog`). `intensity` blends the graded
/// result against the ungraded original (0 = bypass, 1 = full strength).
///
/// Per-clip grading is intentionally out of scope here — it needs a custom
/// `AVVideoCompositing` and is tracked as a separate proposal.
struct LUTRef: Codable, Sendable, Equatable {
    enum Source: Codable, Sendable, Equatable {
        /// An imported `.cube` file in the media library.
        case cube(mediaRef: String)
        /// A built-in look identified by `ColorGradeCatalog` id.
        case look(id: String)
    }

    var source: Source
    var intensity: Double = 1.0

    /// Clamp to the meaningful range; values outside [0, 1] are user/JSON noise.
    var clampedIntensity: Double { min(1.0, max(0.0, intensity)) }
}
