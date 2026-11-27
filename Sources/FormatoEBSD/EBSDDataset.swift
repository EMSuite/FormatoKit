//
//  EBSDDataset.swift
//  Moved from Electron Microscopy Studio's Sources/TEMSEM (at 7b09bf5) by FormatoKit#147.
//  Role: what an EBSD or TKD pattern file holds, the one value every pattern reader fills: the scan grid and its step, the pattern
//        shape and element type, the detector geometry with its projection centres in the Bruker convention (kikuchipy's internal
//        one), the static background the file carries, the SEM header, the file's own orientation map as plain columns when it has
//        one (`EBSDMapColumns`), and where the patterns are (`EBSDPatternSource`: an HDF5 dataset or fixed-size records of a vendor's
//        binary file) so they are read by map position on demand (`EBSDPatternReader`, also a `FormatoLazyArray`, and
//        `EBSDDataset.signal()`). The header numbers a reader sizes and indexes by pass `ReaderNumber`, and `EBSDDataset.validated()`
//        refuses a scan or pattern size no reader can lay out, so a broken or hostile header is refused in words. A record file is
//        mapped only on a local volume and checked before every read, so a volume that goes away is a sentence, not a crash;
//        elsewhere it is read through its handle, each read in an autorelease pool of its own, so a pass holds a row, not the scan.
//        Ported from kikuchipy 0.13.1 (`kikuchipy/io/plugins/_h5ebsd.py`, `detectors/_ebsd_detector.py`; GPL-3.0-or-later, see
//        NOTICE); the parity rows are in docs/parity.md.
//

import Foundation
import FormatoCore
import FormatoHDF5

/// The layouts the readers know.
public nonisolated enum EBSDFileFormat: String, Sendable, Equatable {
    case kikuchipyH5EBSD = "kikuchipy h5ebsd"
    case brukerH5EBSD = "Bruker h5ebsd"
    case edaxH5EBSD = "EDAX h5ebsd"
    case oxfordH5OINA = "Oxford H5OINA"
    /// Oxford Instruments' binary pattern file (`.ebsp`).
    case oxfordBinary = "Oxford ebsp"
    /// EDAX TSL's binary pattern file (`.up1`, `.up2`).
    case edaxBinary = "EDAX up1/up2"
    /// NORDIF `Pattern.dat` with `Setting.txt` beside it (`NORDIFOpening`).
    case nordif = "NORDIF"
    /// Patterns a consumer made in memory (a demo dataset): not data, never read from a file.
    case generated = "generated demo (not data)"
}

