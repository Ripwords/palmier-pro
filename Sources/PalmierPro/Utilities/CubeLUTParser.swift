import CoreImage
import Foundation

/// A parsed 3D color lookup table from an Adobe/Resolve `.cube` file.
///
/// `rgbaTable` holds `dimension³` RGBA entries (alpha forced to 1), in the file's
/// native ordering — red varies fastest — which is exactly what
/// `CIColorCubeWithColorSpace` expects, so no reordering is needed.
struct CubeLUT: Equatable, Sendable {
    let dimension: Int
    let rgbaTable: [Float]
    /// Input domain from DOMAIN_MIN/MAX (defaults 0…1). Non-default domains are
    /// parsed but not yet remapped — see `CubeLUTParser.Warning`.
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>

    var cubeData: Data {
        rgbaTable.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    var hasNonDefaultDomain: Bool {
        domainMin != SIMD3(0, 0, 0) || domainMax != SIMD3(1, 1, 1)
    }
}

enum CubeLUTParser {
    enum ParseError: LocalizedError, Equatable {
        case missingSize
        case unsupported1D
        case badDimension(Int)
        case wrongRowCount(expected: Int, got: Int)
        case malformedRow(line: Int)

        var errorDescription: String? {
            switch self {
            case .missingSize: "No LUT_3D_SIZE found in .cube file"
            case .unsupported1D: "1D LUTs are not supported yet (only LUT_3D_SIZE)"
            case .badDimension(let n): "Unsupported LUT_3D_SIZE \(n) (expected 2…64)"
            case .wrongRowCount(let e, let g): "Expected \(e) data rows, found \(g)"
            case .malformedRow(let l): "Malformed data row at line \(l)"
            }
        }
    }

    /// Parse `.cube` text into a `CubeLUT`. Pure and synchronous — safe to unit test.
    static func parse(_ text: String) throws -> CubeLUT {
        var dimension: Int?
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var table: [Float] = []

        for (idx, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let keyword = parts.first else { continue }

            switch keyword.uppercased() {
            case "TITLE":
                continue
            case "LUT_1D_SIZE":
                throw ParseError.unsupported1D
            case "LUT_3D_SIZE":
                guard parts.count >= 2, let n = Int(parts[1]) else { throw ParseError.missingSize }
                guard (2...64).contains(n) else { throw ParseError.badDimension(n) }
                dimension = n
                table.reserveCapacity(n * n * n * 4)
            case "DOMAIN_MIN":
                if let v = simd3(parts) { domainMin = v }
            case "DOMAIN_MAX":
                if let v = simd3(parts) { domainMax = v }
            default:
                // Data row: three floats r g b.
                guard parts.count >= 3,
                      let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                    throw ParseError.malformedRow(line: idx + 1)
                }
                table.append(contentsOf: [r, g, b, 1])
            }
        }

        guard let dim = dimension else { throw ParseError.missingSize }
        let expected = dim * dim * dim
        let got = table.count / 4
        guard got == expected else { throw ParseError.wrongRowCount(expected: expected, got: got) }

        return CubeLUT(dimension: dim, rgbaTable: table, domainMin: domainMin, domainMax: domainMax)
    }

    private static func simd3(_ parts: [String]) -> SIMD3<Float>? {
        guard parts.count >= 4,
              let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) else { return nil }
        return SIMD3(x, y, z)
    }
}

extension CubeLUT: ColorGradeProcessor {
    /// Build the Core Image filter that applies this LUT in the given working color
    /// space. The compositor tags output as Rec.709, so pass a 709/sRGB space here
    /// for SDR-authored film LUTs.
    func makeFilter(colorSpace: CGColorSpace) -> CIFilter? {
        CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": cubeData,
            "inputColorSpace": colorSpace,
        ])
    }

    func process(_ image: CIImage, colorSpace: CGColorSpace) -> CIImage {
        guard let filter = makeFilter(colorSpace: colorSpace) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }
}
