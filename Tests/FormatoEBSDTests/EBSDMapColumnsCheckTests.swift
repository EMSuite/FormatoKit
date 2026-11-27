//
//  EBSDMapColumnsCheckTests.swift
//  The map readers refuse the columns DiffractoKit's `CrystalMap` would refuse, where the file is read and with its name, as the
//  app's readers did when they built the map themselves (FormatoKit#147 review): a phase id column shorter than the angles, x or
//  y of another length or not finite, a property of another length, and coordinates that span more than 2^28 grid cells.
//

import Foundation
import XCTest
@testable import FormatoEBSD

nonisolated final class EBSDMapColumnsCheckTests: XCTestCase {

    private static let euler = [SIMD3<Double>](repeating: SIMD3(0, 0, 0), count: 4)

    private func refusal(_ columns: EBSDMapColumns, file: String? = "map.h5") -> EBSDReadError? {
        do { _ = try columns.checked(file: file); return nil } catch { return error as? EBSDReadError }
    }

    func testColumnsOfOneValueAPointOnAGridPass() throws {
        let columns = EBSDMapColumns(euler: Self.euler, phaseIDs: [0, 1, 1, -1], x: [0, 1, 0, 1], y: [0, 0, 1, 1],
                                     properties: ["iq": [1, 2, 3, 4]], isInData: [true, true, false, true])
        XCTAssertEqual(try columns.checked(file: "map.h5"), columns)
        XCTAssertEqual(try EBSDMapColumns(euler: Self.euler).checked(), EBSDMapColumns(euler: Self.euler), "no x or y: x = 0, 1, 2, 3")
    }

    func testAShortPhaseIDColumnIsRefusedWithTheFileName() {
        let error = refusal(EBSDMapColumns(euler: Self.euler, phaseIDs: [0, 1, 1]))
        XCTAssertEqual(error, EBSDReadError(.unreadable, "map.h5: its phase ids have another length than its 4 orientations."))
    }

    func testCoordinatesPropertiesAndMaskOfAnotherLengthAreRefused() {
        XCTAssertEqual(refusal(EBSDMapColumns(euler: Self.euler, x: [0, 1, 2]))?.reason, .unreadable)
        XCTAssertEqual(refusal(EBSDMapColumns(euler: Self.euler, y: [0, 1, 2, 3, 4]))?.reason, .unreadable)
        XCTAssertEqual(refusal(EBSDMapColumns(euler: Self.euler, properties: ["ci": [1]]), file: nil),
                       EBSDReadError(.unreadable, "its values of ci have another length than its 4 orientations."))
        XCTAssertEqual(refusal(EBSDMapColumns(euler: Self.euler, isInData: [true]))?.reason, .unreadable)
    }

    func testCoordinatesThatAreNotFiniteMakeNoGrid() {
        let error = refusal(EBSDMapColumns(euler: Self.euler, x: [0, .nan, 0, 1], y: [0, 0, 1, 1]))
        XCTAssertEqual(error, EBSDReadError(.unreadable, "map.h5: the crystal map's coordinates make no grid: x holds a value that is not a finite number."))
    }

    func testCoordinatesSpanningMoreThanTheCellCapAreRefused() {
        // Two points 2^29 steps apart along x: a 1 x (2^29 + 1) grid.
        let euler = [SIMD3<Double>](repeating: SIMD3(0, 0, 0), count: 3)
        let error = refusal(EBSDMapColumns(euler: euler, x: [0, 1, Double(1 << 29)]))
        XCTAssertEqual(error?.reason, .tooLarge)
        XCTAssertEqual(EBSDMapColumns.maximumCells, 1 << 28, "DiffractoKit's CrystalMap.maximumCells")
    }
}