/// The detector as kikuchipy's `EBSDDetector` holds it after reading: shape, pixel size, binning, the three tilts and the sample
/// tilt in degrees, and the projection centres converted to the Bruker convention (x right, y DOWN, both as a fraction of the
/// pattern width and height, z as a fraction of the pattern height).
public nonisolated struct EBSDDetectorGeometry: Sendable, Equatable {
    public var rows: Int
    public var columns: Int
    /// Detector pixel size in µm (1 where the file states none).
    public var pixelSize: Double
    public var binning: Int
    /// Detector elevation (tilt), azimuthal and twist angles in degrees.
    public var tilt: Double
    public var azimuthal: Double
    public var twist: Double
    public var sampleTilt: Double
    /// One centre for the whole scan, or one per map position in row-major scan order.
    public var projectionCenters: [SIMD3<Double>]
    /// The values the file did not state and the reader took as kikuchipy's defaults: a result made with them looks calibrated when
    /// it is not, so a consumer says "assumed" beside them. Nothing is refused.
    public var assumed: Set<Assumed> = []

    /// A detector value a reader assumed.
    public enum Assumed: String, Sendable, Equatable, Hashable, CaseIterable, Comparable {
        case projectionCenter, pixelSize, sampleTilt

        /// "projection centre", "detector pixel size", "sample tilt".
        public var title: String {
            switch self {
            case .projectionCenter: "projection centre"
            case .pixelSize: "detector pixel size"
            case .sampleTilt: "sample tilt"
            }
        }

        public static func < (a: Assumed, b: Assumed) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    }

    /// The assumed values in a fixed order, as words ("projection centre, sample tilt"); nil when every value came from the file.
    public var assumedText: String? { assumed.isEmpty ? nil : assumed.sorted().map(\.title).joined(separator: ", ") }

    public init(rows: Int, columns: Int, pixelSize: Double = 1, binning: Int = 1, tilt: Double = 0, azimuthal: Double = 0, twist: Double = 0,
                sampleTilt: Double = 70, projectionCenters: [SIMD3<Double>], assumed: Set<Assumed> = []) {
        self.rows = rows; self.columns = columns; self.pixelSize = pixelSize; self.binning = binning
        self.tilt = tilt; self.azimuthal = azimuthal; self.twist = twist; self.sampleTilt = sampleTilt
        self.projectionCenters = projectionCenters
        self.assumed = assumed
    }

    /// Columns over rows, kikuchipy's `aspect_ratio`.
    public var aspectRatio: Double { Double(columns) / Double(rows) }

    /// The projection-centre conventions the files write, named as kikuchipy names them.
    public enum Convention: String, Sendable, Equatable { case bruker, tsl, oxford, emsoft4, emsoft5 }

    /// `pc` written in `convention`, converted to the Bruker convention (`EBSDDetector._get_pc_in_bruker_convention`).
    public func brukerCenter(_ pc: SIMD3<Double>, from convention: Convention) -> SIMD3<Double> {
        switch convention {
        case .bruker: return pc
        case .tsl: return SIMD3(pc.x, 1 - pc.y, pc.z * (Double(min(rows, columns)) / Double(rows)))
        case .oxford: return SIMD3(pc.x, 1 - pc.y * aspectRatio, pc.z * aspectRatio)
        case .emsoft4, .emsoft5:
            let pcx = convention == .emsoft4 ? -pc.x : pc.x
            let b = Double(binning)
            return SIMD3(0.5 - pcx / (Double(columns) * b), 0.5 - pc.y / (Double(rows) * b), pc.z / (Double(rows) * b * pixelSize))
        }
    }

    /// A Bruker-convention centre in `convention` (`EBSDDetector._get_pc_in_convention`).
    public func center(_ pc: SIMD3<Double>, in convention: Convention) -> SIMD3<Double> {
        switch convention {
        case .bruker: return pc
        case .tsl: return SIMD3(pc.x, 1 - pc.y, pc.z / (Double(min(rows, columns)) / Double(rows)))
        case .oxford: return SIMD3(pc.x, (1 - pc.y) / aspectRatio, pc.z / aspectRatio)
        case .emsoft4, .emsoft5:
            let b = Double(binning)
            var x = (0.5 - pc.x) * Double(columns) * b
            if convention == .emsoft4 { x = -x }
            return SIMD3(x, (0.5 - pc.y) * Double(rows) * b, pc.z * Double(rows) * b * pixelSize)
        }
    }
}

/// The SEM header the file carries beside the patterns.
public nonisolated struct EBSDSEMHeader: Sendable, Equatable {
    public var beamEnergyKeV: Double?
    public var magnification: Double?
    public var workingDistanceMM: Double?
    public var microscope: String?

    public init(beamEnergyKeV: Double? = nil, magnification: Double? = nil, workingDistanceMM: Double? = nil, microscope: String? = nil) {
        self.beamEnergyKeV = beamEnergyKeV; self.magnification = magnification; self.workingDistanceMM = workingDistanceMM; self.microscope = microscope
    }
}

