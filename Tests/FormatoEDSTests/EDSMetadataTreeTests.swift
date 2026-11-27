//
//  EDSMetadataTreeTests.swift
//  The metadata the EDS readers write is a tree FormatoHSPY can write (no key both a value and a group of others, FormatoKit#183
//  review): the mode is the name of the one group under `Acquisition_instrument`, as in RosettaSciIO's tree, and names itself
//  only where no instrument field is known. `EDSMetadata(_:)` reads every field back. A sparse store whose pixel lists a channel
//  out of order or twice is refused, so its dense slabs and its sums agree.
//

import Foundation
import FormatoCore
import XCTest
@testable import FormatoEDS

nonisolated final class EDSMetadataTreeTests: XCTestCase {

    private func tree(_ fields: EDSMetadata) -> FormatoMetadata {
        fields.metadata(file: "map.bcf", source: "the Esprit XML header", rule: "test")
    }

    private func assertNoKeyIsAGroup(_ metadata: FormatoMetadata, file: StaticString = #filePath, line: UInt = #line) {
        let keys = metadata.keys
        for key in keys {
            XCTAssertFalse(keys.contains { $0.hasPrefix(key + ".") }, "\(key) is a value and a group", file: file, line: line)
        }
    }

    func testTheModeIsTheGroupOfTheInstrumentFields() {
        var fields = EDSMetadata()
        fields.mode = "SEM"; fields.beamEnergy = 15; fields.liveTime = 2.5; fields.elements = ["Fe", "Ni"]
        let metadata = tree(fields)
        assertNoKeyIsAGroup(metadata)
        XCTAssertNil(metadata[EDSMetadata.modeKey], "the mode is the group's name, as RosettaSciIO's tree has it")
        XCTAssertEqual(metadata["Acquisition_instrument.SEM.beam_energy"]?.value.number, 15)
        XCTAssertEqual(EDSMetadata(metadata), fields)
    }

    func testAModeWithoutFieldsNamesItself() {
        var fields = EDSMetadata()
        fields.mode = "TEM"; fields.title = "EDS"
        let metadata = tree(fields)
        assertNoKeyIsAGroup(metadata)
        XCTAssertEqual(metadata[EDSMetadata.modeKey]?.value.text, "TEM")
        XCTAssertEqual(EDSMetadata(metadata), fields)
    }

    func testAPixelListingAChannelOutOfOrderOrTwiceIsRefused() {
        XCTAssertNoThrow(try EDSSparseSpectrumImage(ny: 1, nx: 2, channels: 4, rowOffsets: [0, 2, 3], channelIndex: [1, 3, 0], counts: [1, 2, 3]))
        for channels: [UInt16] in [[3, 1, 0], [1, 1, 0]] {
            XCTAssertThrowsError(try EDSSparseSpectrumImage(ny: 1, nx: 2, channels: 4, rowOffsets: [0, 2, 3], channelIndex: channels,
                                                            counts: [1, 2, 3])) { error in
                XCTAssertEqual((error as? EDSReadError)?.reason, .damaged)
            }
        }
    }
}
