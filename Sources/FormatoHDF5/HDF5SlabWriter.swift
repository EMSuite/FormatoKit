//
//  HDF5SlabWriter.swift
//  Role: a NEW HDF5 file whose one large numeric dataset is filled a slab at a time, and published only when complete: the
//        layer under the format writers that stream a cube (FormatoHSPY's `HSPYStreamWriter`; the first consumer's orix
//        HDF5 and h5ebsd writers, EMSuite/Electron-Microscopy-Studio#184). What the file's layout means belongs to the caller,
//        which writes the structure around the dataset through `HDF5WriteSession` (`init`'s `structure`, or `append`).
//
//  The file is an `HDF5PendingFile`: built under a scratch name beside the destination and moved onto it by atomic rename at
//  `publish`, so a failed, cancelled or abandoned write leaves the destination as it was and no scratch behind. The dataset
//  is chunked (HDF5 allocates a chunk when it is first written, so a 16 GB dataset costs nothing until filled) and stored
//  without filters. Each slab is written from the caller's memory where it lies: the writer holds no copy of it, and no HDF5
//  handle or lock outlives a call (`HDF5PendingFile`), so a caller may await between slabs.
//

import Foundation
import FormatoCore

/// A new HDF5 file whose dataset at `path` is written a slab at a time. Not thread-safe: one caller at a time.
public nonisolated final class HDF5SlabWriter: @unchecked Sendable {
    /// The file the writer publishes onto.
    public var destination: URL { pending.destination }
    /// The dataset's path, element type, shape (C order) and chunk shape.
    public let path: String
    public let dataType: FormatoDataType
    public let shape: [Int]
    public let chunk: [Int]
    /// Elements written so far, summed over the slabs (a slab written twice counts twice).
    public private(set) var elementsWritten = 0
    /// Every element of the dataset: `publish` needs at least this many written.
    public let elementCount: Int
    /// The scratch file, for the tests (it must be gone after a publish, a cancel or a failure).
    package var scratch: URL { pending.scratch }

    private let pending: HDF5PendingFile
    private var finished = false

    /// Starts the file: `structure` writes what lies around the dataset (groups, attributes), then the dataset is created at
    /// `path` (missing groups above it are made), chunked by `chunk`, unfilled. Nothing reaches `destination` before `publish`.
    /// - Parameters:
    ///   - dataType: an integer or float type (the colour types are refused, `invalidArgument`).
    ///   - shape: one extent of at least 1 per dimension, rank 1 to 32.
    ///   - chunk: one extent per dimension, each from 1 to the dataset's extent, under 4 GiB a chunk.
    ///   - sourcePath: the file the values come from; a destination that is that file (by identity) is refused
    ///     (`destinationIsSource`) before anything is written.
    /// - Throws: `HDF5FileError`, or what `structure` throws; the scratch is then removed.
    public init(destination: URL, path: String, dataType: FormatoDataType, shape: [Int], chunk: [Int], sourcePath: String? = nil,
                structure: (HDF5WriteSession) throws -> Void = { _ in }) throws {
        guard !shape.isEmpty, shape.allSatisfy({ $0 >= 1 }), let count = try? FormatoArray.elementCount(shape),
              !count.multipliedReportingOverflow(by: dataType.byteSize).overflow else {
            throw HDF5FileError.invalidArgument("a streamed dataset has extents of at least 1, not \(shape)")
        }
        self.path = path
        self.dataType = dataType
        self.shape = shape
        self.chunk = chunk
        elementCount = count
        pending = try HDF5PendingFile(destination: destination, sourcePath: sourcePath)
        do {
            try pending.append { session in
                try structure(session)
                try session.createDataset(path, dataType: dataType, shape: shape, chunk: chunk)
            }
        } catch {
            pending.discard()
            finished = true
            throw error
        }
    }

    deinit { if !finished { pending.discard() } }

    /// Writes `slab` (the dataset's rank and element type) with its first element at `start`. A slab outside the dataset or of
    /// another type throws `invalidArgument` and writes nothing; the file stays open for the next slab.
    public func write(_ slab: FormatoArray, at start: [Int]) throws {
        try checkOpen()
        let elements = try check(slab: slab.shape, dataType: slab.dataType, at: start)
        try run { try $0.writeSlab(path, start: start, slab) }
        elementsWritten += elements
    }

    /// `write(_:at:)` from the caller's memory: `bytes` holds `count`'s elements of `dataType` in C order, little-endian. HDF5
    /// reads them where they are; the array that wraps them lives only for the synchronous write.
    public func write(bytes: UnsafeRawBufferPointer, count: [Int], at start: [Int]) throws {
        try checkOpen()
        let elements = try check(slab: count, dataType: dataType, at: start)
        guard bytes.count == elements * dataType.byteSize else {
            throw HDF5FileError.invalidArgument("\(bytes.count) bytes for a slab of \(count) \(dataType.rawValue)")
        }
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        let wrapped = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
        let slab = try FormatoArray(dataType: dataType, shape: count, bytes: wrapped)
        try run { try $0.writeSlab(path, start: start, slab) }
        elementsWritten += elements
    }

    /// Runs `body` on the file between slabs (more structure, attributes known only after the data). A throwing body ends the
    /// file as `HDF5PendingFile.append` does: the scratch is removed and every later call throws.
    public func append(_ body: (HDF5WriteSession) throws -> Void) throws {
        try checkOpen()
        try run(body)
    }

    /// Moves the file onto the destination (the item that was there when the writer started is replaced; one that appeared
    /// since is left alone and the call throws `cannotWrite`). Fewer elements written than the dataset holds throws
    /// `invalidArgument` and publishes nothing; the file stays open for more slabs or `cancel`.
    public func publish() throws {
        try checkOpen()
        guard elementsWritten >= elementCount else {
            throw HDF5FileError.invalidArgument("\(elementsWritten) of the \(elementCount) elements of \(path) were written")
        }
        finished = true
        try pending.publish()
    }

    /// Abandons the file: the scratch is removed, the destination is untouched. Safe to call more than once.
    public func cancel() {
        finished = true
        pending.discard()
    }

    /// A failed HDF5 call ends the file (`HDF5PendingFile` has removed the scratch), so later calls are refused by name.
    private func run(_ body: (HDF5WriteSession) throws -> Void) throws {
        do { try pending.append(body) } catch {
            finished = true
            throw error
        }
    }

    private func checkOpen() throws {
        guard !finished else { throw HDF5FileError.invalidArgument("the slab writer of \(path) was already published or cancelled") }
    }

    /// The slab's element count, after checking it lies inside the dataset with the dataset's rank and type.
    private func check(slab count: [Int], dataType slabType: FormatoDataType, at start: [Int]) throws -> Int {
        guard slabType == dataType else {
            throw HDF5FileError.invalidArgument("a \(slabType.rawValue) slab for \(path), which stores \(dataType.rawValue)")
        }
        guard start.count == shape.count, count.count == shape.count,
              (try? FormatoArray.validateSlab(start: start, count: count, shape: shape)) != nil else {
            throw HDF5FileError.invalidArgument("slab \(start) of \(count) is outside \(path) of shape \(shape)")
        }
        return try FormatoArray.elementCount(count)
    }
}
