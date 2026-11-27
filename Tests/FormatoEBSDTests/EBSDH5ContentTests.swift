//
//  EBSDH5ContentTests.swift
//  Moved from Electron Microscopy Studio's EMStudioTests (at 67d6df4) by FormatoKit#147, with its fixtures and truths unchanged; the
//  app's routing and room checks stay in the app.
//  Every EBSD HDF5 file is told by what it holds (#514), or refused with a typed reason and a sentence that names it and says what it
//  holds, in plain words (no HDF5 path, no quoted dataset name):
//  - patterns: an H5OINA whose scan holds only unprocessed patterns reads those (kikuchipy refuses it unless asked for them), and an
//    H5OINA's map comes with its patterns (kikuchipy 0.13.1 leaves it empty), while a map that does not read never keeps the patterns
//    from opening;
//  - a map without patterns: AZtec's H5OINA map export (#513) and orix's own HDF5 file, read as orix 0.15.0 reads it
//    (ebsd-orix-map.truth.json, tools/ebsd-readers/make_orix_map_fixtures.py): the points `is_in_data` keeps, and of a map with several
//    rotations a point the first, the one orix shows. So do a Bruker or EDAX file saved without patterns and EMsoft's dictionary
//    indexing file (EBSDH5VendorMapTests);
//  - an EDS-only H5OINA is refused (`edsOnly`).
//  Fixtures: tools/ebsd-readers/make_h5oina_map_fixtures.py, make_orix_map_fixtures.py, make_h5ebsd_without_patterns.py.
//

import Foundation
import FormatoCore
import FormatoHDF5
import XCTest
@testable import FormatoEBSD

