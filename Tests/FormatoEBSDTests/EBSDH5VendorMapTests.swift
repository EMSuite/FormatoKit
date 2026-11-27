//
//  EBSDH5VendorMapTests.swift
//  Moved from Electron Microscopy Studio's EMStudioTests (at 67d6df4) by FormatoKit#147, with its fixtures and truth unchanged; the
//  app's Maps room checks stay in the app.
//  The EBSD maps of h5ebsd files saved without patterns (#514), read as their references read them:
//  - Bruker Esprit, as orix 0.15.0's bruker_h5ebsd.py reads it: the points put back in map order by the SEM IY and IX, X SAMPLE
//    reversed as orix reverses it, Phase 0 not indexed, the phases by IT, the thirteen columns orix keeps.
//  - EDAX OIM Analysis, as orix 0.15.0 reads the .ang OIM writes for the same scan (no Python reader reads the .h5 map).
//  - EMsoft's dictionary indexing file, as orix 0.15.0's emsoft_h5ebsd.py reads it: the best match of each point from the dictionary,
//    y from the rows and Step Y, the properties' first column.
//  Truth: Fixtures/ebsd-h5ebsd-map.truth.json (tools/ebsd-readers/make_h5ebsd_map_fixtures.py). The phase colours are the consumer's
//  (DiffractoKit gives each Bruker phase its own Tableau colour, where orix leaves them all tab:blue): the headers here name none.
//

import Foundation
import FormatoCore
import XCTest
@testable import FormatoEBSD