/// Where a scan's patterns are in the file, and the order they are read in: `fileIndexByPosition[k]` is the index in the dataset of
/// the pattern at map position k (row-major), nil for a missing pattern (a file shorter than its scan is zero-padded, as
/// kikuchipy pads it); nil as a whole means the file order is the map order.
public nonisolated struct EBSDPatternSource: Sendable, Equatable {
    /// How the file lays its patterns out.
    public enum Layout: Sendable, Equatable {
        /// An HDF5 dataset of shape `fileShape`.
        case hdf5(datasetPath: String)
        /// Fixed-size records from byte `offset`, `recordBytes` each, the pattern's pixels (little-endian, row-major) `patternOffset`
        /// bytes into its record: EDAX `.up1`/`.up2` (records are bare patterns) and Oxford `.ebsp` (a header and a footer around each).
        case records(offset: Int, recordBytes: Int, patternOffset: Int)
    }

    public var url: URL
    public var layout: Layout
    /// The dataset's shape as stored: (n, rows, columns) or (scanRows, scanColumns, rows, columns).
    public var fileShape: [Int]
    public var dataType: FormatoDataType
    public var fileIndexByPosition: [Int?]?

    public init(url: URL, layout: Layout, fileShape: [Int], dataType: FormatoDataType, fileIndexByPosition: [Int?]? = nil) {
        self.url = url; self.layout = layout; self.fileShape = fileShape; self.dataType = dataType; self.fileIndexByPosition = fileIndexByPosition
    }

    /// An HDF5 dataset at `datasetPath`.
    public init(url: URL, datasetPath: String, fileShape: [Int], dataType: FormatoDataType, fileIndexByPosition: [Int?]? = nil) {
        self.init(url: url, layout: .hdf5(datasetPath: datasetPath), fileShape: fileShape, dataType: dataType, fileIndexByPosition: fileIndexByPosition)
    }

    /// The HDF5 dataset's path; empty for a record file.
    public var datasetPath: String {
        if case .hdf5(let path) = layout { return path }
        return ""
    }

    /// Patterns the dataset holds.
    public var fileCount: Int { fileShape.count == 4 ? fileShape[0] * fileShape[1] : fileShape[0] }
}

