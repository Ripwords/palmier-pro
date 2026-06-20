import CoreImage

/// Builds the `CALayer.filters` chain for the live grade preview, honoring intensity.
enum GradePreview {
    static func filters(for lut: LUTRef?) -> [CIFilter]? {
        guard let lut, lut.clampedIntensity > 0 else { return nil }
        let t = lut.clampedIntensity
        switch lut.kind {
        case .look:
            guard let look = lut.lookID.flatMap(ColorGradeCatalog.look(id:)) else { return nil }
            let chain = look.ciFilters(intensity: t)
            return chain.isEmpty ? nil : chain
        case .cube:
            guard let dim = lut.cubeDimension, let b64 = lut.cubeBase64,
                  let cube = CubeLUT(base64: b64, dimension: dim) else { return nil }
            let cs = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
            return cube.intensityBlended(t).makeFilter(colorSpace: cs).map { [$0] }
        }
    }
}