nonisolated final class EBSDH5VendorMapTests: XCTestCase {

    private static func fixture(_ name: String) -> URL { EBSDFixtures.url(name) }

    private struct Truth: Decodable {
        struct Phase: Decodable { var id: Int; var name: String; var spaceGroup: Int?; var pointGroup: String?; var color: String; var lattice: [String] }
        struct File: Decodable {
            var reference: String; var size: Int; var shape: [Int]; var rotationsPerPoint: Int
            var phaseIDs: [Int]; var x: [String]; var y: [String]; var euler: [String]
            var properties: [String: [String]]; var scanUnit: String; var dx: String; var dy: String; var phases: [Phase]
        }
        var orix: String
        var files: [String: File]
    }

    private static func numbers(_ values: [String]) -> [Double] { values.map { Double($0) ?? .nan } }

    private static let layouts: [String: EBSDH5Reader.MapLayout] = [
        "ebsd-bruker-map.h5": .bruker, "ebsd-edax-map.h5": .edax, "ebsd-emsoft-map.h5": .emsoft,
    ]

    /// Each map reads as its reference reads it, exactly: phases of the points, x and y, the Euler angles orix builds its rotations
    /// from, every property orix keeps, the phases (lattice to the float64 rounding of diffpy's recomputed cell) and the unit.
    /// Red under: the Bruker points left in the order stored (the phases of row 1 shuffled), X SAMPLE not reversed, the degrees taken as
    /// radians or converted in float64 (one ulp off orix), Phase 0 kept as a phase; the EDAX ci -1 points kept indexed, its names not
    /// taken from the formulas; EMsoft's second match shown, its Y Position used, the match index taken as 0-based.
    func testEachMapReadsAsItsReferenceReadsIt() throws {
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: Self.fixture("ebsd-h5ebsd-map.truth.json")))
        XCTAssertEqual(truth.orix, "0.15.0")
        XCTAssertEqual(Set(truth.files.keys), Set(Self.layouts.keys))
        for (name, expected) in truth.files.sorted(by: { $0.key < $1.key }) {
            let layout = try XCTUnwrap(Self.layouts[name])
            XCTAssertEqual(EBSDH5Reader.content(url: Self.fixture(name)), .map(layout), name)
            let found = try EBSDH5Reader.readMap(url: Self.fixture(name))
            XCTAssertEqual(found.layout, layout, name)
            let map = found.map
            let orix = OrixView(map)
            XCTAssertEqual(orix.size, expected.size, name)
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
                XCTAssertNil(read.color, "\(name) phase \(phase.id): the file names no colour")
                XCTAssertEqual(read.spaceGroup, phase.spaceGroup, "\(name) phase \(phase.id)")
                XCTAssertEqual(read.pointGroup, phase.pointGroup, "\(name) phase \(phase.id)")
                let lattice = try XCTUnwrap(read.lattice, "\(name) phase \(phase.id)")
                XCTAssertEqual(lattice.count, 6)
                for (got, want) in zip(lattice, Self.numbers(phase.lattice)) { XCTAssertEqual(got, want, accuracy: 1e-12 * max(1, abs(want))) }
            }
        }
    }

    /// The Bruker phases in id order, with no colour of their own: the consumer gives each the next free Tableau colour.
    func testBrukerPhasesComeInIdOrderWithoutColours() throws {
        let map = try EBSDH5Reader.readVendorMap(url: Self.fixture("ebsd-bruker-map.h5"), layout: .bruker)
        XCTAssertEqual(OrixView(map).phaseList, [-1, 1, 2])
        XCTAssertEqual(map.phaseHeaders.map(\.id), [1, 2])
        XCTAssertEqual(map.phaseHeaders.map(\.color), [nil, nil])
        XCTAssertEqual(map.phaseHeaders.map(\.latticeUnit), [EBSDPhaseHeader.angstrom, EBSDPhaseHeader.angstrom])
    }

    /// The EDAX .h5 map and the .ang of the same scan are one map, phase list and all.
    func testTheEDAXMapIsItsAngMap() throws {
        let h5 = try EBSDH5Reader.readVendorMap(url: Self.fixture("ebsd-edax-map.h5"), layout: .edax)
        let ang = try ANGReader.read(url: Self.fixture("ebsd-edax-map.ang")).map
        XCTAssertEqual(h5.euler, ang.euler)
        XCTAssertEqual(h5.phaseIDs, ang.phaseIDs)
        XCTAssertEqual(h5.x, ang.x)
        XCTAssertEqual(h5.y, ang.y)
        XCTAssertEqual(h5.scanUnit, ang.scanUnit)
        XCTAssertEqual(h5.phaseHeaders, ang.phaseHeaders)
        for (key, values) in h5.properties { XCTAssertEqual(values, ang.properties[key], key) }
    }

    /// A file saved without patterns has the map its patterned twin carries beside its patterns (the kikuchipy-made EDAX file); a
    /// Bruker file whose points all sit at one X and Y SAMPLE (kikuchipy's) lays out no map and is refused in words.
    func testFilesSavedWithoutPatternsReadTheMapTheirPatternedTwinCarries() throws {
        let edax = try EBSDH5Reader.readMap(url: Self.fixture("ebsd-edax-nopatterns-h5ebsd.h5"))
        XCTAssertEqual(edax.layout, .edax)
        XCTAssertEqual(edax.map, try XCTUnwrap(EBSDH5Reader.read(url: Self.fixture("ebsd-edax-h5ebsd.h5")).map))
        XCTAssertEqual(try OrixView(edax.map).shape(), [3, 3])

        XCTAssertThrowsError(try EBSDH5Reader.readMap(url: Self.fixture("ebsd-bruker-nopatterns-h5ebsd.h5"))) { error in
            XCTAssertEqual((error as? EBSDReadError)?.text,
                           "ebsd-bruker-nopatterns-h5ebsd.h5: the positions of its 9 points do not lay them out on a map (they span 1 grid cell).")
        }
    }

    /// orix's regular expressions for EMsoft's phase: the first `[A-z0-9]` run of the name, the bracketed point group (the class holds
    /// `]` itself, so the match backs off to the last `]`).
    func testEMsoftPhaseTextsReadAsOrixsRegularExpressions() {
        XCTAssertEqual(EBSDH5Reader.firstRun(in: "fe4al13/fe4al13", allowed: { ($0 >= 65 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }), "fe4al13")
        XCTAssertEqual(EBSDH5Reader.bracketedPointGroup("Monoclinic b (C2h) [2/m]"), "2/m")
        XCTAssertEqual(EBSDH5Reader.bracketedPointGroup("Cubic (Oh) [m3m]"), "m3m")
        XCTAssertEqual(EBSDH5Reader.bracketedPointGroup("Hexagonal [6/mmm] x"), "6/mmm")
        XCTAssertNil(EBSDH5Reader.bracketedPointGroup("Cubic []"))
        XCTAssertNil(EBSDH5Reader.bracketedPointGroup("Cubic"))
    }
}
