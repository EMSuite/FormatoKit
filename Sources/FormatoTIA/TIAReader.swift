//
//  TIAReader.swift
//  A TIA .ser file as RosettaSciIO 049e7d70 `tia/_api.py` `ser_reader(filename, objects=None)` reads it: the series header
//  (offset array of 4 bytes up to SeriesVersion 528, 8 bytes after), the dimension array, one element per valid data offset,
//  each element a calibration header and its array (a spectrum of ArrayLength values, or an image of SizeY rows of SizeX
//  values) followed by its tag (time, and the stage position when TagTypeID is 0x4142).
//
//  Shape and axes, as `ser_reader`: one navigation axis per header dimension (for an image series, a dimension of size 1 is
//  dropped; spatial navigation axes named y then x, in F order when the first two elements share a y position), then the
//  signal axes: Energy in eV for a spectrum, y and x for an image (offset = calibration offset − element × delta, units
//  metres without the .emi; with it, TIAEMI.swift). Metres become nm by the scale only and 1/metres "1 / nm" (the offsets stay as stored: RosettaSciIO's
//  behaviour, kept). A 1D series whose valid count is below its total keeps only the valid elements (`onlyValidData`), and
//  a single valid element drops the navigation axis; a map stopped early is filled with NaN (floats) or 0 after the last
//  valid element. Each image is flipped vertically (`dc[..., ::-1, :]`).
//
//  Values are read on demand, one image row or one spectrum at a time; nothing past the headers is read at open.
//

import Foundation
import FormatoCore

/// One entry of a series header's dimension array.
public nonisolated struct TIADimension: Sendable, Equatable {
    public let size: Int
    public let calibrationOffset: Double
    public let calibrationDelta: Double
    public let calibrationElement: Int
    public let description: String
    /// The units as stored ("meters", "1/meters", ...); empty when the stored length is 0.
    public let units: String
}

/// The series header of a .ser file.
public nonisolated struct TIASeriesHeader: Sendable, Equatable {
    /// 0x0210 (528) or below: 4-byte offsets; above: 8-byte offsets.
    public let seriesVersion: Int
    /// 0x4120 (16672) for spectra, 0x4122 (16674) for images.
    public let dataTypeID: Int
    /// 0x4142 (16706): each element's tag carries the stage position; 0x4152 (16722): time only.
    public let tagTypeID: Int
    public let totalElements: Int
    public let validElements: Int
    public let offsetArrayOffset: Int
    public let dimensions: [TIADimension]

    /// The series holds spectra (RosettaSciIO's `guess_record_by`: 16672 is spectra, anything else images).
    public var isSpectrum: Bool { dataTypeID == 16672 }
}