/// One scan of an EBSD or TKD pattern file.
public nonisolated struct EBSDDataset: Sendable, Equatable {
    public var format: EBSDFileFormat
    /// The file's own words, lowercased as kikuchipy keeps them (`manufacturer`, `version` of the top group).
    public var manufacturer: String
    public var version: String
    /// The scan group read, and every scan group the file holds.
    public var scanGroup: String
    public var scanGroups: [String]
    public var scanRows: Int
    public var scanColumns: Int
    public var patternRows: Int
    public var patternColumns: Int
    public var dataType: FormatoDataType
    /// Scan step along y (rows) and x (columns), in `scanUnit` (µm in every layout; 1 where the file states none).
    public var stepY: Double
    public var stepX: Double
    public var scanUnit: String
    public var detector: EBSDDetectorGeometry
    /// The static background pattern, as stored (uint8 or uint16, `patternRows` x `patternColumns`), when the file carries one.
    public var staticBackground: FormatoArray?
    public var sem: EBSDSEMHeader
    /// The orientation map the file holds beside its patterns, as plain columns (`EBSDMapColumns`); nil when it holds none or it
    /// did not read.
    public var map: EBSDMapColumns?
    public var patterns: EBSDPatternSource
    /// What the reader left out and why (a companion map that did not fit, a vendor warning), one sentence each.
    public var notes: [String]

    public init(format: EBSDFileFormat, manufacturer: String, version: String, scanGroup: String, scanGroups: [String], scanRows: Int, scanColumns: Int,
                patternRows: Int, patternColumns: Int, dataType: FormatoDataType, stepY: Double, stepX: Double, scanUnit: String = "um",
                detector: EBSDDetectorGeometry, staticBackground: FormatoArray? = nil, sem: EBSDSEMHeader = EBSDSEMHeader(),
                map: EBSDMapColumns? = nil, patterns: EBSDPatternSource, notes: [String] = []) {
        self.format = format; self.manufacturer = manufacturer; self.version = version; self.scanGroup = scanGroup; self.scanGroups = scanGroups
        self.scanRows = scanRows; self.scanColumns = scanColumns; self.patternRows = patternRows; self.patternColumns = patternColumns
        self.dataType = dataType; self.stepY = stepY; self.stepX = stepX; self.scanUnit = scanUnit; self.detector = detector
        self.staticBackground = staticBackground; self.sem = sem; self.map = map; self.patterns = patterns; self.notes = notes
    }

    public var patternCount: Int { scanRows * scanColumns }
    public var patternPixels: Int { patternRows * patternColumns }

    /// Why a scan of `scanRows` x `scanColumns` positions of `patternRows` x `patternColumns` patterns of `byteSize` bytes a pixel
    /// cannot be read, in one sentence; nil when it can: every side at least 1 and the whole scan's bytes countable in an Int, so
    /// no count or offset sized by them traps.
    public static func sizeRefusal(scanRows: Int, scanColumns: Int, patternRows: Int, patternColumns: Int, byteSize: Int) -> String? {
        guard scanRows >= 1, scanColumns >= 1 else {
            return "its scan is \(scanRows) x \(scanColumns) positions; a scan needs at least one row and one column."
        }
        guard patternRows >= 1, patternColumns >= 1 else {
            return "its patterns are \(patternRows) x \(patternColumns) pixels; a pattern needs at least one row and one column."
        }
        guard ReaderNumber.product([scanRows, scanColumns, patternRows, patternColumns, byteSize]) != nil else {
            return "its \(scanRows) x \(scanColumns) scan of \(patternRows) x \(patternColumns) patterns is more bytes than can be counted."
        }
        return nil
    }

    /// This dataset when its scan and pattern sizes can be read (`sizeRefusal`), else a refusal that names the file. A consumer
    /// passes every reader's dataset through here before a pattern reader or a map is sized by it.
    public func validated() throws -> EBSDDataset {
        if let refusal = Self.sizeRefusal(scanRows: scanRows, scanColumns: scanColumns, patternRows: patternRows, patternColumns: patternColumns,
                                          byteSize: dataType.byteSize) {
            throw EBSDReadError(.size, "\(patterns.url.lastPathComponent): \(refusal)")
        }
        return self
    }

    /// Every pattern in map order as one array of shape (scanRows, scanColumns, patternRows, patternColumns), zero where the file has
    /// none. One slab read of the dataset, then the reorder.
    public func allPatterns() throws -> FormatoArray {
        let reader = try EBSDPatternReader(self)
        return try reader.allPatterns()
    }

    /// The patterns as one lazy signal of shape (scanRows, scanColumns, patternRows, patternColumns), read by map position through
    /// an `EBSDPatternReader` (kikuchipy's axes: `y` and `x` in the scan unit with the steps, `dy` and `dx` in px), with the header
    /// facts as metadata. Opens the pattern file; nothing is read until a slab is asked for.
    public func signal() throws -> FormatoLazySignal {
        let reader = try EBSDPatternReader(self)
        let axes = [
            FormatoAxis(name: "y", size: scanRows, scale: stepY, offset: 0, units: scanUnit, navigate: true),
            FormatoAxis(name: "x", size: scanColumns, scale: stepX, offset: 0, units: scanUnit, navigate: true),
            FormatoAxis(name: "dy", size: patternRows, scale: 1, offset: 0, units: "px", navigate: false),
            FormatoAxis(name: "dx", size: patternColumns, scale: 1, offset: 0, units: "px", navigate: false),
        ]
        let file = patterns.url.lastPathComponent
        func entry(_ key: String, _ value: FormatoValue, units: String? = nil, source: String) -> FormatoMetadataEntry {
            FormatoMetadataEntry(key: key, value: value, units: units,
                                 provenance: FormatoProvenance(file: file, source: source, rule: "kikuchipy 0.13.1 reader, as read"))
        }
        var metadata = FormatoMetadata([
            entry("General.title", .text(file), source: "file name"),
            entry("Signal.signal_type", .text("EBSD"), source: "file format \(format.rawValue)"),
        ])
        if !manufacturer.isEmpty { metadata.set(entry("Acquisition_instrument.SEM.Detector.EBSD.manufacturer", .text(manufacturer), source: "manufacturer")) }
        if !version.isEmpty { metadata.set(entry("Acquisition_instrument.SEM.Detector.EBSD.version", .text(version), source: "version")) }
        if let kv = sem.beamEnergyKeV { metadata.set(entry("Acquisition_instrument.SEM.beam_energy", .number(kv), units: "kV", source: "SEM header")) }
        if let mag = sem.magnification { metadata.set(entry("Acquisition_instrument.SEM.magnification", .number(mag), source: "SEM header")) }
        if let wd = sem.workingDistanceMM { metadata.set(entry("Acquisition_instrument.SEM.working_distance", .number(wd), units: "mm", source: "SEM header")) }
        if let microscope = sem.microscope { metadata.set(entry("Acquisition_instrument.SEM.microscope", .text(microscope), source: "SEM header")) }
        return FormatoLazySignal(title: file, signalType: "EBSD", axes: axes, metadata: metadata, array: reader)
    }
}

