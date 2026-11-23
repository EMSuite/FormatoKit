//
//  HSPYStreamWriterTests.swift
//  `HSPYWriter.open` and `HSPYStreamWriter` (FormatoKit#142): a cube written a slab at a time is the file HyperSpy writes for
//  the same signal (pin H2's layout); slabs outside the data, of another type or too few are refused by name; a cancelled or
//  failed write leaves nothing at the destination and no scratch; and the writer holds no more than the slab in hand, so a
//  cube far larger than a slab is written with a flat footprint (FormatoHDF5's `HDF5SlabWriter` under it).
//

import Darwin
import Foundation
import Testing
import FormatoCore
import FormatoHDF5
import FormatoHSPY

@Suite(.serialized) struct HSPYStreamWriterTests {

    /// The process's physical footprint in bytes (`TASK_VM_INFO`, what Activity Monitor shows).
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Opens the planted signal's stream with the golden's options (its "options" metadata and the fixed FileIO entry).
    static func open(_ planted: HSPYPlanted, to url: URL, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> HSPYStreamWriter {
        let (signal, kind, baseOptions) = try HSPYGolden.signal(planted)
        var options = baseOptions
        options.title = planted.title
        for entry in signal.metadata.entries { options.metadata[entry.key] = entry.value }
        return try HSPYWriter.open(shape: planted.shape, dataType: signal.data.dataType, axes: signal.axes, kind: kind, options: options,
                                   to: url, cancelled: cancelled)
    }

    // MARK: The same file, slab by slab

    /// Rows of 7 along the first axis, across HyperSpy's chunks of 31 (no slab is chunk-aligned), as `FormatoArray`s and as bytes.
    @Test(arguments: ["eds-tem-map-chunked-u16", "patterns-4d-chunked-u16", "eels-map-f64", "spectrum-f64"])
    func aStreamWritesWhatHyperSpyWrites(_ name: String) throws {
        let planted = try HSPYGolden.planted(name)
        let type = try #require(HSPYGolden.dataType(planted.dtype))
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(name).hspy")
        let writer = try Self.open(planted, to: url)
        #expect(!FileManager.default.fileExists(atPath: url.path), "nothing at the destination before publish")
        #expect(writer.chunkShape == planted.layout.datasets["data"]?.chunks)
        let rowElements = planted.shape.dropFirst().reduce(1, *)
        var row = 0, slabIndex = 0
        while row < planted.shape[0] {
            let rows = min(7, planted.shape[0] - row)
            let values = HSPYGolden.plantedValues(type, count: rows * rowElements, from: row * rowElements)
            let start = [row] + Array(repeating: 0, count: planted.shape.count - 1)
            let count = [rows] + planted.shape.dropFirst()
            if slabIndex.isMultiple(of: 2) {
                try writer.write(slab: try FormatoArray(dataType: type, shape: count, bytes: values), at: start)
            } else {
                try values.withUnsafeBytes { try writer.write(bytes: $0, count: count, at: start) }
            }
            row += rows
            slabIndex += 1
        }
        #expect(writer.elementsWritten == planted.shape.reduce(1, *))
        try writer.publish()
        try HSPYGolden.expectLayout(url, planted)
        #expect(!FileManager.default.fileExists(atPath: writer.scratch.path))
        #expect(throws: HSPYError.finished) { try writer.publish() }
    }

    @Test func slabsAreCheckedByName() throws {
        let planted = try HSPYGolden.planted("eds-sem-map-u16")
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("slabs.hspy")
        let writer = try Self.open(planted, to: url)
        let row = try FormatoArray(dataType: .uint16, shape: [1, 4, 20], bytes: HSPYGolden.plantedValues(.uint16, count: 80))
        #expect(throws: HSPYError.slabDataType(expected: .uint16, found: .float32)) {
            try writer.write(slab: try FormatoArray(dataType: .float32, shape: [1, 4, 20], bytes: Data(count: 320)), at: [0, 0, 0])
        }
        #expect(throws: HSPYError.slabOutsideData(start: [3, 0, 0], count: [1, 4, 20], shape: [3, 4, 20])) { try writer.write(slab: row, at: [3, 0, 0]) }
        #expect(throws: HSPYError.slabOutsideData(start: [0, 0], count: [1, 4, 20], shape: [3, 4, 20])) { try writer.write(slab: row, at: [0, 0]) }
        #expect(throws: HSPYError.slabOutsideData(start: [0, 1, 0], count: [1, 4, 20], shape: [3, 4, 20])) { try writer.write(slab: row, at: [0, 1, 0]) }
        try Data(count: 10).withUnsafeBytes { bytes in
            #expect(throws: HSPYError.slabByteCount(expected: 160, found: 10)) { try writer.write(bytes: bytes, count: [1, 4, 20], at: [0, 0, 0]) }
        }
        // A refused slab leaves the file open; too few values refuse the publish and keep it open too.
        for start in [0, 1] {
            let values = HSPYGolden.plantedValues(.uint16, count: 80, from: start * 80)
            try writer.write(slab: try FormatoArray(dataType: .uint16, shape: [1, 4, 20], bytes: values), at: [start, 0, 0])
        }
        #expect(throws: HSPYError.incomplete(written: 160, expected: 240)) { try writer.publish() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try writer.write(slab: try FormatoArray(dataType: .uint16, shape: [1, 4, 20], bytes: HSPYGolden.plantedValues(.uint16, count: 80, from: 160)),
                         at: [2, 0, 0])
        try writer.publish()
        try HSPYGolden.expectLayout(url, planted)
    }

    // MARK: Cancelled and failed writes

    @Test func aCancelledStreamLeavesNoFile() throws {
        let planted = try HSPYGolden.planted("eds-tem-map-chunked-u16")
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cancelled.hspy")
        let flag = CancelFlag()
        let writer = try Self.open(planted, to: url, cancelled: { flag.isSet })
        let rowElements = 48 * 512
        try writer.write(slab: try FormatoArray(dataType: .uint16, shape: [1, 48, 512],
                                                bytes: HSPYGolden.plantedValues(.uint16, count: rowElements)), at: [0, 0, 0])
        #expect(FileManager.default.fileExists(atPath: writer.scratch.path), "the scratch holds the file so far")
        flag.set()
        #expect(throws: FormatoCancelled.self) {
            try writer.write(slab: try FormatoArray(dataType: .uint16, shape: [1, 48, 512],
                                                    bytes: HSPYGolden.plantedValues(.uint16, count: rowElements, from: rowElements)), at: [1, 0, 0])
        }
        #expect(!FileManager.default.fileExists(atPath: writer.scratch.path), "the scratch is removed")
        #expect(!FileManager.default.fileExists(atPath: url.path), "nothing at the destination")
        #expect(throws: HSPYError.finished) { try writer.publish() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func aCancelBeforeThePublishLeavesTheOldFile() throws {
        let planted = try HSPYGolden.planted("eels-spectrum-f32")
        let (signal, kind, options) = try HSPYGolden.signal(planted)
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("kept.hspy")
        try Data("the older file".utf8).write(to: url)
        // Cancelled at the first check: before any slab.
        #expect(throws: FormatoCancelled.self) { try HSPYWriter.write(signal, kind: kind, options: options, to: url, cancelled: { true }) }
        // Cancelled at the last check, after every slab: before the publish.
        let calls = CancelFlag()
        #expect(throws: FormatoCancelled.self) {
            try HSPYWriter.write(signal, kind: kind, options: options, to: url, cancelled: { calls.countAndAnswer(trueFrom: 3) })
        }
        #expect(calls.count == 3, "checked at the start, before the one slab and before the publish")
        #expect(try Data(contentsOf: url) == Data("the older file".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["kept.hspy"])
        // An explicit cancel of a stream.
        let writer = try Self.open(planted, to: url)
        let scratch = writer.scratch
        writer.cancel()
        writer.cancel()
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(throws: HSPYError.finished) {
            try writer.write(slab: try FormatoArray(dataType: .float32, shape: [24], bytes: Data(count: 96)), at: [0])
        }
        #expect(try Data(contentsOf: url) == Data("the older file".utf8))
    }

    @Test func swiftTaskCancellationStopsTheWrite() async throws {
        let planted = try HSPYGolden.planted("stack-big-frames-u8")
        let (signal, kind, options) = try HSPYGolden.signal(planted)
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("task.hspy")
        let task = Task<Bool, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try HSPYWriter.write(signal, kind: kind, options: options, to: url)     // the default: FormatoCancellation.task
                return false
            } catch is FormatoCancelled { return true } catch { return false }
        }
        #expect(await task.value, "the write threw FormatoCancelled")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func anAbandonedWriterRemovesItsScratch() throws {
        let planted = try HSPYGolden.planted("image-u8")
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("abandoned.hspy")
        var scratch: URL?
        do {
            let writer = try Self.open(planted, to: url)
            scratch = writer.scratch
            #expect(FileManager.default.fileExists(atPath: writer.scratch.path))
        }
        let left = try #require(scratch)
        #expect(!FileManager.default.fileExists(atPath: left.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Footprint

    /// A 256 MiB cube written in 1 MiB slabs from one reused buffer: the footprint grows by a few slabs at most, never by the
    /// cube (a writer that kept its slabs, or a file built in memory, would grow by 256 MiB). FORMATO_HSPY_BIG=1 runs it at 4 GiB.
    @Test func aLargeCubeIsWrittenHoldingOneSlab() throws {
        let big = ProcessInfo.processInfo.environment["FORMATO_HSPY_BIG"] != nil
        let rows = big ? 4096 : 256, columns = 256, channels = 2048          // uint16: 256 MiB, or 4 GiB
        let slab = columns * channels * 2
        let axes = [FormatoAxis(name: "y", size: rows, scale: 1, offset: 0, units: "nm", navigate: true),
                    FormatoAxis(name: "x", size: columns, scale: 1, offset: 0, units: "nm", navigate: true),
                    FormatoAxis(name: "Energy", size: channels, scale: 0.01, offset: 0, units: "keV", navigate: false)]
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cube.hspy")
        let writer = try HSPYWriter.open(shape: [rows, columns, channels], dataType: .uint16, axes: axes, kind: .edsTEM,
                                         options: HSPYWriteOptions(title: "cube", chunkShape: [1, 64, channels]), to: url,
                                         cancelled: { false })
        // One buffer for every slab; each row differs from the others in its first value.
        var buffer = (0..<(columns * channels)).map { UInt16(truncatingIfNeeded: $0) }
        let start = Self.footprint()
        var peak = start
        for row in 0..<rows {
            buffer[0] = UInt16(truncatingIfNeeded: row)
            try buffer.withUnsafeBytes { try writer.write(bytes: $0, count: [1, columns, channels], at: [row, 0, 0]) }
            peak = max(peak, Self.footprint())
        }
        try writer.publish()
        let grown = peak - start
        #expect(grown < 4 * slab + (16 << 20),
                "the write grew the footprint by \(grown >> 20) MB for a \((rows * slab) >> 20) MB cube in \(slab >> 20) MB slabs")
        // The file holds the cube: two rows read back.
        let reader = try HDF5Reader(url: url)
        for row in [0, rows - 1] {
            let read = try reader.readDataset("/Experiments/cube/data", start: [row, 0, 0], count: [1, columns, channels])
            let expected = [UInt16(truncatingIfNeeded: row)] + (1..<(columns * channels)).map { UInt16(truncatingIfNeeded: $0) }
            #expect(read.bytes == expected.withUnsafeBytes { Data($0) }, "row \(row)")
        }
        #expect(try reader.filterCount(of: "/Experiments/cube/data") == 0)
    }
}

/// A flag the `cancelled` closure reads, set by the test; and a counter that answers true from its n-th call.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var calls = 0

    var isSet: Bool { lock.withLock { value } }
    var count: Int { lock.withLock { calls } }
    func set() { lock.withLock { value = true } }
    func countAndAnswer(trueFrom n: Int) -> Bool {
        lock.withLock {
            calls += 1
            return calls >= n
        }
    }
}
