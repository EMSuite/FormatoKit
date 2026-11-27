//
//  EDSFile.swift
//  Role: what a SEM-EDS file holds once read (Bruker `.bcf`/`.spx`, EDAX `.spd`/`.lsd`/`.spc`, JEOL `.pts`/`.eds`/`.img`/`.map`/`.asw`):
//        its signals in the order RosettaSciIO 0.15.0 returns them (spectrum images, single spectra, images) as FormatoCore
//        signals, each with its axes as rsciio states them (name, size, scale, offset, units, navigate), the data type rsciio
//        gives the data, and the metadata fields the readers map, under rsciio's keys. A spectrum image's array is an
//        `EDSSparseSpectrumImage` (its counts by pixel, its dense slabs on demand); a spectrum's and an image's are in memory.
//        The counts are exact integers; nothing here computes a number.
//        `EDSReader.read` picks the vendor's reader by extension. Parity: Tests/FormatoEDSTests against the m7/read-* reference
//        bundles of Electron Microscopy Studio's tools/parity/sem (emit.py, RosettaSciIO 0.15.0).
//        Moved from Electron Microscopy Studio's Sources/TEMSEM/EDS/SEMEDSFile.swift (at f1eaafc) by FormatoKit#148: the
//        app's own signal, axis and metadata types became FormatoCore's; the reads, bounds and sentences are unchanged.
//

import Foundation
import FormatoCore

/// What one signal of an `EDSFile` is.
public nonisolated enum EDSSignalKind: Sendable, Equatable {
    /// A spectrum image: its array is an `EDSSparseSpectrumImage`, the last axis the energy.
    case spectrumImage
    /// One spectrum: one energy axis.
    case spectrum
    /// One image (an SE, BSE or HAADF image recorded with the map, a JEOL image or element map): [height, width], row 0 first.
    case image
}

/// A read file: its signals in rsciio's order, and what it opened without.
public nonisolated struct EDSFile: Sendable {
    public let url: URL
    public let signals: [FormatoLazySignal]
    /// A sentence for each companion beside the file that is there but could not be read (a sandboxed consumer is given the
    /// picked file only): it is left out as a missing one is, and said here. Empty when nothing was left out.
    public let notes: [String]

    public init(url: URL, signals: [FormatoLazySignal], notes: [String] = []) {
        self.url = url
        self.signals = signals
        self.notes = notes
    }

    /// What `signal` is: a spectrum image when its array is an `EDSSparseSpectrumImage`, a spectrum when it has one axis, else
    /// an image.
    public static func kind(of signal: FormatoLazySignal) -> EDSSignalKind {
        if signal.array is EDSSparseSpectrumImage { return .spectrumImage }
        return signal.axes.count == 1 ? .spectrum : .image
    }

    /// The sparse counts of a spectrum image's signal; nil for a spectrum or an image.
    public static func counts(of signal: FormatoLazySignal) -> EDSSparseSpectrumImage? { signal.array as? EDSSparseSpectrumImage }

    public var spectrumImages: [FormatoLazySignal] { signals.filter { Self.kind(of: $0) == .spectrumImage } }
    public var spectra: [FormatoLazySignal] { signals.filter { Self.kind(of: $0) == .spectrum } }
    public var images: [FormatoLazySignal] { signals.filter { Self.kind(of: $0) == .image } }
}

extension EDSFile {
    /// The most items a reader allocates for one array from the sizes a header states, where the file itself does not bound
    /// them (2^28: the row offsets of a 16384 x 16384 map, 2 GB). Real maps hold a few million pixels.
    package static let largestArray = 1 << 28