/// Reads patterns of one dataset by map position; holds the HDF5 dataset open (or the record file, `RecordFile`) between calls (a
/// live pattern pane asks per cursor move). As a `FormatoLazyArray` it is the scan of shape (scanRows, scanColumns, patternRows,
/// patternColumns), read pattern by pattern.
public nonisolated final class EBSDPatternReader: @unchecked Sendable {
    public let dataset: EBSDDataset

    /// How a record file is held. A mapped page whose volume has gone (a network share that dropped, a disk pulled out) or whose file
    /// was cut short faults when it is touched, a SIGBUS that ends the process without a dialog; a read through a file handle fails
    /// with an error instead. Either way the bytes are the same.
    public enum RecordStrategy: Sendable, Equatable {
        /// Mapped, pages coming in as patterns are read; before every read a descriptor opened with the file is asked whether the file
        /// is still there, at least as long as when it was opened.
        case mapped
        /// Read record by record through a held file handle.
        case read
    }

    /// Mapped on a local volume; read on any other, or when the volume does not say (as `DM4Reader.readingOptions` maps on local
    /// volumes only, for the same fault).
    public static func recordStrategy(volumeIsLocal: Bool?) -> RecordStrategy {
        volumeIsLocal == true ? .mapped : .read
    }

    private enum Store {
        case hdf5(HDF5SlabReader)
        case records(RecordFile, offset: Int, recordBytes: Int, patternOffset: Int)
    }
    private let store: Store

    /// A record file is held as `strategy` says, or when nil as its volume says (`recordStrategy(volumeIsLocal:)`).
    public init(_ dataset: EBSDDataset, strategy: RecordStrategy? = nil) throws {
        self.dataset = dataset
        let source = dataset.patterns
        switch source.layout {
        case .hdf5(let path):
            do { store = .hdf5(try HDF5SlabReader(url: source.url, path: path)) } catch { throw EBSDReadError.wrap(error, file: source.url) }
        case .records(let offset, let recordBytes, let patternOffset):
            let volumeIsLocal = try? source.url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
            let file = try RecordFile(url: source.url, strategy: strategy ?? EBSDPatternReader.recordStrategy(volumeIsLocal: volumeIsLocal))
            let bytesPerPattern = dataset.patternPixels * dataset.dataType.byteSize
            // The records' span overflow-checked, and compared with what follows the offset, so neither side can overflow.
            let span = ReaderNumber.product([source.fileCount, recordBytes]) ?? Int.max
            guard recordBytes >= patternOffset + bytesPerPattern, offset >= 0, offset <= file.size, span <= file.size - offset else {
                throw EBSDReadError(.truncated, "\(source.url.lastPathComponent) is shorter than its \(source.fileCount) patterns need (\(file.size) bytes).")
            }
            store = .records(file, offset: offset, recordBytes: recordBytes, patternOffset: patternOffset)
        }
    }

    /// The pattern at map position (row, column), shape (patternRows, patternColumns), as stored; zero where the file has none.
    public func pattern(row: Int, column: Int) throws -> FormatoArray {
        guard row >= 0, row < dataset.scanRows, column >= 0, column < dataset.scanColumns else {
            throw EBSDReadError(.position, "Position (\(row), \(column)) is outside the \(dataset.scanRows) x \(dataset.scanColumns) scan.")
        }
        let position = row * dataset.scanColumns + column
        let index: Int?
        if let order = dataset.patterns.fileIndexByPosition { index = position < order.count ? order[position] : nil }
        else { index = position < dataset.patterns.fileCount ? position : nil }
        let shape = [dataset.patternRows, dataset.patternColumns]
        guard let index else {
            return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: Data(count: dataset.patternPixels * dataset.dataType.byteSize))
        }
        return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: bytes(fileIndex: index))
    }

    /// One scan row of patterns, shape (scanColumns, patternRows, patternColumns), in map order: one slab when the file order is the
    /// map order and the row is inside the file; else pattern by pattern (a Bruker region of interest, a file shorter than its scan).
    public func row(_ row: Int) throws -> FormatoArray {
        guard row >= 0, row < dataset.scanRows else {
            throw EBSDReadError(.position, "Row \(row) is outside the \(dataset.scanRows) x \(dataset.scanColumns) scan.")
        }
        let columns = dataset.scanColumns
        let shape = [columns, dataset.patternRows, dataset.patternColumns]
        let source = dataset.patterns
        let first = row * columns
        if source.fileIndexByPosition == nil, first + columns <= source.fileCount {
            let slab = try rowSlab(row: row)
            return try FormatoArray(dataType: slab.dataType, shape: shape, bytes: slab.bytes)
        }
        var bytes = Data()
        bytes.reserveCapacity(columns * dataset.patternPixels * dataset.dataType.byteSize)
        for column in 0..<columns {
            let one = try pattern(row: row, column: column)
            bytes.append(one.bytes)
        }
        return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: bytes)
    }

    /// See `EBSDDataset.allPatterns`.
    public func allPatterns() throws -> FormatoArray {
        let source = dataset.patterns
        let bytesPerPattern = dataset.patternPixels * dataset.dataType.byteSize
        let total = dataset.patternCount
        let shape = [dataset.scanRows, dataset.scanColumns, dataset.patternRows, dataset.patternColumns]
        let fileCount = source.fileCount
        let whole: Data
        switch store {
        case .hdf5(let slabs):
            do { whole = try slabs.read(start: [Int](repeating: 0, count: source.fileShape.count), count: source.fileShape).bytes }
            catch { throw EBSDReadError.wrap(error, file: source.url) }
        case .records(_, _, let recordBytes, _):
            if recordBytes == bytesPerPattern, source.fileIndexByPosition == nil, fileCount == total {
                return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: bytes(fileIndex: 0, count: total))
            }
            var out = Data(count: total * bytesPerPattern)
            for position in 0..<total {
                let index: Int?
                if let order = source.fileIndexByPosition { index = position < order.count ? order[position] : nil }
                else { index = position < fileCount ? position : nil }
                guard let index, index < fileCount else { continue }
                out.replaceSubrange((position * bytesPerPattern)..<((position + 1) * bytesPerPattern), with: try bytes(fileIndex: index))
            }
            return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: out)
        }
        if source.fileIndexByPosition == nil, fileCount == total {
            return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: whole)
        }
        guard whole.count >= fileCount * bytesPerPattern else {
            throw EBSDReadError(.truncated, "\(source.url.lastPathComponent) holds \(whole.count) bytes of patterns where its header names "
                + "\(fileCount) patterns of \(bytesPerPattern) bytes.")
        }
        var out = Data(count: total * bytesPerPattern)
        whole.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                // Nil only for zero bytes, when there is nothing to copy.
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                for position in 0..<total {
                    let index: Int?
                    if let order = source.fileIndexByPosition { index = position < order.count ? order[position] : nil }
                    else { index = position < fileCount ? position : nil }
                    guard let index, index < fileCount else { continue }
                    let from = srcBase.advanced(by: index * bytesPerPattern)
                    dstBase.advanced(by: position * bytesPerPattern).copyMemory(from: from, byteCount: bytesPerPattern)
                }
            }
        }
        return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: out)
    }

    /// One scan row as the file stores it (the file order is the map order: `row(_:)` checks that), as one slab read (one slice or one
    /// read of the record file for bare-pattern records, record by record otherwise).
    func rowSlab(row: Int) throws -> FormatoArray {
        let columns = dataset.scanColumns
        let shape = [columns, dataset.patternRows, dataset.patternColumns]
        switch store {
        case .hdf5(let slabs):
            let fileShape = dataset.patterns.fileShape
            let start: [Int], count: [Int]
            if fileShape.count == 4 {
                start = [row, 0, 0, 0]; count = [1, columns, fileShape[2], fileShape[3]]
            } else {
                start = [row * columns, 0, 0]; count = [columns, fileShape[1], fileShape[2]]
            }
            do { return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: try slabs.read(start: start, count: count).bytes) }
            catch { throw EBSDReadError.wrap(error, file: dataset.patterns.url) }
        case .records(_, _, let recordBytes, _):
            let bytesPerPattern = dataset.patternPixels * dataset.dataType.byteSize
            if recordBytes == bytesPerPattern {
                return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: bytes(fileIndex: row * columns, count: columns))
            }
            var out = Data()
            out.reserveCapacity(columns * bytesPerPattern)
            for column in 0..<columns { out.append(try bytes(fileIndex: row * columns + column)) }
            return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: out)
        }
    }

    /// The stored bytes of `count` patterns from file index `fileIndex` on: one slab for HDF5, the record's pixels for a record file
    /// (`count` records in one slice when the records are bare patterns).
    private func bytes(fileIndex: Int, count: Int = 1) throws -> Data {
        let bytesPerPattern = dataset.patternPixels * dataset.dataType.byteSize
        switch store {
        case .hdf5(let slabs):
            let fileShape = dataset.patterns.fileShape
            let start: [Int], extent: [Int]
            if fileShape.count == 4 {
                start = [fileIndex / fileShape[1], fileIndex % fileShape[1], 0, 0]; extent = [1, count, fileShape[2], fileShape[3]]
            } else {
                start = [fileIndex, 0, 0]; extent = [count, fileShape[1], fileShape[2]]
            }
            do { return try slabs.read(start: start, count: extent).bytes } catch { throw EBSDReadError.wrap(error, file: dataset.patterns.url) }
        case .records(let file, let offset, let recordBytes, let patternOffset):
            let first = offset + fileIndex * recordBytes + patternOffset
            let length = recordBytes == bytesPerPattern ? count * bytesPerPattern : bytesPerPattern
            return try file.bytes(from: first, count: length)
        }
    }
}