/// Reads TIA .ser files.
public nonisolated enum TIAReader {
    static let spectrumID = 16672
    static let positionTagID = 16706

    /// The series header of the .ser file at `url` (no element is read).
    /// - Throws: ``TIAError`` for a file that is not a .ser series or ends inside its header; `FormatoReadError` when it
    ///   cannot be opened.
    public static func header(url: URL) throws -> TIASeriesHeader {
        try SERFile(url: url).header
    }

    /// The series of the .ser file at `url` as one lazy signal, read as RosettaSciIO reads a .ser alone.
    /// - Parameter onlyValidData: RosettaSciIO's `only_valid_data` (default true): a 1D series stopped early keeps only its
    ///   valid elements; false keeps the requested size, filled after the last valid element.
    /// - Throws: ``TIAError``, `FormatoReadError.unsupportedDataType` for complex values, `FormatoReadError.cannotOpen`.
    public static func read(url: URL, onlyValidData: Bool = true) throws -> FormatoLazySignal {
        try read(url: url, onlyValidData: onlyValidData, imageUnits: { _ in "meters" })
    }

    /// `ser_reader` with the units of an image's signal axes chosen from its header (`_guess_units_from_mode` when an .emi is
    /// read; "meters" otherwise).
    static func read(url: URL, onlyValidData: Bool, imageUnits: (TIASeriesHeader) -> String) throws -> FormatoLazySignal {
        let file = try SERFile(url: url)
        let h = file.header
        let name = formatoDisplayFileName(url.path)
        guard h.validElements > 0 else { throw TIAError.noValidData }
        guard h.validElements <= h.totalElements else {
            throw TIAError.inconsistent("\(h.validElements) valid elements of \(h.totalElements)")
        }
        let offsets = try file.elementOffsets()
        let element = try file.element(at: offsets[0], spectrum: h.isSpectrum)
        guard element.count > 0 else { throw TIAError.inconsistent("an element of no values") }
        // Every valid element must lie inside the file (its array and, when it carries positions, its tag).
        let tagBytes = h.tagTypeID == positionTagID ? 24 : 8
        for offset in offsets {
            let (end, o) = offset.addingReportingOverflow(element.headerBytes + element.arrayBytes)
            guard !o, offset >= 0, end <= file.count else { throw TIAError.truncated("element at byte \(offset)") }
        }

        // F order when the first two elements share a y position (`data["PositionY"][0] == data["PositionY"][1]`).
        var orderF = false
        if h.tagTypeID == positionTagID, offsets.count > 1 {
            let y0 = try file.tagPositionY(elementEnd: offsets[0] + element.headerBytes + element.arrayBytes, tagBytes: tagBytes)
            let y1 = try file.tagPositionY(elementEnd: offsets[1] + element.headerBytes + element.arrayBytes, tagBytes: tagBytes)
            orderF = y0 == y1
        }

        let ndim = h.dimensions.count
        guard ndim > 0 else { throw TIAError.noDimensions }
        var axes: [FormatoAxis] = []
        var shape: [Int?] = Array(repeating: nil, count: ndim)
        var spatial = ["x", "y"].prefix(ndim).map { $0 }
        for i in 0..<ndim {
            let idim = orderF ? ndim - i : 1 + i
            let d = h.dimensions[idim - 1]
            guard h.isSpectrum || h.dimensions[i].size != 1 else { continue }
            let units = d.units
            let name: String? = units == "meters" ? spatial.popLast() : nil
            axes.append(FormatoAxis(name: name, size: d.size, scale: d.calibrationDelta, offset: d.calibrationOffset, units: units,
                                    navigate: true))
            shape[i] = d.size
        }
        if ndim == 1, h.totalElements != h.validElements, onlyValidData {
            if h.validElements == 1 {
                shape = []
                axes = []
            } else {
                guard let first = axes.first else {
                    throw TIAError.inconsistent("a series stopped early with no navigation axis")
                }
                shape[0] = h.validElements
                axes[0] = FormatoAxis(name: first.name, size: h.validElements, scale: first.scale, offset: first.offset,
                                      units: first.units, navigate: true)
            }
        }

        // The signal axes.
        if h.isSpectrum {
            axes.append(FormatoAxis(name: "Energy", size: element.length, scale: element.deltaX, offset: element.offsetX, units: "eV",
                                    navigate: false))
            shape.append(element.length)
        } else {
            let offsetY = element.offsetY - Double(element.elementY) * element.deltaY
            let offsetX = element.offsetX - Double(element.elementX) * element.deltaX
            let units = imageUnits(h)
            axes.append(FormatoAxis(name: "y", size: element.rows, scale: element.deltaY, offset: offsetY, units: units, navigate: false))
            shape.append(element.rows)
            axes.append(FormatoAxis(name: "x", size: element.columns, scale: element.deltaX, offset: offsetX, units: units,
                                    navigate: false))
            shape.append(element.columns)
        }
        axes = axes.map { a in
            switch a.units {
            case "meters": FormatoAxis(name: a.name, size: a.size, scale: a.scale * 1e9, offset: a.offset, units: "nm", navigate: a.navigate)
            case "1/meters":
                FormatoAxis(name: a.name, size: a.size, scale: a.scale / 1e9, offset: a.offset, units: "1 / nm", navigate: a.navigate)
            default: a
            }
        }

        // `load_only_data`: the stored values laid end to end, each image flipped, reshaped to the shape; a map stopped early is
        // filled; size-1 dimensions are squeezed when the axes are fewer than the dimensions.
        var final = shape.compactMap { $0 }
        let perElement = element.count
        let stored = h.validElements
        var elements: Int
        do {
            let total = try FormatoArray.elementCount(final)
            guard total % perElement == 0 else {
                throw TIAError.inconsistent("\(total) values are not a whole number of \(perElement)-value elements")
            }
            elements = total / perElement
        }
        if elements != stored {
            if ndim == 1, onlyValidData {
                guard !final.isEmpty else { throw TIAError.inconsistent("no navigation dimension to shorten") }
                final[0] = stored
                elements = stored
                let values = try FormatoArray.elementCount(final)
                guard values == stored * perElement else {
                    throw TIAError.inconsistent("\(stored) valid elements do not fill the shape \(final)")
                }
            } else if stored > elements {
                throw TIAError.inconsistent("\(stored) valid elements, room for \(elements)")
            }
        }
        if axes.count != final.count {
            final = final.filter { $0 != 1 }
            guard axes.count == final.count else {
                throw TIAError.inconsistent("\(axes.count) axes for the shape \(final)")
            }
        }

        var metadata = FormatoMetadata()
        metadata.set(FormatoMetadataEntry(key: "General.original_filename", value: .text(name), units: nil,
            provenance: FormatoProvenance(file: name, source: "(the file name)", rule: "rsciio tia: os.path.split(filename)[1]")))
        metadata.set(FormatoMetadataEntry(key: "Signal.signal_type", value: .text(""), units: nil,
            provenance: FormatoProvenance(file: name, source: "(constant)", rule: "rsciio tia: signal_type is \"\"")))
        let array = TIAElementArray(path: url.path, dataType: element.dataType, shape: final,
                                    dataStarts: offsets.map { $0 + element.headerBytes }, elementCount: perElement,
                                    imageRows: h.isSpectrum ? nil : element.rows, columns: h.isSpectrum ? perElement : element.columns,
                                    elements: elements)
        return FormatoLazySignal(title: "", signalType: "", axes: axes, metadata: metadata, array: array)
    }

    static func dataType(code: Int) throws -> FormatoDataType {
        switch code {
        case 1: .uint8
        case 2: .uint16
        case 3: .uint32
        case 4: .int8
        case 5: .int16
        case 6: .int32
        case 7: .float32
        case 8: .float64
        case 9: throw FormatoReadError.unsupportedDataType("TIA complex64")
        case 10: throw FormatoReadError.unsupportedDataType("TIA complex128")
        default: throw TIAError.dataType(code)
        }
    }
}

