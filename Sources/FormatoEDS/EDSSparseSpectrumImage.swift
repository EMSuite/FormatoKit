//
//  EDSSparseSpectrumImage.swift
//  Role: a SEM-EDS spectrum image as per-pixel compressed rows (an event-counting detector fills a few channels per pixel), and
//        the lazy array of its signal: `read` hands out the dense counts of any hyperslab in RosettaSciIO's data type and shape,
//        so a 512 x 512 x 4096 JEOL map is held as the X-rays it recorded, not as the cube. The counts are exact integers; every
//        sum is an exact UInt64 sum.
//        Moved from Electron Microscopy Studio's Sources/TEMSEM/EDS/SEMEDSFile.swift (`CSRSpectrumImage`,
//        `CSRSpectrumImageBuilder`, at f1eaafc) by FormatoKit#148; the data type, the shape and `read` are new (the lazy array of
//        the signal), the sums and checks unchanged. The consumer's spectral maths conforms it to its own spectrum-image protocol.
//

import Foundation
import FormatoCore

/// A spectrum image as per-pixel compressed rows: `rowOffsets` (ny · nx + 1 entries) into `channelIndex` and `counts`; inside a
/// pixel the channels ascend and each appears once with a nonzero count. Every sum is an exact UInt64 sum.
/// As a lazy array its `shape` is RosettaSciIO's ([y, x, energy] for a map, [x, energy] for an EDAX line scan, which the rows
/// hold as one row of pixels) and its `dataType` the one RosettaSciIO gives the data (uint8, uint16 or uint32); the counts here
/// are the same integers held as UInt32.
public nonisolated struct EDSSparseSpectrumImage: FormatoLazyArray, Equatable {
    public let ny: Int
    public let nx: Int
    public let channels: Int
    public let rowOffsets: [Int]
    public let channelIndex: [UInt16]
    public let counts: [UInt32]
    /// RosettaSciIO's data type for the counts.
    public let dataType: FormatoDataType
    /// RosettaSciIO's shape: the pixels in row-major order over every dimension but the last, then the channels.
    public let shape: [Int]

    /// Checked whole, so no later read can index past the counts or past a spectrum: `ny · nx + 1` offsets from 0, never
    /// decreasing, ending at the count of entries, and every channel below `channels`. A reader's damaged file is refused here.
    /// `shape` (default [ny, nx, channels]) must end with the channels and hold ny · nx pixels before them; `dataType` is one of
    /// uint8, uint16 and uint32.
    public init(ny: Int, nx: Int, channels: Int, rowOffsets: [Int], channelIndex: [UInt16], counts: [UInt32],
                dataType: FormatoDataType = .uint32, shape: [Int]? = nil) throws {
        let pixels = ny.multipliedReportingOverflow(by: nx)
        guard ny >= 0, nx >= 0, channels > 0, !pixels.overflow, rowOffsets.count == pixels.partialValue + 1,
              rowOffsets.first == 0, rowOffsets.last == counts.count, channelIndex.count == counts.count else {
            throw EDSReadError(.damaged, "The spectrum image's pixel table does not describe its \(counts.count) counts for \(ny) x \(nx) pixels.")
        }
        for (a, b) in zip(rowOffsets, rowOffsets.dropFirst()) where b < a {
            throw EDSReadError(.damaged, "The spectrum image's pixel table runs backwards (offset \(b) after \(a)).")
        }
        if let wide = channelIndex.first(where: { Int($0) >= channels }) {
            throw EDSReadError(.damaged, "The spectrum image has a count in channel \(wide), beyond its \(channels) channels.")
        }
        guard [.uint8, .uint16, .uint32].contains(dataType) else {
            throw EDSReadError(.unsupportedType, "A spectrum image's counts are uint8, uint16 or uint32, not \(dataType.rawValue).")
        }
        let layout = shape ?? [ny, nx, channels]
        let lead = (try? FormatoArray.elementCount(Array(layout.dropLast()))) ?? -1
        guard layout.count >= 2, layout.last == channels, lead == pixels.partialValue else {
            throw EDSReadError(.damaged, "A spectrum image of \(ny) x \(nx) pixels and \(channels) channels does not have the shape \(layout).")
        }
        self.ny = ny; self.nx = nx; self.channels = channels
        self.rowOffsets = rowOffsets; self.channelIndex = channelIndex; self.counts = counts
        self.dataType = dataType; self.shape = layout
    }

    private static let blockPixels = 4096

    /// One pixel's spectrum (`channels` counts).
    public func spectrum(pixel p: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: channels)
        for k in rowOffsets[p]..<rowOffsets[p + 1] { out[Int(channelIndex[k])] = counts[k] }
        return out
    }

    /// The total count of every pixel, row-major.
    public func pixelTotals() -> [Int64] {
        (0..<(ny * nx)).map { p in
            var s: Int64 = 0
            for k in rowOffsets[p]..<rowOffsets[p + 1] { s += Int64(counts[k]) }
            return s
        }
    }

    /// The summed spectrum over the pixels `mask` keeps (row-major `y * nx + x`, true = in; nil, every pixel).
    public func sum(mask: [Bool]?) -> [UInt64] {
        // The closure never answers true, so the throwing core cannot throw; the zeros are never returned.
        (try? sum(mask: mask, cancelled: { false }, progress: nil)) ?? [UInt64](repeating: 0, count: channels)
    }

    /// The same sum, cancellable: `cancelled` is asked once per block of pixels and `FormatoCancelled` thrown with nothing kept;
    /// `progress` is monotone in 0...1 and ends at 1. A mask of the wrong length is a programming error (masks are made from
    /// ny and nx), not file data.
    public func sum(mask: [Bool]?, cancelled: @Sendable () -> Bool, progress: (@Sendable (Double) -> Void)?) throws -> [UInt64] {
        precondition(mask.map { $0.count == ny * nx } ?? true, "mask length must be ny*nx")
        var out = [UInt64](repeating: 0, count: channels)
        let n = ny * nx
        for start in stride(from: 0, to: n, by: Self.blockPixels) {
            try FormatoCancellation.check(cancelled)
            let end = min(start + Self.blockPixels, n)
            for p in start..<end where mask?[p] ?? true {
                for k in rowOffsets[p]..<rowOffsets[p + 1] { out[Int(channelIndex[k])] &+= UInt64(counts[k]) }
            }
            progress?(Double(end) / Double(n))
        }
        if n == 0 { progress?(1) }
        return out
    }

    /// For every channel range, the per-pixel exact sum of counts inside it (outer index = range, inner = pixel, row-major).
    /// Ranges are half-open and may overlap.
    public func windowSums(_ ranges: [Range<Int>]) -> [[UInt64]] {
        // Never cancelled, so the throwing core cannot throw; the empty answer is never returned.
        (try? windowSums(ranges, cancelled: { false }, progress: nil)) ?? []
    }

    /// The same sums, cancellable as `sum(mask:cancelled:progress:)`.
    public func windowSums(_ ranges: [Range<Int>], cancelled: @Sendable () -> Bool,
                           progress: (@Sendable (Double) -> Void)?) throws -> [[UInt64]] {
        let n = ny * nx
        var out = [[UInt64]](repeating: [UInt64](repeating: 0, count: n), count: ranges.count)
        let los = ranges.map(\.lowerBound), his = ranges.map(\.upperBound)
        let maxHi = his.max() ?? 0
        for start in stride(from: 0, to: n, by: Self.blockPixels) {
            try FormatoCancellation.check(cancelled)
            let end = min(start + Self.blockPixels, n)
            for p in start..<end {
                for k in rowOffsets[p]..<rowOffsets[p + 1] {
                    let c = Int(channelIndex[k])
                    if c >= maxHi { break }
                    let v = UInt64(counts[k])
                    for r in 0..<ranges.count where c >= los[r] && c < his[r] { out[r][p] &+= v }
                }
            }
            progress?(Double(end) / Double(n))
        }
        if n == 0 { progress?(1) }
        return out
    }

    /// The dense counts of the hyperslab `[start, start + count)` of `shape`, in C order, little-endian, in `dataType`: the
    /// absent channels are 0. A count above the data type's largest value is refused (`EDSReadError.Reason.countAboveType`),
    /// never wrapped. The calling task's cancellation is asked every few hundred pixels (`FormatoCancelled`).
    public func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.validateSlab(start: start, count: count, shape: shape)
        let size = dataType.byteSize
        let total = try FormatoArray.elementCount(count)
        let rank = shape.count
        let firstChannel = start[rank - 1], channelCount = count[rank - 1]
        let largest: UInt32 = dataType == .uint8 ? 0xFF : dataType == .uint16 ? 0xFFFF : .max
        var out = Data(count: total * size)
        var above: (pixel: Int, channel: Int, count: UInt32)?
        try out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            var slot = 0
            try FormatoArray.forEachContiguousRun(start: Array(start.dropLast()), count: Array(count.dropLast()),
                                                  shape: Array(shape.dropLast()), cancelled: FormatoCancellation.task) { first, length in
                guard above == nil else { return }
                for p in first..<(first + length) {
                    let base = slot * channelCount
                    slot += 1
                    for k in rowOffsets[p]..<rowOffsets[p + 1] {
                        let c = Int(channelIndex[k]) - firstChannel
                        if c < 0 { continue }
                        if c >= channelCount { break }
                        let v = counts[k]
                        guard v <= largest else { above = (p, c + firstChannel, v); return }
                        let o = (base + c) * size
                        for b in 0..<size { dst[o + b] = UInt8(truncatingIfNeeded: v >> (8 * b)) }
                    }
                }
            }
        }
        if let above {
            throw EDSReadError(.countAboveType, "The spectrum image holds a count of \(above.count) in channel \(above.channel) of pixel \(above.pixel), above the largest \(dataType.rawValue).")
        }
        return try FormatoArray(dataType: dataType, shape: count, bytes: out)
    }
}

