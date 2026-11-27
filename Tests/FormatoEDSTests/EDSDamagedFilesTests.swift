//
//  EDSDamagedFilesTests.swift
//  A damaged EDS file is refused in words, never a crash (the consumer's macEM 2.1.0 bundle B, #606 damaged EDS files): one test
//  per site the audit named.
//  Red before (in the app): a spectrum image's channel past its last indexed out of range when summed; a pixel table that ran
//  backwards, or more pixels than the header, trapped in `precondition`; an SFS stream offset behind what was read gave a negative
//  index; a JEOL magnification of 0 gave an infinite scale.
//  Moved from Electron Microscopy Studio's EMStudioTests/SEMDamagedFilesTests.swift (its #606 part, at f1eaafc) by
//  FormatoKit#148; the EBSD part (#607) stays with the app's EBSD processing.
//

import Foundation
import FormatoCore
import FormatoEDS
import XCTest

nonisolated final class EDSDamagedFilesTests: XCTestCase {

    func testASpectrumImageWithACountPastItsLastChannelIsRefused() {
        XCTAssertThrowsError(try EDSSparseSpectrumImage(ny: 1, nx: 2, channels: 4, rowOffsets: [0, 1, 2], channelIndex: [0, 4], counts: [1, 1])) {
            XCTAssertTrue(($0 as? EDSReadError)?.text.contains("channel 4") ?? false, "\($0)")
            XCTAssertEqual(($0 as? EDSReadError)?.reason, .damaged)
        }
        var builder = try? EDSSparseSpectrumImageBuilder(ny: 1, nx: 1, channels: 4)
        builder?.append(channels: [UInt16(9)], counts: [UInt32(2)])
        XCTAssertThrowsError(try builder?.finish())
    }

    func testASpectrumImageWhosePixelTableDoesNotDescribeItsCountsIsRefused() {
        // Backwards offsets.
        XCTAssertThrowsError(try EDSSparseSpectrumImage(ny: 1, nx: 2, channels: 4, rowOffsets: [0, 2, 1], channelIndex: [0], counts: [1]))
        // Too few offsets for the pixels.
        XCTAssertThrowsError(try EDSSparseSpectrumImage(ny: 2, nx: 2, channels: 4, rowOffsets: [0, 1], channelIndex: [0], counts: [1]))
        // The last offset is not the number of counts.
        XCTAssertThrowsError(try EDSSparseSpectrumImage(ny: 1, nx: 1, channels: 4, rowOffsets: [0, 3], channelIndex: [0], counts: [1]))
        // An overflowing pixel count.
        XCTAssertThrowsError(try EDSSparseSpectrumImage(ny: Int.max, nx: 2, channels: 4, rowOffsets: [0], channelIndex: [], counts: []))
        // More pixels appended than the image holds.
        var builder = try? EDSSparseSpectrumImageBuilder(ny: 1, nx: 1, channels: 4)
        builder?.append(channels: [UInt16(1)], counts: [UInt32(2)])
        builder?.append(channels: [UInt16(1)], counts: [UInt32(2)])
        XCTAssertThrowsError(try builder?.finish()) {
            XCTAssertTrue(($0 as? EDSReadError)?.text.contains("more than its 1 x 1") ?? false, "\($0)")
        }
    }

    func testAnSFSStreamOffsetBehindWhatWasReadIsRefused() throws {
        var blocks = [[UInt8](repeating: 1, count: 16)]
        var stream = EDSByteStream(name: "damaged.bcf") { blocks.isEmpty ? nil : blocks.removeFirst() }
        try stream.skip(8)
        XCTAssertThrowsError(try stream.seek(2)) { XCTAssertTrue("\($0)".contains("damaged.bcf"), "\($0)") }
        XCTAssertThrowsError(try stream.skip(-1))
        XCTAssertThrowsError(try stream.seek(Int.min))
        try stream.seek(12)
        XCTAssertEqual(try stream.take(4).count, 4)
    }

    func testAJEOLMagnificationOfZeroNegativeOrNaNIsRefusedNamingTheFile() throws {
        for mag in [0, -100, Double.nan] {
            XCTAssertThrowsError(try JEOLEDSReader.fieldWidth(scanSize: 125, magnification: mag, file: "map.pts")) {
                XCTAssertTrue(($0 as? EDSReadError)?.text.hasPrefix("map.pts") ?? false, "\($0)")
                XCTAssertEqual(($0 as? EDSReadError)?.reason, .number)
            }
        }
        XCTAssertEqual(try JEOLEDSReader.fieldWidth(scanSize: 125, magnification: 1000, file: "map.pts"), 125, accuracy: 1e-12)
    }
}
