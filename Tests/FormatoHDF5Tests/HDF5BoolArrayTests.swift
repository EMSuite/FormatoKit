//
//  HDF5BoolArrayTests.swift
//  `HDF5WriteSession.writeBools` (FormatoKit#170): a one-dimensional dataset of h5py's bool type, the type of orix's and kikuchipy's
//  `crystal_map/data/is_in_data`, read back exactly by `HDF5Reader.readBooleans` with the shape it was written with; an empty array,
//  `replace` and a missing parent group behave as `writeDataset`'s. The type is the one `writeBool` writes (pinned to h5py 3.16.0 by
//  `HDF5BoolAttributeTests` for the attribute), so `datasetInfo` names it an enum, as the scalar's. Red before: there was no call.
//

import Foundation
import Testing
import FormatoCore
import FormatoHDF5

@Suite(.serialized) struct HDF5BoolArrayTests {
    @Test func aBoolArrayReadsBackExactly() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("bools.h5")
        let values = [true, false, true, true, false, false, true]
        try HDF5NewFile.write(to: out) { session in
            try session.writeBools("/crystal_map/data/is_in_data", values)
            try session.writeBools("/g/empty", [])
            try session.writeBool("/g/scalar", true)
            #expect(throws: HDF5FileError.self) { try session.writeBools("/crystal_map/data/is_in_data", [true]) }
            try session.writeBools("/g/replaced", [false])
            try session.writeBools("/g/replaced", [true, true], replace: true)
            #expect(throws: HDF5FileError.self) { try session.writeBools("/g", [true], replace: true) }
        }
        let reader = try HDF5Reader(url: out)
        #expect(try reader.readBooleans("/crystal_map/data/is_in_data") == values)
        let info = try reader.datasetInfo("/crystal_map/data/is_in_data")
        #expect(info.shape == [values.count])
        #expect(try reader.datasetInfo("/g/scalar").type == info.type, "the type of writeBool")
        #expect(try reader.readBooleans("/g/empty") == [])
        #expect(try reader.datasetInfo("/g/empty").shape == [0])
        #expect(try reader.readBooleans("/g/replaced") == [true, true])
    }
}
