//
//  EBSDReaderBundleParityTests.swift
//  Moved from Electron Microscopy Studio's SEMReaderBundleParityTests (EMStudioTests, at 67d6df4) by FormatoKit#147: the reader
//  bundles of the app's tools/parity/sem/references/m1 (kikuchipy 0.13.1's `kikuchipy.load`, orix 0.15.0's `orix.io.load`), copied
//  with their inputs byte for byte into Fixtures/bundles, against the kit's readers on the files the bundles were emitted from. The
//  app keeps the cases its own door, demo data or other kits answer (the north-star scan from the shipped demo file, the MSA spectrum,
//  the m2 background chain, the SEM TIFF and virtual BSE cases) and its door's own reading of these files.
//  A pattern file is read by its reader (`EBSDH5Reader`, `OxfordBinaryReader`, `NORDIFOpening`; an EDAX `.up1` as one dataset over its
//  records), validated, and read through `EBSDPatternReader` by scan row as a pattern browser reads it; EDAX's hexagonal `.up2` is read
//  by `EDAXBinaryReader`, which keeps kikuchipy's one-row reading. Navigation and signal shape, dtype, the whole scan's sha256 and the
//  first and last pattern are exact; each pattern's minimum, maximum and mean, the mean pattern, the projection centres, the static
//  background and the map's first Euler angles are held at the bundle's tolerances. The orientation maps go through `ANGReader` and
//  `CTFReader`, the map's shape and steps as orix's `CrystalMap` derives them from the columns (`OrixView`). An EMsoft EBSD pattern
//  file has no reader: its test holds the refusal. Last, every bundle folder is named by a comparing test or allowlisted with a reason.
//  The duplex steel map was emitted from orix-data's download; the committed .ang fixture is the same bytes (checked by sha256).
//

import CryptoKit
import Foundation
import FormatoCore
import XCTest
@testable import FormatoEBSD