    /// The number of items `dims` describe, checked before a reader allocates for them: the product must not overflow, and
    /// that many items of `bytesPerItem` bytes must fit in the `fileLength` bytes the file holds for them. A header that
    /// promises more than its file holds is refused with the file's name.
    package static func checkedCount(dims: [Int], bytesPerItem: Int, fileLength: Int, name: String) throws -> Int {
        let stated = dims.map { String($0) }.joined(separator: " x ")
        var count = 1
        for d in dims {
            let next = count.multipliedReportingOverflow(by: d)
            guard d >= 0, !next.overflow else { throw EDSReadError(.size, "\(name) states \(stated) values, which no file holds.") }
            count = next.partialValue
        }
        let bytes = count.multipliedReportingOverflow(by: bytesPerItem)
        guard !bytes.overflow, bytes.partialValue <= fileLength else {
            throw EDSReadError(.size, "\(name) states \(stated) values of \(bytesPerItem) bytes, more than the \(fileLength) bytes it holds for them.")
        }
        return count
    }
}

/// The one door to the three vendors' readers.
public nonisolated enum EDSReader {
    /// Every extension the three readers read, lowercased.
    public static let readableExtensions = BrukerEDSReader.readableExtensions + EDAXEDSReader.readableExtensions
        + JEOLEDSReader.readableExtensions

    /// The file read by its vendor's reader, chosen by extension (case-insensitive). Whole-file work: run it off the main actor.
    /// A JEOL `.pts` (or the `.asw` naming it) reports `progress` 0...1 after each sweep of its event stream and stops with
    /// `CancellationError` when the calling task is cancelled; the Bruker and EDAX readers report nothing.
    public static func read(url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> EDSFile {
        switch url.pathExtension.lowercased() {
        case let e where BrukerEDSReader.readableExtensions.contains(e): return try BrukerEDSReader.read(url: url)
        case let e where EDAXEDSReader.readableExtensions.contains(e): return try EDAXEDSReader.read(url: url)
        case let e where JEOLEDSReader.readableExtensions.contains(e): return try JEOLEDSReader.read(url: url, progress: progress)
        default: throw EDSReadError(.notThisFormat, "\(url.lastPathComponent) is not a Bruker, EDAX or JEOL EDS file.")
        }
    }
}

// MARK: - The metadata

/// The metadata fields the readers map from a signal, under rsciio's names (`General`, `Signal`, `Acquisition_instrument.<mode>`,
/// its `Detector.EDS` and `Stage`, `Sample`); nil (or an absent list) where rsciio writes nothing. The readers fill it and write
/// it into the signal's `FormatoMetadata` (`metadata(file:source:rule:)`); `init(_:)` reads it back from there.
public nonisolated struct EDSMetadata: Equatable, Sendable {
    public var originalFilename: String?
    public var title: String?
    public var date: String?
    public var time: String?
    public var signalType: String?
    /// "SEM" or "TEM", the key of `Acquisition_instrument` (rsciio guesses it from the beam energy: above 30 kV is TEM).
    public var mode: String?
    /// kV.
    public var beamEnergy: Double?
    public var magnification: Double?
    /// Degrees.
    public var azimuthAngle: Double?
    public var elevationAngle: Double?
    /// eV.
    public var energyResolutionMnKa: Double?
    /// Seconds.
    public var liveTime: Double?
    public var realTime: Double?
    public var detectorType: String?
    /// Degrees.
    public var tiltAlpha: Double?
    public var sampleName: String?
    public var elements: [String]?
    public var xrayLines: [String]?

    public init() {}

    /// The entry that names the mode: its value is the key under `Acquisition_instrument` ("SEM" or "TEM") that holds the
    /// instrument's fields.
    public static let modeKey = "Acquisition_instrument"

    /// The instrument's keys under `mode`, in the order the readers write them.
    private static func instrument(_ mode: String) -> (beam: String, magnification: String, azimuth: String, elevation: String,
                                                     resolution: String, live: String, real: String, detector: String, tilt: String) {
        let i = modeKey + "." + mode, eds = i + ".Detector.EDS"
        return (i + ".beam_energy", i + ".magnification", eds + ".azimuth_angle", eds + ".elevation_angle",
                eds + ".energy_resolution_MnKa", eds + ".live_time", eds + ".real_time", eds + ".detector_type", i + ".Stage.tilt_alpha")
    }

    /// The fields as FormatoCore metadata under rsciio's keys, present only where set, each with `file`, `source` and `rule` as
    /// its provenance. The instrument's fields are written under the mode, which every reader sets with them.
    package func metadata(file: String, source: String, rule: String) -> FormatoMetadata {
        var out = FormatoMetadata()
        let provenance = FormatoProvenance(file: file, source: source, rule: rule)
        func put(_ key: String, _ value: FormatoValue?, _ units: String? = nil) {
            if let value { out.set(FormatoMetadataEntry(key: key, value: value, units: units, provenance: provenance)) }
        }
        put("General.original_filename", originalFilename.map { .text($0) })
        put("General.title", title.map { .text($0) })
        put("General.date", date.map { .text($0) })
        put("General.time", time.map { .text($0) })
        put("Signal.signal_type", signalType.map { .text($0) })
        if let mode {
            let k = Self.instrument(mode)
            put(Self.modeKey, .text(mode))
            put(k.beam, beamEnergy.map { .number($0) }, "kV")
            put(k.magnification, magnification.map { .number($0) })
            put(k.azimuth, azimuthAngle.map { .number($0) }, "°")
            put(k.elevation, elevationAngle.map { .number($0) }, "°")
            put(k.resolution, energyResolutionMnKa.map { .number($0) }, "eV")
            put(k.live, liveTime.map { .number($0) }, "s")
            put(k.real, realTime.map { .number($0) }, "s")
            put(k.detector, detectorType.map { .text($0) })
            put(k.tilt, tiltAlpha.map { .number($0) }, "°")
        }
        put("Sample.name", sampleName.map { .text($0) })
        put("Sample.elements", elements.map { .texts($0) })
        put("Sample.xray_lines", xrayLines.map { .texts($0) })
        return out
    }

    /// The fields a reader wrote into `metadata`.
    public init(_ metadata: FormatoMetadata) {
        originalFilename = metadata["General.original_filename"]?.value.text
        title = metadata["General.title"]?.value.text
        date = metadata["General.date"]?.value.text
        time = metadata["General.time"]?.value.text
        signalType = metadata["Signal.signal_type"]?.value.text
        sampleName = metadata["Sample.name"]?.value.text
        elements = metadata["Sample.elements"]?.value.texts
        xrayLines = metadata["Sample.xray_lines"]?.value.texts
        guard let mode = metadata[Self.modeKey]?.value.text else { return }
        let k = Self.instrument(mode)
        self.mode = mode
        beamEnergy = metadata[k.beam]?.value.number
        magnification = metadata[k.magnification]?.value.number
        azimuthAngle = metadata[k.azimuth]?.value.number
        elevationAngle = metadata[k.elevation]?.value.number
        energyResolutionMnKa = metadata[k.resolution]?.value.number
        liveTime = metadata[k.live]?.value.number
        realTime = metadata[k.real]?.value.number
        detectorType = metadata[k.detector]?.value.text
        tiltAlpha = metadata[k.tilt]?.value.number
    }
}

// MARK: - The signals the readers build

/// One axis as rsciio states it: the physical value at index i is offset + i · scale, in `units` (nil when the file states no
/// unit, as rsciio leaves it, which FormatoCore writes as "").
package nonisolated struct EDSAxis: Equatable, Sendable {
    package var name: String
    package var size: Int
    package var scale: Double
    package var offset: Double
    package var units: String?

    package init(name: String, size: Int, scale: Double, offset: Double, units: String?) {
        self.name = name; self.size = size; self.scale = scale; self.offset = offset; self.units = units
    }

    /// The FormatoCore axis: `navigate` as rsciio sets it (the spatial axes of a spectrum image navigate; an image's and a
    /// spectrum's axes are its signal).
    package func formato(navigate: Bool) -> FormatoAxis {
        FormatoAxis(name: name, size: size, scale: scale, offset: offset, units: units ?? "", navigate: navigate)
    }
}

/// Where a reader's metadata came from, for the provenance of its entries.
package nonisolated struct EDSSource: Sendable {
    package var file: String
    package var source: String
    package var rule: String
}

package nonisolated enum EDSSignals {
    /// A spectrum image: `axes` as rsciio returns them, the energy last; `cube` already in rsciio's data type and shape.
    package static func spectrumImage(axes: [EDSAxis], cube: EDSSparseSpectrumImage, metadata md: EDSMetadata,
                                      from s: EDSSource) -> FormatoLazySignal {
        FormatoLazySignal(title: md.title ?? "", signalType: md.signalType ?? "",
                          axes: axes.enumerated().map { $0.element.formato(navigate: $0.offset < axes.count - 1) },
                          metadata: md.metadata(file: s.file, source: s.source, rule: s.rule), array: cube)
    }

    /// One spectrum: its counts, little-endian in `dataType` (int32, uint32 or uint64, as rsciio names them).
    package static func spectrum(axis: EDSAxis, dataType: FormatoDataType, bytes: Data, metadata md: EDSMetadata,
                                 from s: EDSSource) throws -> FormatoLazySignal {
        let array = try FormatoArray(dataType: dataType, shape: [axis.size], bytes: bytes)
        return FormatoLazySignal(title: md.title ?? "", signalType: md.signalType ?? "", axes: [axis.formato(navigate: false)],
                                 metadata: md.metadata(file: s.file, source: s.source, rule: s.rule), array: FormatoInMemoryArray(array))
    }

    /// One image, row-major, row 0 first: `pixels` (height · width) written in `dataType` (uint8, uint16 or uint32), each value
    /// already within it.
    package static func image(axes: [EDSAxis], dataType: FormatoDataType, width: Int, height: Int, pixels: [UInt32],
                              metadata md: EDSMetadata, from s: EDSSource) throws -> FormatoLazySignal {
        let size = dataType.byteSize
        var bytes = Data(count: pixels.count * size)
        bytes.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            for (i, v) in pixels.enumerated() {
                for b in 0..<size { dst[i * size + b] = UInt8(truncatingIfNeeded: v >> (8 * b)) }
            }
        }
        let array = try FormatoArray(dataType: dataType, shape: [height, width], bytes: bytes)
        return FormatoLazySignal(title: md.title ?? "", signalType: md.signalType ?? "", axes: axes.map { $0.formato(navigate: false) },
                                 metadata: md.metadata(file: s.file, source: s.source, rule: s.rule), array: FormatoInMemoryArray(array))
    }

    /// `values` as little-endian bytes of `T`.
    package static func bytes<T: FixedWidthInteger>(_ values: [T]) -> Data {
        var out = Data(capacity: values.count * MemoryLayout<T>.size)
        for v in values { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        return out
    }
}

// MARK: - Little-endian reads

/// Little-endian reads from a byte array, bounds-checked (a short file is a refusal, never a crash).
package nonisolated struct EDSBytes {
    package let bytes: [UInt8]
    package let name: String

    package init(_ bytes: [UInt8], name: String) { self.bytes = bytes; self.name = name }

    package func need(_ offset: Int, _ count: Int) throws {
        guard offset >= 0, count >= 0, offset + count <= bytes.count else {
            throw EDSReadError(.truncated, "\(name) ends before its header says it does (byte \(offset + count) of \(bytes.count)).")
        }
    }

    package func u8(_ o: Int) throws -> UInt8 { try need(o, 1); return bytes[o] }
    package func i8(_ o: Int) throws -> Int8 { Int8(bitPattern: try u8(o)) }
    package func u16(_ o: Int) throws -> UInt16 { try need(o, 2); return UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8 }
    package func i16(_ o: Int) throws -> Int16 { Int16(bitPattern: try u16(o)) }
    package func u32(_ o: Int) throws -> UInt32 {
        try need(o, 4)
        return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
    }
    package func i32(_ o: Int) throws -> Int32 { Int32(bitPattern: try u32(o)) }
    package func u64(_ o: Int) throws -> UInt64 { UInt64(try u32(o)) | UInt64(try u32(o + 4)) << 32 }
    package func f32(_ o: Int) throws -> Float { Float(bitPattern: try u32(o)) }
    package func f64(_ o: Int) throws -> Double { Double(bitPattern: try u64(o)) }
    package func slice(_ o: Int, _ n: Int) throws -> ArraySlice<UInt8> { try need(o, n); return bytes[o..<(o + n)] }
}

package nonisolated enum EDSText {
    /// A NUL-padded byte field as Python's `bytes.rstrip(b"\x00")` then UTF-8, Shift-JIS when it is not UTF-8 (rsciio's JEOL `_decode`).
    package static func decode(_ field: some Collection<UInt8>, stripLeading: Bool = false) -> String {
        var b = Array(field)
        while let last = b.last, last == 0 { b.removeLast() }
        if stripLeading { while let first = b.first, first == 0 { b.removeFirst() } }
        if let s = String(bytes: b, encoding: .utf8) { return s }
        if let s = String(bytes: b, encoding: .shiftJIS) { return s }
        return String(decoding: b, as: UTF8.self)
    }

    /// An OLE automation date (days since 1899-12-30, as JEOL writes it) as rsciio's `date` and `time` ISO strings; the time keeps its
    /// microseconds when it has any, as Python's `time.isoformat()` does. A damaged field (not a number, infinite, or more
    /// microseconds than an Int64 holds, about 290 000 years) is refused; rsciio raises on each of these too.
    package static func oleDate(_ days: Double, file: String) throws -> (date: String, time: String) {
        // Python: datetime(1899, 12, 30) + timedelta(days=d), timedelta rounds to whole microseconds (round half even).
        let micros = (days * 86_400_000_000).rounded(.toNearestOrEven)
        guard var totalMicros = Int64(exactly: micros) else {
            throw EDSReadError(.number, "\(file) states its date as \(days) days after 1899-12-30, which is no date.")
        }
        var dayNumber = totalMicros / 86_400_000_000
        totalMicros -= dayNumber * 86_400_000_000
        if totalMicros < 0 { totalMicros += 86_400_000_000; dayNumber -= 1 }
        // 1899-12-30 is Julian day number 2415019.
        let (y, m, d) = civil(fromJulianDay: 2_415_019 + Int(dayNumber))
        let second = totalMicros / 1_000_000, us = totalMicros % 1_000_000
        let date = String(format: "%04d-%02d-%02d", y, m, d)
        var time = String(format: "%02d:%02d:%02d", Int(second / 3600), Int(second / 60 % 60), Int(second % 60))
        if us != 0 { time += String(format: ".%06d", Int(us)) }
        return (date, time)
    }

    /// Gregorian (year, month, day) of a Julian day number (Fliegel and Van Flandern, 1968).
    static func civil(fromJulianDay jd: Int) -> (Int, Int, Int) {
        var l = jd + 68569
        let n = 4 * l / 146097
        l -= (146097 * n + 3) / 4
        let i = 4000 * (l + 1) / 1461001
        l = l - 1461 * i / 4 + 31
        let j = 80 * l / 2447
        let d = l - 2447 * j / 80
        l = j / 11
        let m = j + 2 - 12 * l
        let y = 100 * (n - 49) + i + l
        return (y, m, d)
    }

    /// Bruker's "d.m.yyyy" and "h:m:s" as ISO date and time (rsciio: `strptime("%d.%m.%Y %H:%M:%S")`, then `isoformat()`).
    package static func brukerDateTime(date: String, time: String) -> (date: String, time: String)? {
        let d = date.trimmingCharacters(in: .whitespaces).split(separator: ".").compactMap { Int($0) }
        let t = time.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count == 3 else { return nil }
        return (String(format: "%04d-%02d-%02d", d[2], d[1], d[0]), String(format: "%02d:%02d:%02d", t[0], t[1], t[2]))
    }
}

