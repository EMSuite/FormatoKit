//
//  EDAXBinaryReaderTests.swift
//  Moved from Electron Microscopy Studio's EMStudioTests (at 67d6df4) by FormatoKit#147, with its fixtures and truth unchanged; the
//  app's door (`EDAXOpening`: the hexagonal refusal, the `.ang` paired by name) stays in the app.
//  The EDAX .up1/.up2 reader against kikuchipy 0.13.1 (`edax_binary.file_reader`): every Fixtures/ebsd-edax-binary*.up* reads with the
//  values of Fixtures/ebsd-edax.truth.json (tools/ebsd-readers/make_edax_fixtures.py): the header, the navigation and pattern
//  shapes, the element type, kikuchipy's warning as the note, the first and last pattern and the sha256 of every pattern in map order;
//  version 2 and a damaged header (sizes whose products leave the Int range, an empty map) refused in words. A dataset over the file's
//  records reads the same patterns through `EBSDPatternReader`.
//

import Foundation
import FormatoCore
import XCTest
@testable import FormatoEBSD

nonisolated final class EDAXBinaryReaderTests: XCTestCase {

    nonisolated struct Header: Decodable {
        let sx: Int, sy: Int, nx: Int, ny: Int
        let patternOffset: Int, nPatterns: Int
        let dx: String, dy: String
        let isHex: Bool
        enum CodingKeys: String, CodingKey {
            case sx, sy, nx, ny, dx, dy
            case patternOffset = "pattern_offset", nPatterns = "n_patterns", isHex = "is_hex"
        }
    }

    nonisolated struct Truth: Decodable {
        let fileSHA256: String
        let version: Int
        let header: Header?
        let navShape: [Int]?
        let sigShape: [Int]?
        let dtype: String?
        let warnings: [String]?
        let patternsSHA256: String?
        let firstPattern: [Int]?
        let lastPattern: [Int]?
        let refused: String?
        enum CodingKeys: String, CodingKey {
            case version, header, dtype, warnings, refused
            case fileSHA256 = "file_sha256", navShape = "nav_shape", sigShape = "sig_shape", patternsSHA256 = "patterns_sha256"
            case firstPattern = "first_pattern", lastPattern = "last_pattern"
        }
    }

    nonisolated struct TruthFile: Decodable {
        let kikuchipy: String
        let up: [String: Truth]
    }

    static func fixture(_ name: String) -> URL { EBSDFixtures.url(name) }

    static func truth() throws -> TruthFile {
        try JSONDecoder().decode(TruthFile.self, from: Data(contentsOf: fixture("ebsd-edax.truth.json")))
    }

    static func sha256(_ data: Data) -> String { EBSDFixtures.sha256(data) }

    private func ints(_ array: FormatoArray) -> [Int] { array.doubles().map { Int($0) } }

    func testTruthIsKikuchipy0131() throws {
        let truth = try Self.truth()
        XCTAssertEqual(truth.kikuchipy, "0.13.1")
        XCTAssertEqual(Set(truth.up.keys), ["ebsd-edax-binary.up1", "ebsd-edax-binary-hex.up2", "ebsd-edax-binary.up2", "ebsd-edax-binary-v2.up2"])
    }

    func testEveryFixtureReadsAsKikuchipyReadsIt() throws {
        for (name, expected) in try Self.truth().up where expected.refused == nil {
            let url = Self.fixture(name)
            XCTAssertEqual(Self.sha256(try Data(contentsOf: url)), expected.fileSHA256, "\(name): the fixture is not the one the truth was written from")
            let header = try XCTUnwrap(expected.header, name)
            let file = try EDAXBinaryReader.read(url: url)
            XCTAssertEqual(file.version, expected.version, name)
            XCTAssertEqual(file.patternColumns, header.sx, "\(name) sx")
            XCTAssertEqual(file.patternRows, header.sy, "\(name) sy")
            XCTAssertEqual(file.patternOffset, header.patternOffset, "\(name) offset")
            XCTAssertEqual(file.scanColumns, header.nx, "\(name) nx")
            XCTAssertEqual(file.scanRows, header.ny, "\(name) ny")
            XCTAssertEqual(file.patternCount, header.nPatterns, "\(name) n_patterns")
            let dx = try XCTUnwrap(Double(header.dx)), dy = try XCTUnwrap(Double(header.dy))
            XCTAssertEqual(file.stepX, dx, "\(name) dx")
            XCTAssertEqual(file.stepY, dy, "\(name) dy")
            XCTAssertEqual(file.isHexagonal, header.isHex, "\(name) is_hex")
            XCTAssertEqual(file.scanUnit, "um", name)
            XCTAssertEqual(file.dataType.rawValue, expected.dtype, "\(name) dtype")
            // kikuchipy's one navigation dimension is one row here.
            let nav = try XCTUnwrap(expected.navShape)
            XCTAssertEqual([file.scanRows, file.scanColumns], nav.count == 1 ? [1, nav[0]] : nav, "\(name) scan shape")
            XCTAssertEqual([file.patternRows, file.patternColumns], expected.sigShape, "\(name) pattern shape")
            XCTAssertEqual(file.note, expected.warnings?.first, "\(name) note")
            let all = try EDAXBinaryReader.allPatterns(file)
            XCTAssertEqual(all.shape, [file.scanRows, file.scanColumns, file.patternRows, file.patternColumns], "\(name) all patterns shape")
            XCTAssertEqual(Self.sha256(all.bytes), expected.patternsSHA256, "\(name): every pattern, bit for bit")
            let first = try EDAXBinaryReader.pattern(file, index: 0)
            XCTAssertEqual(first.shape, [file.patternRows, file.patternColumns], name)
            XCTAssertEqual(ints(first), expected.firstPattern, "\(name) first pattern")
            let last = try EDAXBinaryReader.pattern(file, row: file.scanRows - 1, column: file.scanColumns - 1)
            XCTAssertEqual(ints(last), expected.lastPattern, "\(name) last pattern")
            XCTAssertThrowsError(try EDAXBinaryReader.pattern(file, index: file.patternCount), name)
            XCTAssertThrowsError(try EDAXBinaryReader.pattern(file, row: file.scanRows, column: 0), name)
        }
    }

    func testVersion2IsRefusedAsUpstreamRefusesIt() throws {
        let expected = try XCTUnwrap(try Self.truth().up["ebsd-edax-binary-v2.up2"])
        let url = Self.fixture("ebsd-edax-binary-v2.up2")
        XCTAssertEqual(Self.sha256(try Data(contentsOf: url)), expected.fileSHA256)
        XCTAssertNotNil(expected.refused, "kikuchipy refuses version 2")
        XCTAssertThrowsError(try EDAXBinaryReader.read(url: url)) { error in
            let text = (error as? EDAXReadError)?.text ?? ""
            XCTAssertTrue(text.contains("version 2"), text)
        }
    }

    func testAShortFileAndAWrongExtensionAreRefusedInWords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("edax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A version 3 header that promises 3 x 4 patterns of 6 x 8 uint16 over 20 bytes of patterns.
        var bytes = Data()
        for word in [3, 8, 6, 42] as [UInt32] { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(0)
        for word in [4, 3] as [UInt32] { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(0)
        for value in [0.25, 0.5] { withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(Data(count: 20))
        let short = folder.appendingPathComponent("short.up2")
        try bytes.write(to: short)
        XCTAssertThrowsError(try EDAXBinaryReader.read(url: short)) { error in
            XCTAssertTrue(((error as? EDAXReadError)?.text ?? "").contains("holds 0"), String(describing: error))
        }
        let header = folder.appendingPathComponent("header-only.up1")
        try Data([1, 0, 0]).write(to: header)
        XCTAssertThrowsError(try EDAXBinaryReader.read(url: header))
        let wrong = folder.appendingPathComponent("patterns.dat")
        try bytes.write(to: wrong)
        XCTAssertThrowsError(try EDAXBinaryReader.read(url: wrong)) { error in
            XCTAssertTrue(((error as? EDAXReadError)?.text ?? "").contains(".up1 or .up2"), String(describing: error))
        }
    }

    /// A header in the file's layout: version, sx, sy and the pattern offset, then from version 3 one pad byte, nx, ny, the hexagonal-grid
    /// flag (off) and the steps.
    private static func header(version: UInt32, sx: UInt32, sy: UInt32, offset: UInt32, nx: UInt32 = 1, ny: UInt32 = 1) -> Data {
        var bytes = Data()
        for word in [version, sx, sy, offset] { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        guard version >= 3 else { return bytes }
        bytes.append(0)
        for word in [nx, ny] { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(0)
        for value in [1.0, 1.0] { withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        return bytes
    }

    func testADamagedHeaderIsRefusedInWordsInsteadOfTrapping() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("edax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func refusal(_ bytes: Data, _ name: String) throws -> String {
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            do {
                _ = try EDAXBinaryReader.read(url: url)
                XCTFail("\(name) was read")
                return ""
            } catch {
                return (error as? EDAXReadError)?.text ?? String(describing: error)
            }
        }
        // A pattern of (2^32 - 1)^2 pixels: sx * sy left the Int range and trapped.
        let huge = try refusal(Self.header(version: 3, sx: .max, sy: .max, offset: 42), "huge-pattern.up1")
        XCTAssertEqual(huge, "huge-pattern.up1 states a 4294967295 x 4294967295 pattern, larger than the whole file (42 bytes).")
        // A map of (2^32 - 1)^2 patterns: nx * ny left the Int range and trapped.
        let map = try refusal(Self.header(version: 3, sx: 1, sy: 1, offset: 42, nx: .max, ny: .max), "huge-map.up2")
        XCTAssertEqual(map, "huge-map.up2 states 4294967295 x 4294967295 patterns of 1 x 1 but holds 0.")
        // A map with no columns, and a version 1 file with no pattern after its header, opened as empty scans.
        let empty = try refusal(Self.header(version: 3, sx: 8, sy: 8, offset: 42, nx: 0, ny: 3), "no-columns.up1")
        XCTAssertEqual(empty, "no-columns.up1 states a 3 x 0 map.")
        let none = try refusal(Self.header(version: 1, sx: 8, sy: 8, offset: 16) + Data(count: 63), "no-pattern.up1")
        XCTAssertEqual(none, "no-pattern.up1 holds no complete 8 x 8 pattern after byte 16 (79 bytes).")
    }

    // MARK: The records

    /// A version 1 `.up1` as one dataset over its records (as a consumer pairs it), read through `EBSDPatternReader`: the patterns are
    /// the file's records, bit-exact.
    func testADatasetOverTheRecordsReadsThePatternsBitExact() throws {
        let url = Self.fixture("ebsd-edax-binary.up1")
        let file = try EDAXBinaryReader.read(url: url)
        let source = EBSDPatternSource(url: url, layout: .records(offset: file.patternOffset, recordBytes: file.bytesPerPattern, patternOffset: 0),
                                       fileShape: [file.patternCount, file.patternRows, file.patternColumns], dataType: file.dataType)
        let dataset = try EBSDDataset(format: .edaxBinary, manufacturer: "edax", version: String(file.version), scanGroup: "", scanGroups: [],
                                      scanRows: file.scanRows, scanColumns: file.scanColumns, patternRows: file.patternRows,
                                      patternColumns: file.patternColumns, dataType: file.dataType, stepY: file.stepY, stepX: file.stepX,
                                      scanUnit: file.scanUnit,
                                      detector: EBSDDetectorGeometry(rows: file.patternRows, columns: file.patternColumns,
                                                                     projectionCenters: [SIMD3(0.5, 0.5, 0.5)]),
                                      patterns: source).validated()
        XCTAssertEqual([dataset.scanRows, dataset.scanColumns], [1, 9])
        XCTAssertEqual(try dataset.allPatterns(), try EDAXBinaryReader.allPatterns(file))
        let reader = try EBSDPatternReader(dataset)
        XCTAssertEqual(try reader.pattern(row: 0, column: 8), try EDAXBinaryReader.pattern(file, index: 8))
        XCTAssertEqual(try reader.row(0).bytes, try EDAXBinaryReader.allPatterns(file).bytes, "the one row is the whole scan")
    }
}
