//
//  HSPYWriter.swift
//  Role: write a signal as a HyperSpy file (.hspy, layout 3.3; `HSPYLayout`), whole from memory (`HSPYWriter.write`) or a slab
//        at a time (`HSPYWriter.open` and `HSPYStreamWriter`), for a cube larger than the memory one wants to spend on it.
//
//  Both go through FormatoHDF5's `HDF5SlabWriter`: the file is built beside the destination and moved onto it only when
//  complete, so a refused, failed or cancelled write leaves the destination as it was and no scratch behind. The writer holds
//  no copy of the data: each slab is written from where the caller holds it. Swift task cancellation is checked before every
//  slab and before the publish (FormatoKit's contract, `FormatoCancellation`): a cancelled write throws `FormatoCancelled`.
//

import Foundation
import FormatoCore
import FormatoHDF5

public nonisolated enum HSPYWriter {
    /// About this many bytes a slab when a whole signal is written: the unit between two cancellation checks.
    static let slabBytes = 16 << 20

    /// Writes `signal` as a HyperSpy file at `destination` (replacing what is there, atomically). The data keeps its stored
    /// type; the signal's metadata entries become HyperSpy's metadata tree (the writer's own keys aside), then the options'.
    /// - Parameters:
    ///   - kind: the class HyperSpy builds on load; it sets `signal_type` (the signal's own `signalType` is not read).
    ///   - cancelled: checked before each slab of about 16 MB and before the publish.
    /// - Throws: `HSPYError` for what the layout refuses (before anything is written), `HDF5FileError` for the file,
    ///   `FormatoCancelled`.
    public static func write(_ signal: FormatoSignal, kind: HSPYSignalKind, options: HSPYWriteOptions = HSPYWriteOptions(),
                             to destination: URL, cancelled: @escaping @Sendable () -> Bool = FormatoCancellation.task) throws {
        let data = signal.data
        let writer = try HSPYStreamWriter(shape: data.shape, dataType: data.dataType, axes: signal.axes, kind: kind,
                                          title: options.title ?? signal.title, signalMetadata: signal.metadata, options: options,
                                          destination: destination, cancelled: cancelled)
        do {
            // Bands along the first dimension, each written from the signal's own bytes.
            let rowElements = data.shape.dropFirst().reduce(1, *)
            let rowBytes = rowElements * data.dataType.byteSize
            let rowsPerSlab = max(1, slabBytes / max(1, rowBytes))
            try data.bytes.withUnsafeBytes { all in
                var row = 0
                while row < data.shape[0] {
                    let rows = min(rowsPerSlab, data.shape[0] - row)
                    let slab = UnsafeRawBufferPointer(rebasing: all[(row * rowBytes)..<((row + rows) * rowBytes)])
                    try writer.write(bytes: slab, count: [rows] + data.shape.dropFirst(), at: [row] + Array(repeating: 0, count: data.shape.count - 1))
                    row += rows
                }
            }
            try writer.publish()
        } catch {
            writer.cancel()
            throw error
        }
    }

    /// Starts a HyperSpy file at `destination` whose data is written a slab at a time (`HSPYStreamWriter.write(slab:at:)`), for a
    /// cube that is read, computed or acquired in pieces. The structure (axes, metadata) is written now; the data is allocated
    /// a chunk at a time as slabs arrive; nothing reaches `destination` before `publish()`.
    /// - Parameters:
    ///   - shape: the data's shape in array order, rank 1 to 4.
    ///   - axes: one per dimension, in array order; the signal axes last.
    ///   - cancelled: checked before each slab and before the publish; a cancelled stream removes its file.
    /// - Throws: `HSPYError` for what the layout refuses, `HDF5FileError` for the file.
    public static func open(shape: [Int], dataType: FormatoDataType, axes: [FormatoAxis], kind: HSPYSignalKind,
                            options: HSPYWriteOptions = HSPYWriteOptions(), to destination: URL,
                            cancelled: @escaping @Sendable () -> Bool = FormatoCancellation.task) throws -> HSPYStreamWriter {
        try HSPYStreamWriter(shape: shape, dataType: dataType, axes: axes, kind: kind, title: options.title ?? "",
                             signalMetadata: FormatoMetadata(), options: options, destination: destination, cancelled: cancelled)
    }
}