/// The calibration header of a series' first element: RosettaSciIO reads every element with its layout.
nonisolated struct TIAElementHeader {
    let dataType: FormatoDataType
    let headerBytes: Int
    /// Spectrum: CalibrationOffset, CalibrationDelta, CalibrationElement; image: the X calibration.
    let offsetX: Double, deltaX: Double, elementX: Int
    let offsetY: Double, deltaY: Double, elementY: Int
    /// Spectrum: ArrayLength; image: SizeX.
    let length: Int
    /// Image: SizeY (1 for a spectrum).
    let height: Int

    var rows: Int { height }
    var columns: Int { length }
    var count: Int { length * height }
    var arrayBytes: Int { count * dataType.byteSize }
}

/// The bytes of a .ser file, mapped, with bounds-checked little-endian reads.
nonisolated struct SERFile {
    let data: Data
    let header: TIASeriesHeader
    var count: Int { data.count }

    init(url: URL) throws {
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch {
            throw FormatoReadError.cannotOpen(formatoDisplayFileName(url.path), error.localizedDescription)
        }
        guard data.count >= 30 else { throw TIAError.notTIA("\(data.count) bytes, shorter than a series header") }
        let byteOrder = try Self.u16(data, 0), seriesID = try Self.u16(data, 2)
        guard byteOrder == 0x4949, seriesID == 0x0197 else {
            throw TIAError.notTIA(String(format: "byte order 0x%04X, series id 0x%04X", byteOrder, seriesID))
        }
        let version = try Self.u16(data, 4)
        let wide = version > 528
        let offsetArray = try wide ? Self.u64(data, 22) : Self.u32(data, 22)
        let ndim = try Self.u32(data, wide ? 30 : 26)
        var at = wide ? 34 : 30
        var dims: [TIADimension] = []
        for _ in 0..<ndim {
            let size = try Self.u32(data, at)
            let calOffset = try Self.f64(data, at + 4), calDelta = try Self.f64(data, at + 12)
            let calElement = try Self.u32(data, at + 20)
            let descLength = try Self.u32(data, at + 24)
            let description = try Self.text(data, at + 28, descLength)
            let unitsAt = at + 28 + descLength
            let unitsLength = try Self.u32(data, unitsAt)
            let units = try Self.text(data, unitsAt + 4, unitsLength)
            at = unitsAt + 4 + unitsLength
            dims.append(TIADimension(size: size, calibrationOffset: calOffset, calibrationDelta: calDelta, calibrationElement: calElement,
                                     description: description, units: units))
        }
        header = TIASeriesHeader(seriesVersion: version, dataTypeID: try Self.u32(data, 6), tagTypeID: try Self.u32(data, 10),
                                 totalElements: try Self.u32(data, 14), validElements: try Self.u32(data, 18),
                                 offsetArrayOffset: offsetArray, dimensions: dims)
    }

    /// The data offsets of the valid elements.
    func elementOffsets() throws -> [Int] {
        let width = header.seriesVersion > 528 ? 8 : 4
        let (bytes, o1) = header.totalElements.multipliedReportingOverflow(by: width)
        let (end, o2) = header.offsetArrayOffset.addingReportingOverflow(bytes)
        guard !o1, !o2, end <= data.count else { throw TIAError.truncated("offset array") }
        return try (0..<header.validElements).map { i in
            let at = header.offsetArrayOffset + i * width
            return try width == 8 ? Self.u64(data, at) : Self.u32(data, at)
        }
    }

    func element(at offset: Int, spectrum: Bool) throws -> TIAElementHeader {
        let element = try layout(at: offset, spectrum: spectrum)
        let (values, o1) = element.length.multipliedReportingOverflow(by: element.height)
        let (bytes, o2) = values.multipliedReportingOverflow(by: element.dataType.byteSize)
        guard !o1, !o2, bytes <= data.count else { throw TIAError.truncated("element at byte \(offset)") }
        return element
    }

    private func layout(at offset: Int, spectrum: Bool) throws -> TIAElementHeader {
        if spectrum {
            let type = try TIAReader.dataType(code: try Self.u16(data, offset + 20))
            return TIAElementHeader(dataType: type, headerBytes: 26, offsetX: try Self.f64(data, offset), deltaX: try Self.f64(data, offset + 8),
                                    elementX: try Self.u32(data, offset + 16), offsetY: 0, deltaY: 0, elementY: 0,
                                    length: try Self.u32(data, offset + 22), height: 1)
        }
        let type = try TIAReader.dataType(code: try Self.u16(data, offset + 40))
        return TIAElementHeader(dataType: type, headerBytes: 50, offsetX: try Self.f64(data, offset), deltaX: try Self.f64(data, offset + 8),
                                elementX: try Self.u32(data, offset + 16), offsetY: try Self.f64(data, offset + 20),
                                deltaY: try Self.f64(data, offset + 28), elementY: try Self.u32(data, offset + 36),
                                length: try Self.u32(data, offset + 42), height: try Self.u32(data, offset + 46))
    }

    /// PositionY of the tag that follows an element's array (TagTypeID, Unknown, Time, PositionX, PositionY).
    func tagPositionY(elementEnd: Int, tagBytes: Int) throws -> Double {
        try Self.f64(data, elementEnd + 16)
    }

    private static func check(_ data: Data, _ at: Int, _ n: Int) throws {
        let (end, o) = at.addingReportingOverflow(n)
        guard at >= 0, !o, end <= data.count else { throw TIAError.truncated("header") }
    }

    static func u16(_ data: Data, _ at: Int) throws -> Int {
        try check(data, at, 2)
        let s = data.startIndex + at
        return Int(data[s]) | Int(data[s + 1]) << 8
    }

    static func u32(_ data: Data, _ at: Int) throws -> Int {
        try check(data, at, 4)
        let s = data.startIndex + at
        return Int(UInt32(data[s]) | UInt32(data[s + 1]) << 8 | UInt32(data[s + 2]) << 16 | UInt32(data[s + 3]) << 24)
    }

    static func u64(_ data: Data, _ at: Int) throws -> Int {
        try check(data, at, 8)
        let s = data.startIndex + at
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(data[s + k]) << (8 * UInt64(k)) }
        guard v <= UInt64(Int.max) else { throw TIAError.truncated("offset beyond any file") }
        return Int(v)
    }

    static func f64(_ data: Data, _ at: Int) throws -> Double {
        try check(data, at, 8)
        let s = data.startIndex + at
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(data[s + k]) << (8 * UInt64(k)) }
        return Double(bitPattern: v)
    }

    /// NumPy's fixed-length bytes: trailing NULs dropped, decoded as UTF-8 (Latin-1 if it is not).
    static func text(_ data: Data, _ at: Int, _ n: Int) throws -> String {
        try check(data, at, n)
        let s = data.startIndex + at
        var raw = [UInt8](data[s..<(s + n)])
        while raw.last == 0 { raw.removeLast() }
        return String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .isoLatin1) ?? ""
    }
}

