import Testing
@testable import PalmierPro

@Suite("Cube LUT parsing")
struct CubeLUTParserTests {

    /// A 2×2×2 identity cube: each corner maps to itself (red varies fastest).
    static let identity2 = """
    # sample identity LUT
    TITLE "identity"
    LUT_3D_SIZE 2
    0 0 0
    1 0 0
    0 1 0
    1 1 0
    0 0 1
    1 0 1
    0 1 1
    1 1 1
    """

    @Test func parsesDimensionAndCount() throws {
        let lut = try CubeLUTParser.parse(Self.identity2)
        #expect(lut.dimension == 2)
        #expect(lut.rgbaTable.count == 2 * 2 * 2 * 4)   // 8 entries × RGBA
    }

    @Test func forcesAlphaToOne() throws {
        let lut = try CubeLUTParser.parse(Self.identity2)
        for i in stride(from: 3, to: lut.rgbaTable.count, by: 4) {
            #expect(lut.rgbaTable[i] == 1)
        }
    }

    @Test func preservesFileOrderRedFastest() throws {
        let lut = try CubeLUTParser.parse(Self.identity2)
        // Second entry is (1,0,0) — red advanced first.
        #expect(lut.rgbaTable[4] == 1)
        #expect(lut.rgbaTable[5] == 0)
        #expect(lut.rgbaTable[6] == 0)
    }

    @Test func defaultDomainIsZeroToOne() throws {
        let lut = try CubeLUTParser.parse(Self.identity2)
        #expect(!lut.hasNonDefaultDomain)
    }

    @Test func ignoresCommentsAndBlankLines() throws {
        let text = "\n# a\n\nLUT_3D_SIZE 2\n# b\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n\n"
        #expect(throws: Never.self) { try CubeLUTParser.parse(text) }
    }

    @Test func missingSizeThrows() {
        #expect(throws: CubeLUTParser.ParseError.missingSize) {
            try CubeLUTParser.parse("0 0 0\n1 1 1")
        }
    }

    @Test func oneDimensionalIsRejected() {
        #expect(throws: CubeLUTParser.ParseError.unsupported1D) {
            try CubeLUTParser.parse("LUT_1D_SIZE 4\n0 0 0\n1 1 1")
        }
    }

    @Test func wrongRowCountThrows() {
        // Declares 2 but only supplies 3 rows.
        #expect(throws: CubeLUTParser.ParseError.wrongRowCount(expected: 8, got: 3)) {
            try CubeLUTParser.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0")
        }
    }

    @Test func malformedRowThrows() {
        #expect(throws: (any Error).self) {
            try CubeLUTParser.parse("LUT_3D_SIZE 2\n0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        }
    }

    @Test func parsesNonDefaultDomain() throws {
        let text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 4 4 4\n"
            + (0..<8).map { _ in "0.5 0.5 0.5" }.joined(separator: "\n")
        let lut = try CubeLUTParser.parse(text)
        #expect(lut.hasNonDefaultDomain)
        #expect(lut.domainMax == .init(4, 4, 4))
    }
}
