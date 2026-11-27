//
//  MapWriterTests.swift
//  The .ang and .ctf writers (FormatoKit#147) on plain columns: orix-data's two-phase duplex steel map (Fixtures/ebsd-sdss-ferrite-
//  austenite.ang, 100 x 117 points, as `ANGReader` reads it) laid out as an `EBSDMapGrid`, written, and read back by the kit's own
//  readers: the grid, steps, phases (name, point group, Laue group, lattice), phase ids and every Euler angle within the written
//  precision (.ang: five decimals of a radian, 5e-6, held at 2e-5; .ctf: four decimals of a degree, 8.7e-7 rad, held at 3e-6), the
//  image quality column of the .ang within its five decimals. The byte-for-byte parity with orix's `file_writer` (the app's bundles
//  `m8/write-ang-*`, `m8/write-ctf-*`) holds the chain from a `CrystalMap` and stays with the app that builds the grid from one.
//

import Foundation
import FormatoCore
import XCTest
@testable import FormatoEBSD

nonisolated final class MapWriterTests: XCTestCase {

    /// The duplex map as the writers take it: every point indexed and in data, the header's two phases with orix's names of their
    /// proper point group (432) and Laue group (m-3m).
    private static func duplex() throws -> (map: EBSDMapColumns, grid: EBSDMapGrid) {
        let map = try ANGReader.read(url: EBSDFixtures.url("ebsd-sdss-ferrite-austenite.ang")).map
        let orix = OrixView(map)
        let shape = try orix.shape()
        XCTAssertEqual(shape, [100, 117])
        let ids = try XCTUnwrap(map.phaseIDs)
        let phases = map.phaseHeaders.map {
            EBSDMapGrid.Phase(id: $0.id, name: $0.name, spaceGroup: $0.spaceGroup, lattice: $0.lattice, properPointGroup: "432", laueGroup: "m-3m")
        }
        let grid = try EBSDMapGrid(rows: shape[0], columns: shape[1], dx: orix.dx, dy: orix.dy, mapDY: orix.dy,
                                   indexed: ids.map { $0 != -1 }, euler: map.euler, phaseIDs: ids.map { Double($0) },
                                   properties: map.properties, phases: phases)
        return (map, grid)
    }

    private func scratch(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("map-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent(name)
    }

    private func assertClose(_ ours: [Double], _ theirs: [Double], _ bound: Double, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ours.count, theirs.count, "\(what): count", file: file, line: line)
        let worst = zip(ours, theirs).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, bound, what, file: file, line: line)
    }

    func testAnAngWrittenFromTheColumnsReadsBackAsTheMap() throws {
        let (map, grid) = try Self.duplex()
        let url = try scratch("duplex.ang")
        try ANGWriter.write(grid, to: url, options: ANGWriter.Options(operatorName: "test"))
        let back = try ANGReader.read(url: url)
        XCTAssertEqual(back.vendor, .orix, "orix's column-names line")
        XCTAssertEqual(back.header.grid, "SqrGrid")
        XCTAssertEqual(back.header.stepX, 1.5)
        XCTAssertEqual(back.header.stepY, 1.5)
        XCTAssertEqual([back.header.rows, back.header.columnsOdd, back.header.columnsEven], [100, 117, 117])
        XCTAssertTrue(back.header.lines.contains("# OPERATOR: test"))
        XCTAssertEqual(back.pointCount, map.pointCount)
        XCTAssertEqual(back.map.phaseIDs, map.phaseIDs)
        XCTAssertEqual(back.map.phaseHeaders.map(\.id), [1, 2])
        XCTAssertEqual(back.map.phaseHeaders.map(\.name), map.phaseHeaders.map(\.name))
        XCTAssertEqual(back.map.phaseHeaders.map(\.pointGroup), ["432", "432"], "EDAX's alias 43 read back as 432")
        for (ours, theirs) in zip(back.map.phaseHeaders, map.phaseHeaders) {
            assertClose(ours.lattice ?? [], theirs.lattice ?? [], 5e-4, "lattice of \(theirs.name), three decimals")
        }
        for k in 0..<3 { assertClose(back.map.euler.map { $0[k] }, map.euler.map { $0[k] }, 2e-5, "Euler \(k + 1)") }
        assertClose(back.map.x ?? [], grid.x, 1e-9, "x")
        assertClose(back.map.y ?? [], grid.y, 1e-9, "y")
        assertClose(back.map.properties["iq"] ?? [], map.properties["iq"] ?? [], 1e-4, "image quality")
        XCTAssertEqual(try OrixView(back.map).shape(), [100, 117])
    }

    func testACtfWrittenFromTheColumnsReadsBackAsTheMap() throws {
        let (map, grid) = try Self.duplex()
        let url = try scratch("duplex.ctf")
        try CTFWriter.write(grid, to: url)
        let back = try CTFReader.read(path: url.path)
        XCTAssertEqual(back.vendor, .oxfordOrBruker)
        XCTAssertEqual(back.header.first, "Channel Text File")
        XCTAssertTrue(back.header.contains("Prj\tduplex"), "the project is the file's name")
        XCTAssertTrue(back.header.contains("Author\tFormatoKit"))
        XCTAssertEqual(back.pointCount, map.pointCount)
        XCTAssertEqual(back.map.phaseIDs, map.phaseIDs)
        XCTAssertEqual(back.map.phaseHeaders.map(\.name), map.phaseHeaders.map(\.name))
        XCTAssertEqual(back.map.phaseHeaders.map(\.pointGroup), ["m-3m", "m-3m"], "Laue group 11")
        XCTAssertEqual(back.map.phaseHeaders.map(\.spaceGroup), [nil, nil], "space group 0: none")
        for k in 0..<3 { assertClose(back.map.euler.map { $0[k] }, map.euler.map { $0[k] }, 3e-6, "Euler \(k + 1)") }
        assertClose(back.map.x ?? [], grid.x, 1e-9, "x")
        assertClose(back.map.y ?? [], grid.y, 1e-9, "y")
        XCTAssertEqual(back.map.properties["error"], [Double](repeating: 0, count: map.pointCount), "every point indexed: Error 0")
        let orix = OrixView(back.map)
        XCTAssertEqual(try orix.shape(), [100, 117])
        XCTAssertEqual([orix.dy, orix.dx], [1.5, 1.5])
    }

    /// A point not indexed is written as each format writes none: .ang Euler 4π, CI −1 and phase −1 on a one-phase map, read back as
    /// not indexed; .ctf phase 0, Euler 0 and Error 3, read back as phase −1.
    func testAPointNotIndexedIsWrittenAsTheFormatsNone() throws {
        let grid = try EBSDMapGrid(rows: 1, columns: 2, dx: 1, dy: 1, mapDY: 0, indexed: [true, false],
                                   euler: [SIMD3(0.1, 0.2, 0.3), .zero], phaseIDs: [1, -1], properties: ["iq": [5, 0]],
                                   phases: [EBSDMapGrid.Phase(id: 1, name: "Ni", spaceGroup: 225, lattice: [3.52, 3.52, 3.52, 90, 90, 90],
                                                              properPointGroup: "432", laueGroup: "m-3m")])
        let ang = try ANGReader.read(text: try ANGWriter.text(of: grid), url: URL(fileURLWithPath: "/tmp/one.ang"))
        XCTAssertEqual(ang.map.phaseIDs, [1, -1])
        XCTAssertEqual(ang.map.euler[1], SIMD3(repeating: (4 * Double.pi * 100_000).rounded() / 100_000))
        XCTAssertEqual(ang.map.properties["ci"], [0, -1])
        let ctf = try CTFReader.read(text: try CTFWriter.text(of: grid))
        XCTAssertEqual(ctf.map.phaseIDs, [1, -1])
        XCTAssertEqual(ctf.map.euler[1], .zero)
        XCTAssertEqual(ctf.map.properties["error"], [0, 3])
        XCTAssertEqual(ctf.map.phaseHeaders.map(\.spaceGroup), [225])
    }

    /// A grid whose per-cell arrays are not one value a cell, or that has no cell, is refused before anything is written.
    func testAGridOfTheWrongLengthIsRefused() {
        XCTAssertThrowsError(try EBSDMapGrid(rows: 0, columns: 3, dx: 1, dy: 1, mapDY: 1, indexed: [], euler: [], phaseIDs: [], phases: [])) { error in
            XCTAssertEqual(error as? EBSDMapGrid.Refusal, .noGrid)
        }
        XCTAssertThrowsError(try EBSDMapGrid(rows: 1, columns: 2, dx: 1, dy: 1, mapDY: 1, indexed: [true, true], euler: [.zero, .zero],
                                             phaseIDs: [1], phases: [])) { error in
            XCTAssertEqual(error as? EBSDMapGrid.Refusal, .length("phase ids"))
        }
        XCTAssertThrowsError(try EBSDMapGrid(rows: 1, columns: 2, dx: 1, dy: 1, mapDY: 1, indexed: [true, true], euler: [.zero, .zero],
                                             phaseIDs: [1, 1], properties: ["iq": [1]], phases: [])) { error in
            XCTAssertEqual(error as? EBSDMapGrid.Refusal, .length("property iq"))
        }
    }

    /// The acquisition a header states: integers without decimals, else six significant digits, 0 for none.
    func testHeaderNumbersAreWrittenAsTheWritersWriteThem() {
        XCTAssertEqual(EBSDMapAcquisition.headerNumber(nil), "0")
        XCTAssertEqual(EBSDMapAcquisition.headerNumber(.nan), "0")
        XCTAssertEqual(EBSDMapAcquisition.headerNumber(20), "20")
        XCTAssertEqual(EBSDMapAcquisition.headerNumber(24.7), "24.7")
        XCTAssertEqual(EBSDMapAcquisition.headerNumber(1.0 / 3.0), "0.333333")
    }
}