extension EBSDPatternReader: FormatoLazyArray {
    public var dataType: FormatoDataType { dataset.dataType }
    public var shape: [Int] { [dataset.scanRows, dataset.scanColumns, dataset.patternRows, dataset.patternColumns] }

    /// The slab `[start, start + count)` of the scan, read pattern by pattern (a whole scan row at once where the slab holds whole
    /// rows of whole patterns), never more than the patterns it covers.
    public func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.validateSlab(start: start, count: count, shape: shape)
        let wholePatterns = start[2] == 0 && start[3] == 0 && count[2] == dataset.patternRows && count[3] == dataset.patternColumns
        let wholeRows = wholePatterns && start[1] == 0 && count[1] == dataset.scanColumns
        var out = Data()
        for r in start[0]..<(start[0] + count[0]) {
            if wholeRows {
                out.append(try row(r).bytes)
                continue
            }
            for c in start[1]..<(start[1] + count[1]) {
                let one = try pattern(row: r, column: c)
                out.append(wholePatterns ? one.bytes : try one.slab(start: [start[2], start[3]], count: [count[2], count[3]]).bytes)
            }
        }
        return try FormatoArray(dataType: dataset.dataType, shape: count, bytes: out)
    }
}

/// A record file's bytes, held as `EBSDPatternReader.RecordStrategy` says. Mapped: a descriptor is opened before the file is mapped and
/// kept, and before every read it must still answer (`fstat`) with at least the size the file was opened at; a volume that has gone
/// (the descriptor fails) or a file cut short is refused in words, and the mapping is never touched. Read: each read seeks the held
/// handle and reads, under a lock (the handle has one offset) and in an autorelease pool of its own, and a short or failed read is
/// refused the same way.
private nonisolated final class RecordFile: @unchecked Sendable {
    let url: URL
    /// The file's size in bytes when it was opened; every read stays inside it.
    let size: Int
    private let handle: FileHandle
    /// The mapping (`.mapped`), nil when records are read through `handle` (`.read`).
    private let mapping: Data?
    private let lock = NSLock()

    init(url: URL, strategy: EBSDPatternReader.RecordStrategy) throws {
        let handle: FileHandle, mapping: Data?, size: Int
        do {
            handle = try FileHandle(forReadingFrom: url)
            switch strategy {
            case .mapped:
                let data = try Data(contentsOf: url, options: .alwaysMapped)
                mapping = data
                size = data.count
            case .read:
                mapping = nil
                size = Int(try handle.seekToEnd())
            }
        } catch {
            throw EBSDReadError(.unreadable, "\(url.lastPathComponent) could not be read: \((error as NSError).localizedDescription)")
        }
        self.url = url; self.handle = handle; self.mapping = mapping; self.size = size
    }

    deinit { try? handle.close() }

    /// `count` bytes from byte `start` of the file.
    func bytes(from start: Int, count: Int) throws -> Data {
        guard let mapping else { return try read(from: start, count: count) }
        guard isStillThere else { throw gone }
        guard start >= 0, count >= 0, start <= mapping.count, count <= mapping.count - start else {
            throw EBSDReadError(.truncated, "\(url.lastPathComponent) ends before byte \(start) + \(count); the file is truncated.")
        }
        return mapping.subdata(in: (mapping.startIndex + start)..<(mapping.startIndex + start + count))
    }

    /// Whether the descriptor opened with the file still answers, with at least the opened size: false once the volume has gone
    /// (`fstat` fails on a descriptor whose disk was pulled or whose share dropped) or the file was cut short (a mapped page past the
    /// new end faults). A file that grew still is: reads stay inside the opened size.
    private var isStillThere: Bool {
        var info = stat()
        return fstat(handle.fileDescriptor, &info) == 0 && info.st_size >= off_t(size)
    }

    private var gone: EBSDReadError { EBSDReadError(.gone, "\(url.lastPathComponent) is no longer available.") }

    private func read(from start: Int, count: Int) throws -> Data {
        guard start >= 0, count >= 0 else { throw gone }
        // The handle hands its bytes back autoreleased, and a pass reads every row of a scan in one call that drains no pool. In a
        // pool of its own, a row's bytes go when the caller lets go of them, not when the whole pass ends.
        let data = lock.withLock { () -> Data? in
            autoreleasepool { () -> Data? in
                do {
                    try handle.seek(toOffset: UInt64(start))
                    return try handle.read(upToCount: count) ?? Data()
                } catch {
                    return nil
                }
            }
        }
        guard let data, data.count == count else { throw gone }
        return data
    }
}

/// The numbers a reader takes from a file's header, checked before anything is counted, sized or indexed by them: where Swift's
/// `Int(_:)` or `*` would trap on a broken or hostile header, these answer nil and the reader refuses the file in words.
public nonisolated enum ReaderNumber {
    /// A count or index the file stores as a float, as the whole number Python's `int()` makes of it (truncated toward zero), so a
    /// value that converts gives the same number as before; nil for NaN and infinity (where `int()` raises) and for a value beyond
    /// Int's range (where `Int(_:)` traps).
    public static func int(_ value: Double) -> Int? {
        Int(exactly: value.rounded(.towardZero))
    }

    /// The product of `factors` (1 for none), nil when it overflows an Int.
    public static func product(_ factors: [Int]) -> Int? {
        var total = 1
        for factor in factors {
            let (next, overflow) = total.multipliedReportingOverflow(by: factor)
            if overflow { return nil }
            total = next
        }
        return total
    }
}
