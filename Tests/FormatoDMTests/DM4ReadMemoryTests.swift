//
//  DM4ReadMemoryTests.swift
//  Role: a DM4 read keeps one block alive at a time (#136). On 18 Nov 2026, reading the 145_STEM spectrum image (two 727 MB float32 cubes)
//        raised the footprint by 2.91 GB, twice the cubes, until the read returned (Electron-Microscopy-Studio#581). The suspect: every block
//        `FileHandle.read(upToCount:)` returned stayed in the thread's autorelease pool until the read ended.
//
//  THE TRUTH: a 256 MB sparse file read in 8 MB blocks, as `decodeEELS` reads a cube. The bytes the reader still holds are only the block
//  in hand, so the footprint may grow by a few blocks (and what parallel suites allocate meanwhile), never by the file.
//

import Darwin
import Foundation
import Testing
@testable import FormatoDM

@Suite(.serialized) struct DM4ReadMemoryTests {

    /// The process's physical footprint in bytes (`TASK_VM_INFO`, what Activity Monitor shows).
    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Red before #136: the footprint grew by the whole file (every block still held). Each block is touched, as the scatter does.
    @Test func aLongReadHoldsOneBlockAtATime() throws {
        let size = 256 << 20, block = 8 << 20
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dm4-read-memory-\(UUID().uuidString).bin")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(size))   // sparse: reads as zeros, nothing written
        try writer.close()

        let source = try DM4Experiment.Source.file(url.path)
        #expect(source.size == size)
        let start = Self.footprint()
        var peak = start, sum = 0
        var offset = 0
        while offset < size {
            let bytes = try source.fetch(offset, block)
            sum &+= Int(bytes[0]) &+ Int(bytes[block - 1])
            peak = max(peak, Self.footprint())
            offset += block
        }
        #expect(sum == 0)
        let grown = peak - start
        // The footprint is the whole process's: suites outside this one run in parallel and allocate meanwhile, and malloc keeps
        // freed blocks for reuse, so a correct read measured 34 MB once (FormatoKit#173). Eight blocks is still a quarter of
        // the 256 MB the bug grew by.
        #expect(grown < 8 * block, "the read grew the footprint by \(grown >> 20) MB for a \(size >> 20) MB file read in \(block >> 20) MB blocks")
    }
}