/// Builds an `EDSSparseSpectrumImage` pixel by pixel in row-major order.
package nonisolated struct EDSSparseSpectrumImageBuilder {
    package let ny: Int
    package let nx: Int
    package let channels: Int
    private var rowOffsets: [Int]
    private var channelIndex: [UInt16] = []
    private var counts: [UInt32] = []

    /// A builder for `ny` x `nx` pixels of `channels` channels; more pixels than `EDSFile.largestArray` (or a product that
    /// overflows) is refused before the row offsets are reserved.
    package init(ny: Int, nx: Int, channels: Int) throws {
        let pixels = ny.multipliedReportingOverflow(by: nx)
        guard ny >= 0, nx >= 0, !pixels.overflow, pixels.partialValue <= EDSFile.largestArray, channels > 0,
              channels <= Int(UInt16.max) + 1 else {
            throw EDSReadError(.size, "A spectrum image of \(ny) x \(nx) pixels and \(channels) channels is not one the readers hold.")
        }
        self.ny = ny; self.nx = nx; self.channels = channels
        rowOffsets = [0]
        rowOffsets.reserveCapacity(pixels.partialValue + 1)
    }

    /// The next pixel's spectrum (`channels` counts).
    package mutating func append(spectrum: UnsafeBufferPointer<UInt32>) {
        for c in 0..<channels where spectrum[c] != 0 {
            channelIndex.append(UInt16(c)); counts.append(spectrum[c])
        }
        rowOffsets.append(counts.count)
    }

    /// The next pixel's nonzero entries, channels ascending.
    package mutating func append(channels cs: some Sequence<UInt16>, counts vs: some Sequence<UInt32>) {
        channelIndex.append(contentsOf: cs); counts.append(contentsOf: vs)
        rowOffsets.append(counts.count)
    }

    /// Empty pixels up to the end of the image, then the image, checked whole (`EDSSparseSpectrumImage.init`) with the data
    /// type and shape RosettaSciIO gives it: more pixels than the image holds, or a channel past its last, is refused.
    package mutating func finish(dataType: FormatoDataType = .uint32, shape: [Int]? = nil) throws -> EDSSparseSpectrumImage {
        guard rowOffsets.count <= ny * nx + 1 else {
            throw EDSReadError(.damaged, "The spectrum image holds \(rowOffsets.count - 1) pixels, more than its \(ny) x \(nx).")
        }
        while rowOffsets.count < ny * nx + 1 { rowOffsets.append(counts.count) }
        return try EDSSparseSpectrumImage(ny: ny, nx: nx, channels: channels, rowOffsets: rowOffsets, channelIndex: channelIndex,
                                          counts: counts, dataType: dataType, shape: shape)
    }
}