nonisolated final class EBSDH5ContentTests: XCTestCase {

    private static func fixture(_ name: String) -> URL { EBSDFixtures.url(name) }

    /// A sentence for a person: it names the file and quotes nothing (no 'EBSD/Data/…', no HDF5 call).
    private static func assertPlain(_ sentence: String, names file: String, file path: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(sentence.contains(file), "does not name \(file): \(sentence)", file: path, line: line)
        let rest = sentence.replacingOccurrences(of: file, with: "<file>")
        for leak in ["'", "/EBSD", "HDF5 failed", "H5D", "H5F", "dataset", "Error Domain"] {
            XCTAssertFalse(rest.contains(leak), "carries \(leak): \(sentence)", file: path, line: line)
        }
    }

    // MARK: - What it holds

    func testEachEBSDFileIsToldByWhatItHoldsOrRefusedInWords() throws {
        let patterns: [(String, EBSDFileFormat)] = [
            ("ebsd-oxford.h5oina", .oxfordH5OINA), ("ebsd-oxford-map-patterns.h5oina", .oxfordH5OINA),
            ("ebsd-oxford-map-unprocessed.h5oina", .oxfordH5OINA), ("ebsd-bruker-h5ebsd.h5", .brukerH5EBSD),
            ("ebsd-edax-h5ebsd.h5", .edaxH5EBSD), ("ebsd-kikuchipy-h5ebsd.h5", .kikuchipyH5EBSD),
        ]
        for (name, format) in patterns {
            XCTAssertEqual(EBSDH5Reader.content(url: Self.fixture(name)), .patterns(format), name)
        }
        let maps: [(String, EBSDH5Reader.MapLayout)] = [
            ("ebsd-oxford-map.h5oina", .oxford), ("ebsd-orix-map.h5", .orix), ("ebsd-orix-map-best2.h5", .orix), ("ebsd-orix-map-crop.h5", .orix),
            ("ebsd-bruker-map.h5", .bruker), ("ebsd-bruker-nopatterns-h5ebsd.h5", .bruker), ("ebsd-edax-map.h5", .edax),
            ("ebsd-edax-nopatterns-h5ebsd.h5", .edax), ("ebsd-emsoft-map.h5", .emsoft),
        ]
        for (name, layout) in maps {
            XCTAssertEqual(EBSDH5Reader.content(url: Self.fixture(name)), .map(layout), name)
        }
        let name = "ebsd-oxford-eds.h5oina"
        let sentence = "ebsd-oxford-eds.h5oina holds EDS data from AZtec but no EBSD data."
        XCTAssertEqual(EBSDH5Reader.content(url: Self.fixture(name)), .refused(EBSDReadError(.edsOnly, sentence)), name)
        Self.assertPlain(sentence, names: name)
        XCTAssertNil(EBSDH5Reader.content(url: EBSDFixtures.velox), "not an EBSD file: the Velox route decides")
    }

    // MARK: - orix's map file

    private struct Truth: Decodable {
        struct Phase: Decodable { var id: Int; var name: String; var spaceGroup: Int?; var pointGroup: String?; var color: String; var lattice: [String] }
        struct File: Decodable {
            var size: Int; var pointCount: Int; var shape: [Int]; var rotationsPerPoint: Int
            var phaseIDs: [Int]; var x: [String]; var y: [String]; var euler: [String]
            var properties: [String: [String]]; var scanUnit: String; var dx: String; var dy: String; var phases: [Phase]
        }
        var orix: String
        var files: [String: File]
    }

    private static func numbers(_ values: [String]) -> [Double] { values.map { Double($0) ?? .nan } }

    /// Each orix file reads as `orix.io.load` reads it, exactly: the points in data, their phases, x and y, the Euler angles the file
    /// stores (the first rotation of each point), every property (its first column), the phases with the colours the file writes, and
    /// the unit. Red under: `is_in_data` ignored (the cut map shows 12 points, not 6), the second rotation of each point read as a point
    /// of its own, "None" taken as a point group.
    func testOrixsMapFilesReadAsOrixReadsThem() throws {
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: Self.fixture("ebsd-orix-map.truth.json")))
        XCTAssertEqual(truth.orix, "0.15.0")
        XCTAssertEqual(truth.files.count, 3)
        for (name, expected) in truth.files.sorted(by: { $0.key < $1.key }) {
            let map = try EBSDH5Reader.readOrixMap(url: Self.fixture(name))
            let orix = OrixView(map)
            XCTAssertEqual(orix.size, expected.size, name)
            XCTAssertEqual(map.pointCount, expected.pointCount, name)
            XCTAssertEqual(try orix.shape(), expected.shape, name)
            XCTAssertEqual(orix.phaseIDs, expected.phaseIDs, name)
            XCTAssertEqual(orix.x, Self.numbers(expected.x), name)
            XCTAssertEqual(orix.y, Self.numbers(expected.y), name)
            XCTAssertEqual([orix.dx, orix.dy], Self.numbers([expected.dx, expected.dy]), name)
            let euler = Self.numbers(expected.euler)
            XCTAssertEqual(orix.euler, (0..<expected.size).map { SIMD3(euler[3 * $0], euler[3 * $0 + 1], euler[3 * $0 + 2]) }, name)
            XCTAssertEqual(map.propertyNames, expected.properties.keys.sorted(), name)
            for (property, values) in expected.properties { XCTAssertEqual(orix.property(property), Self.numbers(values), "\(name) \(property)") }
            XCTAssertEqual(map.scanUnit, expected.scanUnit, name)
            XCTAssertEqual(orix.phaseList, expected.phases.map(\.id), name)
            for phase in expected.phases where phase.id != -1 {
                let read = try XCTUnwrap(orix.phase(id: phase.id), "\(name) phase \(phase.id)")
                XCTAssertEqual(read.name, phase.name, "\(name) phase \(phase.id)")
                XCTAssertEqual(read.color, phase.color, "\(name) phase \(phase.id): the colour the file writes")
                XCTAssertEqual(read.spaceGroup, phase.spaceGroup, "\(name) phase \(phase.id)")
                XCTAssertEqual(read.pointGroup, phase.pointGroup, "\(name) phase \(phase.id)")
                // The file stores the cell as given (3.21 Å); diffpy recomputes it from its base (3.2099999999999587), so the cell is
                // held to the file's numbers within the float64 rounding of that recomputation.
                let lattice = try XCTUnwrap(read.lattice, "\(name) phase \(phase.id)")
                for (got, want) in zip(lattice, Self.numbers(phase.lattice)) { XCTAssertEqual(got, want, accuracy: 1e-12 * max(1, abs(want))) }
            }
        }
    }

    // MARK: - H5OINA patterns and their map

    /// An H5OINA scan with patterns carries its map; one that holds only unprocessed patterns reads those, pixel for pixel; one whose
    /// map does not read (kikuchipy's dummy file lists no phases) still opens its patterns.
    func testAnH5OINAsPatternsCarryTheirMapAndUnprocessedOnesRead() throws {
        let map = try EBSDH5Reader.readOxfordMap(url: Self.fixture("ebsd-oxford-map.h5oina"))
        for (name, dataset) in [("ebsd-oxford-map-patterns.h5oina", "Processed Patterns"), ("ebsd-oxford-map-unprocessed.h5oina", "Unprocessed Patterns")] {
            let read = try EBSDH5Reader.read(url: Self.fixture(name))
            XCTAssertEqual(read.patterns.datasetPath, "/1/EBSD/Data/" + dataset, name)
            XCTAssertEqual([read.scanRows, read.scanColumns, read.patternRows, read.patternColumns], [3, 4, 4, 5], name)
            XCTAssertEqual(read.map, map, "\(name): the map beside the patterns")
            let reader = try EBSDPatternReader(read)
            for (row, column) in [(0, 0), (1, 2), (2, 3)] {
                let i = row * 4 + column
                XCTAssertEqual(try reader.pattern(row: row, column: column).doubles(), (0..<20).map { Double(((i * 20 + $0) * 7) % 251) },
                               "\(name) pattern at \(row), \(column)")
            }
        }
        let dummy = try EBSDH5Reader.read(url: Self.fixture("ebsd-oxford.h5oina"))
        XCTAssertNil(dummy.map, "no phases listed: no map, and the patterns open")
        XCTAssertEqual(try EBSDPatternReader(dummy).pattern(row: 0, column: 0).count, 3600)
    }

    // MARK: - The sentences

    /// A refusal names the file and says what is wrong in words, with its reason typed; an HDF5 failure never shows its call or the
    /// path inside the file.
    func testRefusalsNameTheFileAndKeepHDF5InternalsOut() throws {
        let file = URL(fileURLWithPath: "/data/scan 7.h5oina")
        let filter = HDF5FileError.hdf5(operation: "reading /1/EBSD/Data/Processed Patterns",
                                        detail: "H5Dread: required filter 'blosc' is not registered")
        XCTAssertEqual(EBSDReadError.wrap(filter, file: file),
                       EBSDReadError(.filter, "scan 7.h5oina: its data is compressed with a filter the HDF5 library here does not have."))
        XCTAssertEqual(EBSDReadError.wrap(HDF5FileError.cannotOpen("H5Fopen failed"), file: file).text,
                       "scan 7.h5oina: it cannot be opened as an HDF5 file (it may be damaged, or still being written).")
        XCTAssertEqual(EBSDReadError.wrap(EBSDReadError(.missing("RawPatterns"), "it holds no EBSD patterns."), file: file),
                       EBSDReadError(.missing("RawPatterns"), "scan 7.h5oina: it holds no EBSD patterns."))
        XCTAssertEqual(EBSDReadError.wrap(EBSDReadError(.noScan(named: nil, scans: []), "scan 7.h5oina holds no EBSD map."), file: file).text,
                       "scan 7.h5oina holds no EBSD map.", "a sentence that names the file already is kept")
        for error: any Error in [filter, HDF5FileError.notFound("/1/EBSD/Header/Pattern Height"),
                                 HDF5FileError.unsupportedType(path: "/1/EBSD/Data/Euler", type: "compound")] {
            Self.assertPlain(EBSDReadError.wrap(error, file: file).text, names: "scan 7.h5oina")
        }

        let velox = EBSDFixtures.velox
        XCTAssertThrowsError(try EBSDH5Reader.read(url: velox)) { error in
            XCTAssertEqual(error as? EBSDReadError,
                           EBSDReadError(.notEBSD, "velox-tiny.emd: it is not an EBSD file (it does not name the software that wrote it)."))
        }
        XCTAssertThrowsError(try EBSDH5Reader.readMap(url: Self.fixture("ebsd-oxford.h5oina"))) { error in
            XCTAssertEqual(error as? EBSDReadError, EBSDReadError(.holdsPatterns, "ebsd-oxford.h5oina holds EBSD patterns; its map comes with them."))
        }
        XCTAssertThrowsError(try EBSDH5Reader.read(url: Self.fixture("ebsd-bruker-nopatterns-h5ebsd.h5"))) { error in
            let text = (error as? EBSDReadError)?.text ?? "\(error)"
            XCTAssertEqual(text, "ebsd-bruker-nopatterns-h5ebsd.h5: it holds no EBSD patterns.")
            XCTAssertEqual((error as? EBSDReadError)?.reason, .missing("RawPatterns"))
            Self.assertPlain(text, names: "ebsd-bruker-nopatterns-h5ebsd.h5")
        }
    }
}