/// A HyperSpy file being written a slab at a time (`HSPYWriter.open`). Not thread-safe: one caller at a time, who may await
/// between slabs (no HDF5 handle or lock is held between calls). An abandoned writer removes its scratch file.
public nonisolated final class HSPYStreamWriter: @unchecked Sendable {
    /// The file the writer publishes onto.
    public var destination: URL { slabs.destination }
    /// The data's shape, element type and chunk shape.
    public var shape: [Int] { slabs.shape }
    public var dataType: FormatoDataType { slabs.dataType }
    public var chunkShape: [Int] { slabs.chunk }
    /// Values written so far, summed over the slabs.
    public var elementsWritten: Int { slabs.elementsWritten }
    /// The scratch file, for the tests (it must be gone after a publish, a cancel or a failure).
    package var scratch: URL { slabs.scratch }

    private let slabs: HDF5SlabWriter
    private let cancelled: @Sendable () -> Bool
    private var finished = false

    init(shape: [Int], dataType: FormatoDataType, axes: [FormatoAxis], kind: HSPYSignalKind, title: String,
         signalMetadata: FormatoMetadata, options: HSPYWriteOptions, destination: URL,
         cancelled: @escaping @Sendable () -> Bool) throws {
        let plan = try HSPYLayout.plan(shape: shape, dataType: dataType, axes: axes, kind: kind, title: title,
                                       signalMetadata: signalMetadata, options: options)
        try FormatoCancellation.check(cancelled)
        slabs = try HDF5SlabWriter(destination: destination, path: plan.dataPath, dataType: dataType, shape: shape, chunk: plan.chunk) {
            try HSPYLayout.writeStructure(plan, $0)
        }
        self.cancelled = cancelled
    }

    /// Writes `slab` (the data's rank and element type) with its first element at `start`. A slab of another type or outside
    /// the data is refused by name and the file stays open for the next one. A cancelled task removes the file and throws
    /// `FormatoCancelled`; a failed HDF5 write removes it too (and later calls throw `HSPYError.finished`).
    public func write(slab: FormatoArray, at start: [Int]) throws {
        try checkSlab(count: slab.shape, dataType: slab.dataType, at: start)
        try guarded { try slabs.write(slab, at: start) }
    }

    /// `write(slab:at:)` from the caller's memory: `bytes` holds `count`'s values of the data's type in C order, little-endian,
    /// written where they lie (no copy).
    public func write(bytes: UnsafeRawBufferPointer, count: [Int], at start: [Int]) throws {
        try checkSlab(count: count, dataType: dataType, at: start)
        let expected = try FormatoArray.elementCount(count) * dataType.byteSize
        guard bytes.count == expected else { throw HSPYError.slabByteCount(expected: expected, found: bytes.count) }
        try guarded { try slabs.write(bytes: bytes, count: count, at: start) }
    }

    /// Moves the finished file onto the destination. Fewer values written than the data holds throws `incomplete` and the file
    /// stays open; a cancelled task removes it and throws `FormatoCancelled`.
    public func publish() throws {
        guard !finished else { throw HSPYError.finished }
        guard slabs.elementsWritten >= slabs.elementCount else {
            throw HSPYError.incomplete(written: slabs.elementsWritten, expected: slabs.elementCount)
        }
        try guarded {
            finished = true
            try slabs.publish()
        }
    }

    /// Abandons the file: the scratch is removed and the destination is untouched. Safe to call more than once.
    public func cancel() {
        finished = true
        slabs.cancel()
    }

    private func checkSlab(count: [Int], dataType slabType: FormatoDataType, at start: [Int]) throws {
        guard !finished else { throw HSPYError.finished }
        guard slabType == dataType else { throw HSPYError.slabDataType(expected: dataType, found: slabType) }
        guard start.count == shape.count, count.count == shape.count,
              (try? FormatoArray.validateSlab(start: start, count: count, shape: shape)) != nil else {
            throw HSPYError.slabOutsideData(start: start, count: count, shape: shape)
        }
    }

    /// Runs `body` after the cancellation check; a cancel or a failure ends the file.
    private func guarded(_ body: () throws -> Void) throws {
        do {
            try FormatoCancellation.check(cancelled)
            try body()
        } catch {
            cancel()
            throw error
        }
    }
}
