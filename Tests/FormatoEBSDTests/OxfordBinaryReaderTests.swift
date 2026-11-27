//
//  OxfordBinaryReaderTests.swift
//  Moved from Electron Microscopy Studio's EMStudioTests (at 67d6df4) by FormatoKit#147, with its fixtures unchanged; the app's door
//  (`OxfordOpening`: the `.ctf` paired by name, the routing) stays in the app.
//  OxfordBinaryReader against kikuchipy 0.13.1: kikuchipy's own patterns.ebsp and the dummy layouts its reader tests write
//  (Fixtures/sem/oxford, from tools/ebsd-readers/make_oxford_fixtures.py) read with the values kikuchipy.load gives: version, shapes,
//  pixel type, steps, the beam and map positions, the file order, and every pixel bit-exact (the `.u8`/`.u16` file beside each
//  `.json` is the pattern array in map order as numpy returned it, which is what `EBSDDataset.allPatterns` gives).
//

import Foundation
import FormatoCore
import XCTest
@testable import FormatoEBSD

nonisolated final class OxfordBinaryReaderTests: XCTestCase {

    nonisolated struct Truth: Decodable {
        let refused: String?
        let loadFails: Bool?
        let version: Int?
        let nPatternsInHeader: Int?
        let navigationShape: [Int]?
        let signalShape: [Int]?
        let dtype: String?
        let stepSizes: [Double]?
        let scanUnit: String?
        let map1dID: [Int]?
        let fileOrder: [Int]?
        let beamX: [Double]?
        let beamY: [Double]?
        let mapX: [Double]?
        let mapY: [Double]?
        let patterns: String?
        enum CodingKeys: String, CodingKey {
            case refused, loadFails, version, nPatternsInHeader, navigationShape, signalShape, dtype, stepSizes, scanUnit, map1dID,
                 fileOrder, patterns
            case beamX = "beam_x"
            case beamY = "beam_y"
            case mapX = "map_x"
            case mapY = "map_y"
        }
    }

    static let folder = EBSDFixtures.url("sem/oxford")

    static func truth(_ name: String) throws -> Truth {
        try JSONDecoder().decode(Truth.self, from: Data(contentsOf: folder.appendingPathComponent(name + ".json")))
    }

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    func assertReads(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let truth = try Self.truth(name)
        let url = Self.url(name)
        if let refused = truth.refused {
            XCTAssertThrowsError(try OxfordBinaryReader.read(url: url), name, file: file, line: line) { error in
                XCTAssertEqual(error as? OxfordBinaryReader.Refusal, .compressed, "\(name): \(refused)", file: file, line: line)
            }
            return
        }
        let data = try Data(contentsOf: url)
        XCTAssertEqual(try OxfordBinaryReader.patternCountInHeader(data: data), truth.nPatternsInHeader, "\(name): patterns in header", file: file, line: line)
        if truth.loadFails == true {
            // kikuchipy's conftest spaces the version-5 start table by the 16-byte header while writing the 24-byte one; kikuchipy
            // fails on it too (its own test checks only the count above).
            XCTAssertThrowsError(try OxfordBinaryReader.read(url: url), "\(name): kikuchipy cannot load it either", file: file, line: line)
            return
        }
        let dataset = try OxfordBinaryReader.read(url: url)
        let navigation = truth.navigationShape ?? []
        XCTAssertEqual(dataset.format, .oxfordBinary, name, file: file, line: line)
        XCTAssertEqual(dataset.version, String(truth.version ?? -1), "\(name): version", file: file, line: line)
        XCTAssertEqual([dataset.scanRows, dataset.scanColumns], navigation.count == 2 ? navigation : [1, navigation[0]], "\(name): scan shape", file: file, line: line)
        XCTAssertEqual([dataset.patternRows, dataset.patternColumns], truth.signalShape, "\(name): pattern shape", file: file, line: line)
        XCTAssertEqual(dataset.dataType, truth.dtype == "uint16" ? .uint16 : .uint8, "\(name): pixel type", file: file, line: line)
        XCTAssertEqual([dataset.stepY, dataset.stepX], navigation.count == 2 ? truth.stepSizes : [1, 1], "\(name): steps", file: file, line: line)
        XCTAssertEqual(dataset.scanUnit, truth.scanUnit, "\(name): scan unit", file: file, line: line)
        XCTAssertNil(dataset.map, name, file: file, line: line)
        let metadata = try OxfordBinaryReader.metadata(data: data)
        XCTAssertEqual(metadata.map1DIDs, truth.map1dID, "\(name): map 1D ids", file: file, line: line)
        XCTAssertEqual(metadata.fileOrder, truth.fileOrder, "\(name): file order", file: file, line: line)
        XCTAssertEqual(metadata.beamX, truth.beamX, "\(name): beam x", file: file, line: line)
        XCTAssertEqual(metadata.beamY, truth.beamY, "\(name): beam y", file: file, line: line)
        XCTAssertEqual(metadata.mapX.map { $0.map(Double.init) }, truth.mapX, "\(name): map x", file: file, line: line)
        XCTAssertEqual(metadata.mapY.map { $0.map(Double.init) }, truth.mapY, "\(name): map y", file: file, line: line)
        // Every pixel, in map order, as numpy returned it: the whole set, then one row and one pattern through the reader.
        let reference = try Data(contentsOf: Self.url(XCTUnwrap(truth.patterns)))
        let all = try dataset.allPatterns()
        XCTAssertEqual(all.shape, [dataset.scanRows, dataset.scanColumns, dataset.patternRows, dataset.patternColumns], "\(name): shape", file: file, line: line)
        XCTAssertEqual(all.bytes, reference, "\(name): pixels bit-exact", file: file, line: line)
        let reader = try EBSDPatternReader(dataset)
        let bytesPerPattern = dataset.patternPixels * dataset.dataType.byteSize
        let lastRow = dataset.scanRows - 1
        XCTAssertEqual(try reader.row(lastRow).bytes, reference.suffix(dataset.scanColumns * bytesPerPattern), "\(name): last row", file: file, line: line)
        let last = dataset.patternCount - 1
        XCTAssertEqual(try reader.pattern(row: lastRow, column: dataset.scanColumns - 1).bytes, reference.suffix(bytesPerPattern), "\(name): pattern \(last)", file: file, line: line)
    }

    /// kikuchipy's test file: nickel_ebsd_small as a version-2 .ebsp, 3 x 3 patterns of 60 x 60 uint8, rolled one record in the
    /// file so the start table reorders them; the step 1.5 µm from the footers.
    func testKikuchipysPatternsReadBitExact() throws {
        try assertReads("patterns.ebsp")
        let dataset = try OxfordBinaryReader.read(url: Self.url("patterns.ebsp"))
        XCTAssertEqual([dataset.scanRows, dataset.scanColumns], [3, 3])
        XCTAssertEqual([dataset.stepY, dataset.stepX], [1.5, 1.5])
        XCTAssertEqual(dataset.patterns.fileIndexByPosition, [8, 0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(dataset.patterns.layout, .records(offset: 8 + 9 * 8, recordBytes: 16 + 3600 + 18, patternOffset: 16))
        XCTAssertEqual(try EBSDPatternReader(dataset).pattern(row: 0, column: 0).doubles().count, 3600)
        XCTAssertEqual(dataset.detector.projectionCenters, [SIMD3(0.5, 0.5, 0.5)], "kikuchipy's default detector")
        XCTAssertEqual(dataset.detector.sampleTilt, 70)
    }

    /// Every layout kikuchipy's reader tests write: versions 0, 1, 2, 4 (and the 5/6 count), uint16, a bigger map with
    /// 62 x 73 patterns, a file missing one pattern (a 1D list in pixels), and a compressed file refused by name.
    func testEveryKikuchipyLayoutReadsAsKikuchipy() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path)
            .filter { $0.hasPrefix("dummy-") && $0.hasSuffix(".ebsp") }.sorted()
        XCTAssertEqual(names.count, 10, "the fixture set")
        for name in names { try assertReads(name) }
    }

    func testAFileMissingOnePatternIsAListInPixels() throws {
        let dataset = try OxfordBinaryReader.read(url: Self.url("dummy-v2-missing.ebsp"))
        XCTAssertEqual([dataset.scanRows, dataset.scanColumns], [1, 5])
        XCTAssertEqual(dataset.scanUnit, "px")
        XCTAssertNil(dataset.patterns.fileIndexByPosition, "the five present records are in file order")
        let metadata = try OxfordBinaryReader.metadata(data: Data(contentsOf: Self.url("dummy-v2-missing.ebsp")))
        XCTAssertEqual(metadata.map1DIDs, [1, 2, 3, 4, 5])
        XCTAssertEqual(metadata.beamY, [0, 1, 1, 1, 0])
        XCTAssertEqual(metadata.beamX, [2, 0, 1, 2, 0])
    }

    func testAVersion0FileHasNoPositions() throws {
        let dataset = try OxfordBinaryReader.read(url: Self.url("dummy-v0.ebsp"))
        XCTAssertEqual([dataset.scanRows, dataset.scanColumns], [1, 6])
        let metadata = try OxfordBinaryReader.metadata(data: Data(contentsOf: Self.url("dummy-v0.ebsp")))
        XCTAssertNil(metadata.beamX)
        XCTAssertNil(metadata.beamY)
        XCTAssertNil(metadata.mapX)
    }

    func testTooShortAndTruncatedFilesAreRefusedByName() throws {
        let url = URL(fileURLWithPath: "/short.ebsp")
        XCTAssertThrowsError(try OxfordBinaryReader.read(data: Data([1, 2, 3]), url: url)) { error in
            XCTAssertEqual(error as? OxfordBinaryReader.Refusal, .tooShort)
        }
        let whole = try Data(contentsOf: Self.url("patterns.ebsp"))
        XCTAssertThrowsError(try OxfordBinaryReader.read(data: whole.prefix(whole.count - 100), url: url)) { error in
            guard case .truncated? = error as? OxfordBinaryReader.Refusal else { return XCTFail("\(error)") }
        }
        for refusal in [OxfordBinaryReader.Refusal.tooShort, .compressed, .noPatternTable, .truncated(needed: 2, have: 1)] {
            XCTAssertTrue(refusal.reason.hasSuffix("."), refusal.reason)
        }
    }

    /// A version word of Int64.min (negating it trapped) and a NaN beam position (converting it to a map size trapped) are refused in
    /// the reader's words, at the drop and at the open.
    func testAVersionWordWithNoVersionAndANonFiniteBeamPositionAreRefusedInWords() throws {
        let whole = try Data(contentsOf: Self.url("patterns.ebsp"))
        // Int64.min, little-endian, as the version word.
        var noVersion = whole
        noVersion.replaceSubrange(0..<8, with: Data([0, 0, 0, 0, 0, 0, 0, 0x80]))
        XCTAssertThrowsError(try OxfordBinaryReader.patternCountInHeader(data: noVersion)) { error in
            XCTAssertEqual(error as? OxfordBinaryReader.Refusal, .version(.min))
        }
        XCTAssertEqual(OxfordBinaryReader.Refusal.version(.min).reason, "its version word -9223372036854775808 is not an .ebsp version.")
        // NaN as the beam y of the last pattern in map order (record 7: kikuchipy's file is rolled one record), whose footer is a flag
        // byte, beam x, a flag byte and beam y after the 16-byte header and the 3600 pixels.
        let metadata = try OxfordBinaryReader.metadata(data: whole)
        let lastRecord = try XCTUnwrap(metadata.fileOrder.last)
        let beamY = 8 + 9 * 8 + lastRecord * (16 + 3600 + 18) + 16 + 3600 + 10
        let stored = Double(bitPattern: UInt64(littleEndian: whole.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: beamY, as: UInt64.self) }))
        XCTAssertEqual(stored, metadata.beamY?.last, "the bytes replaced are that footer's beam y")
        var nan = Data()
        withUnsafeBytes(of: Double.nan.bitPattern.littleEndian) { nan.append(contentsOf: $0) }
        var notFinite = whole
        notFinite.replaceSubrange(beamY..<(beamY + 8), with: nan)
        XCTAssertThrowsError(try OxfordBinaryReader.read(data: notFinite, url: URL(fileURLWithPath: "/not-finite.ebsp"))) { error in
            XCTAssertEqual(error as? OxfordBinaryReader.Refusal, .beamPositions)
        }
        XCTAssertEqual(OxfordBinaryReader.Refusal.beamPositions.reason,
                       "its beam positions are not finite or lie too many steps apart, which gives no map.")
    }

    /// macEM#638: a file cut inside the last record's footer (its beam position past the end) is refused, not trapped on a
    /// force-unwrap. Red before: `beamX(...)!` trapped.
    func testAFooterCutShortIsRefusedNotTrapped() throws {
        let whole = try Data(contentsOf: Self.url("patterns.ebsp"))
        let cut = whole.prefix(whole.count - 18)   // the last record in the file loses its 18-byte footer
        XCTAssertThrowsError(try OxfordBinaryReader.metadata(data: cut))
        XCTAssertThrowsError(try OxfordBinaryReader.read(data: cut, url: Self.url("patterns.ebsp")))
    }
}