nonisolated final class EBSDReaderBundleParityTests: XCTestCase {

    // MARK: - The cases

    /// Pattern files a reader reads into a dataset, each on the committed fixture its bundle names.
    private static let patternCases = ["m1/read-kikuchipy-h5ebsd", "m1/read-bruker-h5ebsd", "m1/read-edax-h5ebsd", "m1/read-oxford-h5oina",
                                       "m1/read-oxford-binary", "m1/read-edax-up1", "m1/read-nordif"]
    /// EDAX's `.up2` on a hexagonal grid: kikuchipy reads its patterns as one row.
    private static let hexagonalCase = "m1/read-edax-up2"
    private static let angCase = "m1/read-ang-sdss-ferrite-austenite"
    private static let ctfCase = "m1/read-ctf-planted-oxford"
    /// Every case a test in this file compares with a Swift port.
    private static let comparedHere = patternCases + [hexagonalCase, angCase, ctfCase]
    /// The bundles that no test compares with a Swift port, each with the reason.
    private static let allowlist: [String: String] = [
        "m1/read-emsoft-ebsd": "no reader reads an EMsoft EBSD pattern file yet; testTheEMsoftEBSDFileIsRefusedInWords holds the refusal",
    ]

    // MARK: - Helpers

    /// The committed copy of a downloaded dataset a bundle was emitted from (`sem-data/...` on the Python side).
    private static func committedCopy(of path: String) -> URL? {
        switch path {
        case "sem-data/orix/sdss_ferrite_austenite.ang": return EBSDFixtures.url("ebsd-sdss-ferrite-austenite.ang")
        default: return nil
        }
    }

    /// The file a bundle was emitted from: its committed fixture, or the committed copy of its downloaded dataset, checked to be the
    /// bytes the manifest names.
    private func input(_ ref: SEMParityReference) throws -> URL {
        let name = ref.manifest.caseName
        let expected = try XCTUnwrap(ref.manifest.inputs.first, "\(name) names no input")
        let url: URL
        if expected.path.hasPrefix("fixtures/") { url = try XCTUnwrap(ref.inputURL(0), "\(name): \(expected.path)") }
        else { url = try XCTUnwrap(Self.committedCopy(of: expected.path), "\(name): no committed copy of \(expected.path)") }
        XCTAssertEqual(EBSDFixtures.sha256(try Data(contentsOf: url)), expected.sha256, "\(name): \(url.lastPathComponent) is not the bundle's input")
        return url
    }

    /// The bundle's array, named with its case, so a failure in a loop over cases says which one.
    private func reference(_ ref: SEMParityReference, _ array: String) throws -> SEMParityReference.LoadedArray {
        let a = try ref.array(array)
        return SEMParityReference.LoadedArray(name: "\(ref.manifest.caseName)/\(array)", shape: a.shape, dtype: a.dtype, values: a.values,
                                              rtol: a.rtol, atol: a.atol)
    }

    /// kikuchipy's navigation shape as the Swift scan holds it: one navigation axis of n patterns is one scan row of n.
    private static func scanShape(_ navigation: [Int]) -> [Int] {
        navigation.count == 1 ? [1, navigation[0]] : navigation
    }

    /// The dataset a reader reads from the pattern file at `url`, validated.
    private static func dataset(_ url: URL) throws -> EBSDDataset {
        switch url.pathExtension.lowercased() {
        case "ebsp": return try OxfordBinaryReader.read(url: url).validated()
        case "dat": return try NORDIFOpening.open(url: url).validated()
        case "up1", "up2":
            // One dataset over the file's records, as a consumer pairs it without a map beside it (kikuchipy's default detector).
            let file = try EDAXBinaryReader.read(url: url)
            let source = EBSDPatternSource(url: url, layout: .records(offset: file.patternOffset, recordBytes: file.bytesPerPattern, patternOffset: 0),
                                           fileShape: [file.patternCount, file.patternRows, file.patternColumns], dataType: file.dataType)
            return try EBSDDataset(format: .edaxBinary, manufacturer: "edax", version: String(file.version), scanGroup: "", scanGroups: [],
                                   scanRows: file.scanRows, scanColumns: file.scanColumns, patternRows: file.patternRows,
                                   patternColumns: file.patternColumns, dataType: file.dataType, stepY: file.stepY, stepX: file.stepX,
                                   scanUnit: file.scanUnit,
                                   detector: EBSDDetectorGeometry(rows: file.patternRows, columns: file.patternColumns,
                                                                  projectionCenters: [SIMD3(0.5, 0.5, 0.5)]),
                                   patterns: source).validated()
        default: return try EBSDH5Reader.read(url: url).validated()
        }
    }

    // MARK: - Pattern readers

    /// A reader's scan against a pattern bundle: the shapes and dtype in `values`, the sha256 of the whole scan (`values.patterns`,
    /// the bytes in map order), the first and last pattern exact, then every pattern's minimum, maximum and mean and the mean
    /// pattern at the bundle's tolerances, read row by row as a pattern browser reads the scan. `row` hands one scan row of
    /// patterns in map order, `pattern` the pattern at (row, column).
    private func comparePatterns(_ ref: SEMParityReference, scanRows: Int, scanColumns: Int, patternRows: Int, patternColumns: Int,
                                 dataType: FormatoDataType, row: (Int) throws -> FormatoArray,
                                 pattern: (Int, Int) throws -> FormatoArray) throws {
        let name = ref.manifest.caseName
        let navigation = try XCTUnwrap(ref.values["navigation_shape_rc"] as? [Int], "\(name): navigation shape")
        let signal = [patternRows, patternColumns]
        XCTAssertEqual([scanRows, scanColumns], Self.scanShape(navigation), "\(name): navigation shape")
        XCTAssertEqual(signal, ref.values["signal_shape_rc"] as? [Int], "\(name): signal shape")
        XCTAssertEqual(dataType.rawValue, ref.values["dtype"] as? String, "\(name): dtype")

        SEMAssertParity(try pattern(0, 0).doubles(), try reference(ref, "first_pattern"), shape: signal)
        if ref.manifest.arrays["last_pattern"] != nil {
            SEMAssertParity(try pattern(scanRows - 1, scanColumns - 1).doubles(), try reference(ref, "last_pattern"), shape: signal)
        }

        let pixels = patternRows * patternColumns
        var minima: [Double] = [], maxima: [Double] = [], means: [Double] = []
        var sum = [Double](repeating: 0, count: pixels)
        var hasher = SHA256()
        for r in 0..<scanRows {
            let patterns = try row(r)
            hasher.update(data: patterns.bytes)
            let values = patterns.doubles()
            XCTAssertEqual(values.count, scanColumns * pixels, "\(name): scan row \(r)")
            for k in 0..<(values.count / pixels) {
                let start = k * pixels
                var low = Double.infinity, high = -Double.infinity, total = 0.0
                for i in 0..<pixels {
                    let v = values[start + i]
                    if v < low { low = v }
                    if v > high { high = v }
                    total += v
                    sum[i] += v
                }
                minima.append(low)
                maxima.append(high)
                means.append(total / Double(pixels))
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let patternsValue = ref.values["patterns"] as? [String: Any]
        XCTAssertEqual(digest, patternsValue?["sha256"] as? String, "\(name): the whole scan's sha256")
        SEMAssertParity(minima, try reference(ref, "pattern_min"), shape: navigation)
        SEMAssertParity(maxima, try reference(ref, "pattern_max"), shape: navigation)
        SEMAssertParity(means, try reference(ref, "pattern_mean"), shape: navigation)
        if ref.manifest.arrays["mean_pattern"] != nil {
            let count = Double(minima.count)
            SEMAssertParity(sum.map { $0 / count }, try reference(ref, "mean_pattern"), shape: signal)
        }
    }

    /// What a dataset carries beside its patterns, where the bundle holds it as an array: the projection centres in the Bruker
    /// convention and the static background (exact, its dtype too), and the map's first Euler angles (rtol 1e-7). A file without
    /// one matches a bundle that states none: no background where kikuchipy reads none, and no map where kikuchipy's is its
    /// placeholder of identity rotations (all Euler angles 0). A Bruker or EDAX file's map, which kikuchipy leaves as that
    /// placeholder, the reader reads as orix does (#514): only its size is held here.
    private func compareDataset(_ ref: SEMParityReference, _ dataset: EBSDDataset) throws {
        let name = ref.manifest.caseName
        if ref.manifest.arrays["pc"] != nil {
            let centers = dataset.detector.projectionCenters
            SEMAssertParity(centers.flatMap { [$0.x, $0.y, $0.z] }, try reference(ref, "pc"), shape: [centers.count, 3])
        }
        if let entry = ref.manifest.arrays["static_background"] {
            let background = try XCTUnwrap(dataset.staticBackground, "\(name): no static background read")
            XCTAssertEqual(background.dataType.rawValue, entry.dtype, "\(name): static background dtype")
            SEMAssertParity(background.doubles(), try reference(ref, "static_background"), shape: background.shape)
        } else {
            XCTAssertTrue(ref.values["static_background"] is NSNull, "\(name): the bundle states no static background")
            XCTAssertNil(dataset.staticBackground, "\(name): a static background where kikuchipy reads none")
        }
        let placeholder = try ref.manifest.arrays["xmap_euler_head"] != nil && ref.array("xmap_euler_head").values.allSatisfy { $0 == 0 }
        if let map = dataset.map, placeholder, [.brukerH5EBSD, .edaxH5EBSD].contains(dataset.format) {
            XCTAssertEqual(OrixView(map).size, dataset.scanRows * dataset.scanColumns, "\(name): the map beside the patterns")
        } else if let map = dataset.map {
            let head = try reference(ref, "xmap_euler_head")
            let n = head.shape.first ?? 0
            SEMAssertParity(OrixView(map).euler.prefix(n).flatMap { [$0.x, $0.y, $0.z] }, head, shape: [n, 3])
        } else if ref.manifest.arrays["xmap_euler_head"] != nil {
            XCTAssertTrue(try ref.array("xmap_euler_head").values.allSatisfy { $0 == 0 },
                          "\(name): kikuchipy's crystal map holds orientations the reader left out")
        }
    }

    /// kikuchipy h5ebsd, Bruker and EDAX h5ebsd, Oxford H5OINA and `.ebsp`, EDAX `.up1` and NORDIF, each through its reader.
    func testThePatternFilesReadAsKikuchipyReadsThem() throws {
        for name in Self.patternCases {
            let ref = try SEMParityReference.load(name)
            let dataset = try Self.dataset(try input(ref))
            let reader = try EBSDPatternReader(dataset)
            try comparePatterns(ref, scanRows: dataset.scanRows, scanColumns: dataset.scanColumns, patternRows: dataset.patternRows,
                                patternColumns: dataset.patternColumns, dataType: dataset.dataType,
                                row: { try reader.row($0) }, pattern: { try reader.pattern(row: $0, column: $1) })
            try compareDataset(ref, dataset)
        }
    }

    /// The same scans as one lazy signal: its slabs are the reader's patterns, its axes kikuchipy's (y, x in the scan unit with the
    /// steps; dy, dx in px). Red under: the signal read in file order, or a slab past the patterns it covers.
    func testThePatternFilesReadAsOneLazySignal() throws {
        for name in Self.patternCases {
            let ref = try SEMParityReference.load(name)
            let dataset = try Self.dataset(try input(ref))
            let signal = try dataset.signal()
            XCTAssertEqual(signal.array.shape, [dataset.scanRows, dataset.scanColumns, dataset.patternRows, dataset.patternColumns], name)
            XCTAssertEqual(signal.array.dataType, dataset.dataType, name)
            XCTAssertEqual(signal.signalType, "EBSD", name)
            XCTAssertEqual(signal.axes.map(\.name), ["y", "x", "dy", "dx"], name)
            XCTAssertEqual(signal.axes.map(\.scale), [dataset.stepY, dataset.stepX, 1, 1], name)
            XCTAssertEqual(signal.axes.map(\.navigate), [true, true, false, false], name)
            let whole = try signal.array.readAll()
            XCTAssertEqual(whole, try dataset.allPatterns(), "\(name): the whole scan")
            let patternsValue = ref.values["patterns"] as? [String: Any]
            XCTAssertEqual(EBSDFixtures.sha256(whole.bytes), patternsValue?["sha256"] as? String, "\(name): the whole scan's sha256")
            let reader = try EBSDPatternReader(dataset)
            let r = dataset.scanRows - 1, c = dataset.scanColumns - 1
            XCTAssertEqual(try signal.array.read(start: [r, c, 0, 0], count: [1, 1, dataset.patternRows, dataset.patternColumns]).bytes,
                           try reader.pattern(row: r, column: c).bytes, "\(name): the last pattern")
            let corner = try signal.array.read(start: [0, 0, 1, 2], count: [1, 1, 2, 3])
            XCTAssertEqual(corner, try reader.pattern(row: 0, column: 0).slab(start: [1, 2], count: [2, 3]), "\(name): a corner of a pattern")
        }
    }

    /// The hexagonal `.up2`: the reader hands kikuchipy's one row of ten uint16 patterns with kikuchipy's warning.
    func testTheHexagonalUp2ReadsAsKikuchipy() throws {
        let ref = try SEMParityReference.load(Self.hexagonalCase)
        let url = try input(ref)
        let file = try EDAXBinaryReader.read(url: url)
        XCTAssertTrue(file.isHexagonal)
        XCTAssertEqual(file.note, EDAXBinaryReader.hexagonalNote, "kikuchipy's warning")
        try comparePatterns(ref, scanRows: file.scanRows, scanColumns: file.scanColumns, patternRows: file.patternRows,
                            patternColumns: file.patternColumns, dataType: file.dataType,
                            row: { _ in try EDAXBinaryReader.allPatterns(file) },
                            pattern: { try EDAXBinaryReader.pattern(file, row: $0, column: $1) })
    }

    /// EMsoft's EBSD output (`EMData/EBSD/EBSDPatterns`) has no reader: the h5ebsd reader refuses it as a file that is not h5ebsd. The
    /// bundle stays the reference a port will be held to.
    func testTheEMsoftEBSDFileIsRefusedInWords() throws {
        let ref = try SEMParityReference.load("m1/read-emsoft-ebsd")
        let url = try input(ref)
        XCTAssertNil(EBSDH5Reader.content(url: url))
        XCTAssertThrowsError(try EBSDH5Reader.read(url: url)) { error in
            XCTAssertEqual(error as? EBSDReadError,
                           EBSDReadError(.notEBSD, "\(url.lastPathComponent): it is not an EBSD file (it does not name the software that wrote it)."))
        }
        XCTAssertEqual(ref.values["navigation_shape_rc"] as? [Int], [1])
        XCTAssertEqual(ref.values["signal_shape_rc"] as? [Int], [480, 640])
    }

    // MARK: - Orientation maps

    /// A map reader's columns against an orix bundle: size, shape, steps (as orix derives them), scan unit and property names exact,
    /// every phase's name, point group and space group, the phase ids and their counts exact, and the first 16 points' Euler angles,
    /// x, y and properties at rtol 1e-7. The phase colours are orix's defaults, which the consumer gives (the files name none).
    private func compareMap(_ ref: SEMParityReference, _ map: EBSDMapColumns) throws {
        let name = ref.manifest.caseName
        let orix = OrixView(map)
        XCTAssertEqual(orix.size, ref.values["size"] as? Int, "\(name): size")
        XCTAssertEqual(try orix.shape(), ref.values["shape"] as? [Int], "\(name): shape")
        XCTAssertEqual(orix.dx, ref.values["dx"] as? Double, "\(name): dx")
        XCTAssertEqual(orix.dy, ref.values["dy"] as? Double, "\(name): dy")
        XCTAssertEqual(map.scanUnit, ref.values["scan_unit"] as? String, "\(name): scan unit")
        let properties = try XCTUnwrap(ref.values["properties"] as? [String], "\(name): properties")
        XCTAssertEqual(map.propertyNames, properties, "\(name): property names")

        let phases = try XCTUnwrap(ref.values["phases"] as? [String: [String: Any]], "\(name): phases")
        XCTAssertEqual(Set(orix.phaseList.map { String($0) }), Set(phases.keys), "\(name): phase ids")
        for phase in orix.phases {
            let expected = phases[String(phase.id)]
            XCTAssertEqual(phase.name, expected?["name"] as? String, "\(name): phase \(phase.id) name")
            XCTAssertEqual(phase.pointGroup, expected?["point_group"] as? String, "\(name): phase \(phase.id) point group")
            XCTAssertEqual(phase.spaceGroup, expected?["space_group"] as? Int, "\(name): phase \(phase.id) space group")
            XCTAssertNil(phase.color, "\(name): phase \(phase.id) colour")
        }
        var counts: [String: Int] = [:]
        for id in orix.phaseIDs { counts[String(id), default: 0] += 1 }
        XCTAssertEqual(counts, ref.values["phase_counts"] as? [String: Int], "\(name): points per phase")
        SEMAssertParity(orix.phaseIDs.map { Double($0) }, try reference(ref, "phase_id"))

        let head = try reference(ref, "euler_head")
        let n = head.shape.first ?? 0
        SEMAssertParity(orix.euler.prefix(n).flatMap { [$0.x, $0.y, $0.z] }, head, shape: [n, 3])
        SEMAssertParity(Array(orix.x.prefix(n)), try reference(ref, "x_head"))
        SEMAssertParity(Array(orix.y.prefix(n)), try reference(ref, "y_head"))
        for property in properties {
            SEMAssertParity(Array((orix.property(property) ?? []).prefix(n)), try reference(ref, "prop_\(property)_head"))
        }
    }

    /// orix-data's two-phase EDAX `.ang` (the committed fixture, the bundle's downloaded input byte for byte) and the planted
    /// Oxford `.ctf` with its not-indexed point.
    func testTheOrientationMapsReadAsOrixReadsThem() throws {
        let ang = try SEMParityReference.load(Self.angCase)
        try compareMap(ang, try ANGReader.read(url: try input(ang)).map)
        let ctf = try SEMParityReference.load(Self.ctfCase)
        try compareMap(ctf, try CTFReader.read(path: try input(ctf).path).map)
    }

    // MARK: - Coverage

    /// Every bundle folder is compared with a Swift port by a test here, or allowlisted with the reason. Red under: a bundle folder
    /// nothing compares, an allowlisted one a test now compares, an allowlist entry without a folder or a reason.
    func testEveryBundleIsComparedOrAllowlisted() throws {
        let root = SEMParityReference.referencesRoot.appendingPathComponent("m1", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        let folders = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { "m1/" + $0.lastPathComponent }.sorted()
        XCTAssertEqual(folders.count, 11, "the reader bundles are on disk")
        XCTAssertEqual(try SEMParityReference.allCases(), folders, "one manifest a folder")
        for name in folders {
            if let reason = Self.allowlist[name] {
                XCTAssertFalse(Self.comparedHere.contains(name), "\(name) is compared now: take it off the allowlist")
                XCTAssertFalse(reason.isEmpty, "\(name): the allowlist says why")
            } else {
                XCTAssertTrue(Self.comparedHere.contains(name), "\(name): no test compares it and the allowlist does not name it")
            }
        }
        for name in Self.allowlist.keys.sorted() { XCTAssertTrue(folders.contains(name), "allowlisted \(name) has no folder") }
        for name in Self.comparedHere { XCTAssertTrue(folders.contains(name), "\(name) is compared here but has no folder") }
    }
}
