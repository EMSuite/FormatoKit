//
//  EBSDH5OxfordMapTests.swift
//  Moved from Electron Microscopy Studio's EMStudioTests (at 67d6df4) by FormatoKit#147, with its fixtures unchanged; the app's
//  routing and Maps room checks stay in the app.
//  An Oxford .h5oina that holds an orientation map but no patterns (AZtec's map export, #513) reads as a map. The planted fixtures
//  (tools/ebsd-readers/make_h5oina_map_fixtures.py; every value exact in float32) read exactly as the H5OINA specification lays the map
//  out: Euler angles in radians as stored, phase 0 not indexed, the phases of `Header/Phases` with Oxford's Laue group ids, lattice
//  angles in degrees (90° and 120° exact), the `.ctf`'s column names with MAD in degrees and the `.ctf`'s error codes, the header's
//  cells and steps in µm. The same points stored in another order with their X and Y, or without X and Y, read the same map
//  (DREAM3D's EbsdLib, MTEX). A file with no Euler angles is refused with its reason.
//

import Foundation
import XCTest
@testable import FormatoEBSD

nonisolated final class EBSDH5OxfordMapTests: XCTestCase {

    private static func fixture(_ name: String) -> URL { EBSDFixtures.url(name + ".h5oina") }
    private static let map = fixture("ebsd-oxford-map")

    /// The planted map, row by row (4 columns, 3 rows): its phases with 0 not indexed, Euler angles, and columns.
    private static let phases = [1, 1, 2, 2, 1, 0, 2, 2, 1, 1, 1, 2]
    private static func euler(_ i: Int) -> SIMD3<Double> {
        phases[i] == 0 ? .zero : SIMD3(0.5 + 0.125 * Double(i), 0.25 + 0.0625 * Double(i), 1.0 + 0.03125 * Double(i))
    }

    // MARK: - The map

    /// Every number of the planted map, exact: points, phases, orientations, coordinates on the header's grid, the five columns, the
    /// phase list. Red under: degrees taken for radians, phase 0 kept as a phase, MAD left in radians, H5OINA's error codes kept (Success 1
    /// reads Low BC in a `.ctf`), the columns misnamed, the grid transposed, a lattice angle of 90.0000025°.
    func testAMapOnlyH5OINAReadsAsTheSpecificationLaysItOut() throws {
        let map = try EBSDH5Reader.readOxfordMap(url: Self.map)
        let orix = OrixView(map)
        XCTAssertEqual(map.pointCount, 12)
        XCTAssertEqual(map.phaseIDs, Self.phases.map { $0 == 0 ? -1 : $0 })
        XCTAssertEqual(orix.euler, (0..<12).map(Self.euler))
        XCTAssertEqual(map.x, (0..<12).map { Double($0 % 4) * 0.5 })
        XCTAssertEqual(map.y, (0..<12).map { Double($0 / 4) * 0.25 })
        XCTAssertEqual([orix.dx, orix.dy], [0.5, 0.25])
        XCTAssertEqual(map.scanUnit, "um")
        XCTAssertEqual(map.propertyNames, ["BC", "BS", "MAD", "bands", "error"])
        XCTAssertEqual(map.properties["MAD"], (0..<12).map { 0.0078125 * Double($0 + 1) * 180 / Double.pi })
        XCTAssertEqual(map.properties["BC"], (0..<12).map { Double(100 + $0) })
        XCTAssertEqual(map.properties["BS"], (0..<12).map { Double(50 + $0) })
        XCTAssertEqual(map.properties["bands"], (0..<12).map { Double(8 + $0 % 4) })
        XCTAssertEqual(map.properties["error"], Self.phases.map { $0 == 0 ? 3.0 : 0.0 }, "the .ctf's codes: Success 0, No solution 3")

        XCTAssertEqual(orix.phaseList, [-1, 1, 2])
        XCTAssertEqual(try XCTUnwrap(orix.phase(id: 1)),
                       EBSDPhaseHeader(id: 1, name: "Aluminium", spaceGroup: 225, pointGroup: "m-3m",
                                       lattice: [Double(Float(4.05)), Double(Float(4.05)), Double(Float(4.05)), 90, 90, 90]))
        XCTAssertEqual(try XCTUnwrap(orix.phase(id: 2)),
                       EBSDPhaseHeader(id: 2, name: "Magnesium", spaceGroup: 194, pointGroup: "6/mmm",
                                       lattice: [Double(Float(3.21)), Double(Float(3.21)), Double(Float(5.21)), 90, 90, 120]))
    }

    /// Every H5OINA error code has the `.ctf` code of the same outcome; Replaced, which the `.ctf` has none for, stays 7.
    func testTheErrorCodesAreTheCTFsCodesForTheSameOutcome() {
        let ctf = ["Success": 0.0, "Low BC": 1, "Low BS": 2, "No solution": 3, "High MAD": 4, "Not yet analysed": 5, "Unexpected error": 6]
        let h5oina = ["Not yet analysed": 0.0, "Success": 1, "No solution": 2, "Low BC": 3, "Low BS": 4, "High MAD": 5, "Unexpected error": 6]
        for (outcome, code) in h5oina { XCTAssertEqual(EBSDH5Reader.oxfordCTFErrorCodes[code], ctf[outcome], outcome) }
        XCTAssertNil(EBSDH5Reader.oxfordCTFErrorCodes[7])
    }

    /// The same points stored in another order, each with its X and Y, read the same map, as EbsdLib places them; without X and Y the
    /// header's grid places them row by row, as MTEX does. Red under: X and Y ignored, or a map that needs them.
    func testTheSameMapStoredInAnotherOrderOrWithoutPositionsReadsTheSame() throws {
        let map = try EBSDH5Reader.readOxfordMap(url: Self.map)
        XCTAssertEqual(try EBSDH5Reader.readOxfordMap(url: Self.fixture("ebsd-oxford-map-shuffled")), map)
        XCTAssertEqual(try EBSDH5Reader.readOxfordMap(url: Self.fixture("ebsd-oxford-map-grid")), map)
    }

    /// Positions that fill the grid once give each point its cell; the stored order already, two points on one cell, a point off the
    /// grid or one not finite give none (the stored order stands). A line scan needs no y step.
    func testThePositionsPlaceEachPointOnceOrNotAtAll() {
        let x = [0.5, 0.0, 0.5, 0.0], y = [0.0, 0.0, 0.25, 0.25]
        XCTAssertEqual(EBSDH5Reader.oxfordGridOrder(x: x, y: y, columns: 2, rows: 2, dx: 0.5, dy: 0.25), [1, 0, 3, 2])
        XCTAssertEqual(EBSDH5Reader.oxfordGridOrder(x: x.map { $0 + 10.000_01 }, y: y.map { $0 - 3 }, columns: 2, rows: 2, dx: 0.5, dy: 0.25),
                       [1, 0, 3, 2], "counted from the smallest x and y, to the nearest cell")
        XCTAssertNil(EBSDH5Reader.oxfordGridOrder(x: [0, 0.5, 0, 0.5], y: [0, 0, 0.25, 0.25], columns: 2, rows: 2, dx: 0.5, dy: 0.25))
        XCTAssertNil(EBSDH5Reader.oxfordGridOrder(x: [0, 0.5, 0.5, 0.5], y: [0, 0, 0.25, 0.25], columns: 2, rows: 2, dx: 0.5, dy: 0.25))
        XCTAssertNil(EBSDH5Reader.oxfordGridOrder(x: [0, 1.5, 0, 0.5], y: [0, 0, 0.25, 0.25], columns: 2, rows: 2, dx: 0.5, dy: 0.25))
        XCTAssertNil(EBSDH5Reader.oxfordGridOrder(x: [0, .nan, 0, 0.5], y: [0, 0, 0.25, 0.25], columns: 2, rows: 2, dx: 0.5, dy: 0.25))
        XCTAssertNil(EBSDH5Reader.oxfordGridOrder(x: x, y: y, columns: 2, rows: 2, dx: 0, dy: 0.25))
        XCTAssertNil(EBSDH5Reader.oxfordGridOrder(x: x, y: y, columns: 3, rows: 2, dx: 0.5, dy: 0.25))
        XCTAssertEqual(EBSDH5Reader.oxfordGridOrder(x: [1, 0, 0.5], y: [0, 0, 0], columns: 3, rows: 1, dx: 0.5, dy: 0), [2, 0, 1])
    }

    // MARK: - What the files hold

    /// A map-only H5OINA is a map, the pattern files hold patterns, and the pattern reader refuses the map with its reason instead
    /// of the 'Pattern Height' the map lacks; a file without Euler angles is refused with the dataset it lacks.
    func testAMapOnlyH5OINAIsAMapAndThePatternFilesAreNot() throws {
        for name in ["ebsd-oxford-map", "ebsd-oxford-map-shuffled", "ebsd-oxford-map-grid", "ebsd-oxford-map-no-euler"] {
            let url = Self.fixture(name)
            XCTAssertEqual(EBSDH5Reader.sniff(url: url), .oxfordH5OINA, name)
            XCTAssertEqual(EBSDH5Reader.content(url: url), .map(.oxford), name)
        }
        for name in ["ebsd-oxford", "ebsd-oxford-6"] {
            XCTAssertEqual(EBSDH5Reader.content(url: Self.fixture(name)), .patterns(.oxfordH5OINA), name)
        }
        XCTAssertThrowsError(try EBSDH5Reader.read(url: Self.map)) { error in
            XCTAssertEqual(error as? EBSDReadError,
                           EBSDReadError(.holdsMapOnly, "ebsd-oxford-map.h5oina holds an orientation map but no EBSD patterns."))
        }
        let found = try EBSDH5Reader.readMap(url: Self.map)
        XCTAssertEqual(found.layout, .oxford)
        XCTAssertEqual(found.map, try EBSDH5Reader.readOxfordMap(url: Self.map))
        XCTAssertThrowsError(try EBSDH5Reader.readMap(url: Self.fixture("ebsd-oxford-map-no-euler"))) { error in
            XCTAssertEqual(error as? EBSDReadError,
                           EBSDReadError(.missing("Euler"), "ebsd-oxford-map-no-euler.h5oina holds neither EBSD patterns nor orientations: "
                                         + "its EBSD data has no Euler angles."))
        }
    }
}