/// The values of a series, read on demand: the elements laid end to end, each image flipped vertically, elements past the
/// last valid one filled (NaN for floats, 0 otherwise).
nonisolated struct TIAElementArray: FormatoLazyArray {
    let path: String
    let dataType: FormatoDataType
    let shape: [Int]
    /// The first byte of each valid element's array.
    let dataStarts: [Int]
    /// Values per element.
    let elementCount: Int
    /// Rows per image (nil for spectra).
    let imageRows: Int?
    /// Values per stored row (an image's width, a spectrum's length).
    let columns: Int
    /// Elements the shape holds (valid ones first).
    let elements: Int

    func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.validateSlab(start: start, count: count, shape: shape)
        let size = dataType.byteSize
        let total = try FormatoArray.elementCount(count) * size
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw FormatoReadError.cannotOpen(formatoDisplayFileName(path), String(cString: strerror(errno))) }
        defer { close(fd) }
        var out = Data(count: total)
        var failure: FormatoReadError?
        let fill: [UInt8] = switch dataType {
        case .float32: withUnsafeBytes(of: Float.nan.bitPattern.littleEndian) { Array($0) }
        case .float64: withUnsafeBytes(of: Double.nan.bitPattern.littleEndian) { Array($0) }
        default: [UInt8](repeating: 0, count: size)
        }
        try out.withUnsafeMutableBytes { dst in
            var written = 0
            try FormatoArray.forEachContiguousRun(start: start, count: count, shape: shape, cancelled: FormatoCancellation.task) { linear, length in
                var i = linear, remaining = length
                while remaining > 0, failure == nil {
                    let k = i / elementCount, j = i % elementCount
                    let segment: Int, source: Int
                    if let rows = imageRows {
                        let r = j / columns, c = j % columns
                        segment = min(remaining, columns - c)
                        source = ((rows - 1 - r) * columns + c) * size
                    } else {
                        segment = min(remaining, elementCount - j)
                        source = j * size
                    }
                    let want = segment * size
                    if k < dataStarts.count {
                        var done = 0
                        while done < want {
                            let n = pread(fd, dst.baseAddress! + written + done, want - done, off_t(dataStarts[k] + source + done))
                            if n <= 0 { failure = .truncated(formatoDisplayFileName(path)); return }
                            done += n
                        }
                    } else {
                        for v in 0..<segment {
                            for b in 0..<size { dst[written + v * size + b] = fill[b] }
                        }
                    }
                    written += want
                    i += segment
                    remaining -= segment
                }
            }
        }
        if let failure { throw failure }
        return try FormatoArray(dataType: dataType, shape: count, bytes: out)
    }
}
