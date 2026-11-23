//
//  HDF5SlabWriterTests.swift
//  `HDF5SlabWriter` (FormatoKit#142), the layer under the .hspy stream writer and the first consumer's orix and h5ebsd writers:
//  the structure is written first, the dataset is filled a slab at a time from `FormatoArray`s or the caller's bytes, nothing
//  is at the destination before `publish`, slabs that do not fit are refused, a publish with too few elements is refused and
//  keeps the file, and a cancel or an abandoned writer leaves no scratch. FormatoHSPYTests check the layout and the footprint.
//

import Foundation
import Testing
import FormatoCore
import FormatoHDF5

@Suite struct HDF5SlabWriterTests {

    @Test func aDatasetIsFilledSlabBySlabAndPublishedWhole() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("slabs.h5")
        let writer = try HDF5SlabWriter(destination: url, path: "/g/data", dataType: .int16, shape: [4, 3], chunk: [3, 3]) { session in
            try session.setVariableLengthTextAttribute("kind", on: "/", "test")
        }
        #expect(writer.elementCount == 12 && writer.elementsWritten == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let first: [Int16] = [1, -2, 3, 4, -5, 6]
        try writer.write(try FormatoArray(dataType: .int16, shape: [2, 3], bytes: first.withUnsafeBytes { Data($0) }), at: [0, 0])
        let rest: [Int16] = [7, 8, 9, 10, 11, -12]
        try rest.withUnsafeBytes { try writer.write(bytes: $0, count: [2, 3], at: [2, 0]) }
        #expect(writer.elementsWritten == 12)
        try writer.publish()
        let reader = try HDF5Reader(url: url)
        #expect(try reader.readDataset("/g/data").bytes == (first + rest).withUnsafeBytes { Data($0) })
        #expect(try reader.chunkShape(of: "/g/data") == [3, 3])
        #expect(try reader.filterCount(of: "/g/data") == 0)
        #expect(try reader.attribute("kind", of: "/") == .text("test"))
        #expect(!FileManager.default.fileExists(atPath: writer.scratch.path))
        #expect(throws: HDF5FileError.self) { try writer.publish() }
    }

    @Test func slabsThatDoNotFitAreRefusedAndTheFileStaysOpen() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("refused.h5")
        let writer = try HDF5SlabWriter(destination: url, path: "/data", dataType: .float32, shape: [2, 2], chunk: [1, 2])
        let row = try FormatoArray(dataType: .float32, shape: [1, 2], bytes: Data(count: 8))
        #expect(throws: HDF5FileError.self) { try writer.write(row, at: [2, 0]) }
        #expect(throws: HDF5FileError.self) { try writer.write(row, at: [0]) }
        #expect(throws: HDF5FileError.self) { try writer.write(try FormatoArray(dataType: .int32, shape: [1, 2], bytes: Data(count: 8)), at: [0, 0]) }
        try Data(count: 4).withUnsafeBytes { bytes in
            #expect(throws: HDF5FileError.self) { try writer.write(bytes: bytes, count: [1, 2], at: [0, 0]) }
        }
        try writer.write(row, at: [0, 0])
        #expect(throws: HDF5FileError.self) { try writer.publish() }                 // 2 of 4 elements
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: writer.scratch.path))
        writer.cancel()
        #expect(!FileManager.default.fileExists(atPath: writer.scratch.path))
        #expect(throws: HDF5FileError.self) { try writer.write(row, at: [1, 0]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func aRefusedStartLeavesNothing() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("never.h5")
        #expect(throws: HDF5FileError.self) {
            _ = try HDF5SlabWriter(destination: url, path: "/data", dataType: .rgb8, shape: [2, 2], chunk: [1, 2])
        }
        #expect(throws: HDF5FileError.self) {
            _ = try HDF5SlabWriter(destination: url, path: "/data", dataType: .uint8, shape: [2, 0], chunk: [1, 1])
        }
        #expect(throws: HDF5FileError.self) {
            _ = try HDF5SlabWriter(destination: url, path: "/data", dataType: .uint8, shape: [2, 2], chunk: [3, 2])
        }
        struct Refused: Error {}
        #expect(throws: Refused.self) {
            _ = try HDF5SlabWriter(destination: url, path: "/data", dataType: .uint8, shape: [2, 2], chunk: [1, 2]) { _ in throw Refused() }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        var scratch: URL?
        do {
            let writer = try HDF5SlabWriter(destination: url, path: "/data", dataType: .uint8, shape: [2, 2], chunk: [1, 2])
            scratch = writer.scratch
        }
        let left = try #require(scratch)
        #expect(!FileManager.default.fileExists(atPath: left.path), "an abandoned writer removes its scratch")
    }
}
