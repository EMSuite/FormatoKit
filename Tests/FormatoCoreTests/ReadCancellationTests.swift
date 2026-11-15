//
//  ReadCancellationTests.swift
//  The file readers' run walk asks for cancellation every `cancelCheckRuns` runs and throws `FormatoCancelled` (#106), and a
//  file-backed slab read inside a cancelled task stops with that error instead of reading on.
//

import Foundation
import Testing
import os
import FormatoCore

@Suite struct ReadCancellationTests {

    /// Cancelled from the start, no run is visited. Red under: the walk asking nothing.
    @Test func aCancelledWalkVisitsNoRun() {
        var runs = 0
        var thrown: Error?
        do {
            try FormatoArray.forEachContiguousRun(start: [0, 0], count: [10, 4], shape: [10, 4], cancelled: { true }) { _, _ in runs += 1 }
        } catch { thrown = error }
        #expect(thrown is FormatoCancelled)
        #expect(runs == 0)
    }

    /// The first ask says go and the next says stop: exactly one block of runs is visited. Red under: the ask per run (one
    /// visited) or never (all visited).
    @Test func theWalkAsksOncePerBlockOfRuns() {
        let asks = OSAllocatedUnfairLock(initialState: 0)
        let rows = 3 * FormatoArray.cancelCheckRuns
        var runs = 0
        var thrown: Error?
        do {
            try FormatoArray.forEachContiguousRun(start: [0, 0], count: [rows, 2], shape: [rows, 2],
                                                  cancelled: { asks.withLock { $0 += 1; return $0 > 1 } }) { _, _ in runs += 1 }
        } catch { thrown = error }
        #expect(thrown is FormatoCancelled)
        #expect(runs == FormatoArray.cancelCheckRuns)
    }

    /// Never cancelled, the walk visits the same runs as the plain one. Red under: a run dropped at a block boundary.
    @Test func anUncancelledWalkIsThePlainWalk() throws {
        var plain: [[Int]] = [], asked: [[Int]] = []
        FormatoArray.forEachContiguousRun(start: [1, 2, 0], count: [3, 300, 5], shape: [5, 400, 5]) { plain.append([$0, $1]) }
        try FormatoArray.forEachContiguousRun(start: [1, 2, 0], count: [3, 300, 5], shape: [5, 400, 5], cancelled: { false }) {
            asked.append([$0, $1])
        }
        #expect(asked == plain)
    }

    /// A pread-backed slab read in a cancelled task throws `FormatoCancelled`; the same read in a live task returns the bytes.
    @Test func aFileArrayReadStopsInACancelledTask() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("formato-cancel-\(UUID().uuidString).bin")
        try Data((0..<(64 * 64 * 2)).map { UInt8(truncatingIfNeeded: $0) }).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let lazy = FormatoFileArray(path: url.path, offset: 0, dataType: .uint8, shape: [64, 128])
        let cancelled = Task { () throws -> FormatoArray in
            withUnsafeCurrentTask { $0?.cancel() }
            return try lazy.readAll()
        }
        await #expect(throws: FormatoCancelled.self) { try await cancelled.value }
        let live = try await Task { try lazy.readAll() }.value
        #expect(live.bytes.count == 64 * 128)
    }
}
