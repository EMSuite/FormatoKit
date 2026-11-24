//
//  TIAEMI.swift
//  A TIA .emi file and its .ser files as RosettaSciIO 049e7d70 `tia/_api.py` `emi_reader` reads them and HyperSpy 2.5.0
//  maps them (pin T2, tools/tia/emi-pins.py):
//    - the .emi's metadata documents are the byte runs from each `<ObjectInfo>` to the next `</ObjectInfo>`
//      (`get_xml_info_from_emi`, which starts each search one byte after the last start), each read as XML through
//      `GuardedXML` (a document that breaks a bound refuses the file);
//    - its series are the files `<name>_<digit>.ser` beside it, in order (`glob(name + "_[0-9].ser")`, sorted); a series
//      that holds no valid data is skipped (RosettaSciIO's IOError); the k-th digit takes the k-th document's mapped
//      metadata (`index = digit − 1`, Python's index, so `_0.ser` takes the last), none when the .emi holds fewer;
//    - from the first document, for every series: the acquisition date and time (`AcquireDate`, as "Mon Feb 22 19:20:24
//      2016"), and the units of an image's signal axes (`_guess_units_from_mode`: "1/meters" in Diffraction mode, or in
//      STEM mode when the acquisition names a camera or the first dimension is a scan, else "meters"; "meters" when the
//      document has no Mode or no AcquireInfo);
//    - the metadata keys RosettaSciIO's `mapping` fills, matched as HyperSpy matches them (each key slugified, so the stored
//      "High tension_kV" answers `High_tension_kV`): beam energy, microscope, mode, camera length, magnification, the
//      camera's name and dwell time, the stage, and the user.
//  The values of `ExperimentalDescription` are as `parse_ExperimentalDescription` stores them: `label_unit` (or `label`
//  when the unit is empty), a number when there is a unit and the value reads as one (Python's `float`), else text.
//
//  Known limits, all on documents no public file has: an element with child elements and only whitespace before its first
//  child reads as a node (ElementTree keeps that whitespace as text; Foundation's tree drops it); an AcquireDate in any
//  other form than TIA's own gives no date or time (RosettaSciIO's `dateutil` reads many forms); an empty value with a
//  unit, or a mapped value of the wrong kind, gives no entry (RosettaSciIO or HyperSpy stops on it).
//

import Foundation
import FormatoCore

extension TIAReader {
    /// The series of the .emi file at `url`, one lazy signal per `<name>_<digit>.ser` beside it, each with the metadata the
    /// .emi gives it, as HyperSpy loads an .emi.
    /// - Parameter onlyValidData: as in `read(url:onlyValidData:)`.
    /// - Throws: ``TIAError/emi(_:)`` when the .emi holds no metadata document, a document cannot be read, or no series is
    ///   beside it; what `read(url:onlyValidData:)` throws for a series; `FormatoReadError.cannotOpen`.
    public static func readEMI(url: URL, onlyValidData: Bool = true) throws -> [FormatoLazySignal] {
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch {
            throw FormatoReadError.cannotOpen(formatoDisplayFileName(url.path), error.localizedDescription)
        }
        let objects = try EMIObjects.ranges(in: data)
        let series = try seriesFiles(beside: url)
        guard !series.isEmpty else {
            throw TIAError.emi("no \(url.deletingPathExtension().lastPathComponent)_<digit>.ser file beside it")
        }
        guard !objects.isEmpty else { throw TIAError.emi("no <ObjectInfo> document") }
        let first = try EMIObjectInfo(data[objects[0]])
        var signals: [FormatoLazySignal] = []
        for (digit, serURL) in series {
            let signal: FormatoLazySignal
            do {
                signal = try read(url: serURL, onlyValidData: onlyValidData, imageUnits: { first.imageUnits(header: $0) })
            } catch TIAError.noValidData {
                continue
            }
            let index = digit - 1 < 0 ? objects.count - 1 : digit - 1
            var own: EMIObjectInfo?
            if index == 0 { own = first } else if index < objects.count { own = try EMIObjectInfo(data[objects[index]]) }
            var metadata = signal.metadata
            let emiName = formatoDisplayFileName(url.path)
            if let stamp = first.dateAndTime {
                let (date, time) = stamp
                let source = "ObjectInfo[0].AcquireDate (\(first.acquireDate ?? ""))"
                metadata.set(FormatoMetadataEntry(key: "General.date", value: .text(date), units: nil,
                    provenance: FormatoProvenance(file: emiName, source: source, rule: "rsciio tia _get_date_time: date().isoformat()")))
                metadata.set(FormatoMetadataEntry(key: "General.time", value: .text(time), units: nil,
                    provenance: FormatoProvenance(file: emiName, source: source, rule: "rsciio tia _get_date_time: time().isoformat()")))
            }
            for entry in own?.mapped(file: emiName, index: index) ?? [] { metadata.set(entry) }
            signals.append(FormatoLazySignal(title: signal.title, signalType: signal.signalType, axes: signal.axes,
                                             metadata: metadata, array: signal.array))
        }
        return signals
    }

    /// The files `<name>_<digit>.ser` beside the .emi at `url`, by digit, as `glob(name + "_[0-9].ser")` sorted. Each of the ten
    /// names is probed by opening it, never by listing the folder: an open panel or a drop grants a sandboxed app the .emi
    /// alone, and the folder's listing (and `fileExists`, which answers false for a file the app cannot reach) would hide the
    /// .ser files beside it. A name that is there but cannot be opened refuses the .emi with the files named (#162).
    static func seriesFiles(beside url: URL) throws -> [(digit: Int, url: URL)] {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        var found: [(digit: Int, url: URL)] = []
        var unreadable: [String] = []
        for d in 0...9 {
            let candidate = directory.appendingPathComponent("\(stem)_\(d).ser")
            let fd = open(candidate.path, O_RDONLY | O_NONBLOCK)
            if fd >= 0 {
                close(fd)
                found.append((d, candidate))
            } else if errno != ENOENT {
                unreadable.append(candidate.lastPathComponent)
            }
        }
        guard unreadable.isEmpty else {
            throw TIAError.emi("its series \(unreadable.joined(separator: ", ")) beside it cannot be opened; "
                               + "give access to the folder that holds the .emi and its .ser files")
        }
        return found
    }
}

/// The byte ranges of an .emi's `<ObjectInfo>` documents.
nonisolated enum EMIObjects {
    static let open = Data("<ObjectInfo>".utf8)
    static let close = Data("</ObjectInfo>".utf8)

    /// `get_xml_info_from_emi`: each start searched from one byte past the last start (the first from byte 1), each end
    /// from its start; a start with no end refuses the file (RosettaSciIO would hand an empty document to the parser).
    static func ranges(in data: Data) throws -> [Range<Data.Index>] {
        var out: [Range<Data.Index>] = []
        var from = data.startIndex
        while true {
            from += 1
            guard from < data.endIndex, let start = data.range(of: open, in: from..<data.endIndex)?.lowerBound else { break }
            guard let end = data.range(of: close, in: start..<data.endIndex)?.upperBound else {
                throw TIAError.emi("an <ObjectInfo> with no </ObjectInfo>")
            }
            out.append(start..<end)
            from = start
        }
        return out
    }
}

/// One `<ObjectInfo>` document, as far as RosettaSciIO and HyperSpy read it.
nonisolated struct EMIObjectInfo {
    /// `ObjectInfo.AcquireDate` as stored.
    let acquireDate: String?
    /// `ExperimentalDescription`: each row under its HyperSpy slug; nil values (an empty `<Value>`) are left out.
    let description: [String: FormatoValue]
    /// `AcquireInfo`'s text children by HyperSpy slug, or nil when the document has no `AcquireInfo` node.
    let acquireInfo: [String: String]?

    init(_ bytes: Data) throws {
        guard let xml = String(data: bytes, encoding: .utf8) else { throw TIAError.emi("an <ObjectInfo> document that is not UTF-8") }
        guard let document = GuardedXML.document(xml), let root = document.rootElement() else {
            throw TIAError.emi("an <ObjectInfo> document that is not well formed or breaks a bound")
        }
        var date: String?
        var description: [String: FormatoValue] = [:]
        var info: [String: String]?
        for child in root.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch child.name {
            case "ExperimentalDescription":
                // `et.find("Root").findall("Data")`: the first Root child, its Data children in order.
                guard let rows = Self.firstChild(child, "Root") else { continue }
                for row in Self.children(rows, "Data") {
                    guard let label = Self.firstChild(row, "Label").flatMap(Self.text), let valueElement = Self.firstChild(row, "Value"),
                          let unitElement = Self.firstChild(row, "Unit") else { continue }
                    let unit = Self.text(unitElement)
                    let value = Self.text(valueElement)
                    let key = Self.slug(unit.map { label + "_" + $0 } ?? label)
                    if unit != nil {
                        guard let value else { continue }
                        description[key] = Self.pythonFloat(value).map(FormatoValue.number) ?? .text(value)
                    } else if let value {
                        description[key] = .text(value)
                    } else {
                        description[key] = nil
                    }
                }
            case "TrueImageHeaderInfo":
                continue
            case "AcquireDate":
                date = Self.text(child)
            case "AcquireInfo":
                if Self.text(child) != nil {
                    info = nil  // stored as text: not a node HyperSpy or RosettaSciIO can look into
                    continue
                }
                var values = info ?? [:]
                for field in child.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                    if let name = field.name, let text = Self.text(field) { values[Self.slug(name)] = text }
                }
                info = values
            default:
                continue
            }
        }
        acquireDate = date
        self.description = description
        acquireInfo = info
    }

    /// `_guess_units_from_mode` for an image series' signal axes.
    func imageUnits(header h: TIASeriesHeader) -> String {
        guard case .text(let mode)? = description["Mode"], let info = acquireInfo else { return "meters" }
        guard let first = h.dimensions.first else { return "meters" }
        let isCamera = info["CameraNamePath"] != nil
        let isImageStack = first.units.utf8.isEmpty
        let isDiffractionScan = first.size > 1 && !isImageStack
        if mode.contains("STEM") { return isCamera || isDiffractionScan ? "1/meters" : "meters" }
        return mode.contains("Diffraction") ? "1/meters" : "meters"
    }

    /// `_get_date_time` for TIA's own form, "Mon Feb 22 19:20:24 2016": ("2016-02-22", "19:20:24").
    var dateAndTime: (String, String)? {
        guard let parts = acquireDate?.split(whereSeparator: { $0 == " " || $0 == "\t" }), parts.count == 5 else { return nil }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        guard weekdays.contains(String(parts[0])), let m = months.firstIndex(of: String(parts[1])),
              parts[2].count <= 2, let day = Int(parts[2]), (1...31).contains(day),
              parts[4].count == 4, let year = Int(parts[4]) else { return nil }
        let hms = parts[3].split(separator: ":", omittingEmptySubsequences: false)
        guard hms.count == 3, hms.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let hh = Int(hms[0]), let mm = Int(hms[1]), let ss = Int(hms[2]), hh < 24, mm < 60, ss < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: m + 1, day: day)),
              calendar.component(.day, from: date) == day else { return nil }
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return ("\(year)-\(two(m + 1))-\(two(day))", "\(two(hh)):\(two(mm)):\(two(ss))")
    }

    /// RosettaSciIO's `mapping` for TIA, applied as HyperSpy applies it: a key whose value is absent, or of a kind its
    /// function cannot take, gives no entry.
    func mapped(file: String, index: Int) -> [FormatoMetadataEntry] {
        var out: [FormatoMetadataEntry] = []
        func add(_ key: String, _ value: FormatoValue?, units: String?, source: String, rule: String) {
            guard let value else { return }
            out.append(FormatoMetadataEntry(key: key, value: value, units: units,
                                            provenance: FormatoProvenance(file: file, source: "ObjectInfo[\(index)].\(source)", rule: rule)))
        }
        func number(_ slug: String, times factor: Double) -> FormatoValue? {
            guard case .number(let v)? = description[slug] else { return nil }
            return .number(v * factor)
        }
        let tem = "Acquisition_instrument.TEM."
        add(tem + "beam_energy", description["High_tension_kV"], units: "kV", source: "ExperimentalDescription.High tension_kV",
            rule: "rsciio tia mapping: as is")
        if case .text(let m)? = description["Microscope"] {
            add(tem + "microscope", .text(m.replacingOccurrences(of: "Microscope ", with: "")), units: nil,
                source: "ExperimentalDescription.Microscope", rule: "rsciio tia _get_microscope_name: replace(\"Microscope \", \"\")")
        }
        if case .text(let m)? = description["Mode"] {
            add(tem + "acquisition_mode", .text(m.contains("STEM") ? "STEM" : "TEM"), units: nil,
                source: "ExperimentalDescription.Mode", rule: "rsciio tia _get_simplified_mode: STEM if \"STEM\" in mode, else TEM")
        }
        add(tem + "camera_length", number("Camera_length_m", times: 1e3), units: "mm", source: "ExperimentalDescription.Camera length_m",
            rule: "rsciio tia mapping: x * 1e3")
        add(tem + "magnification", description["Magnification_x"], units: nil, source: "ExperimentalDescription.Magnification_x",
            rule: "rsciio tia mapping: as is")
        add(tem + "Detector.Camera.Name", acquireInfo?["CameraNamePath"].map(FormatoValue.text), units: nil,
            source: "AcquireInfo.CameraNamePath", rule: "rsciio tia mapping: as is")
        add(tem + "Detector.Camera.exposure", acquireInfo?["DwellTimePath"].map(FormatoValue.text), units: nil,
            source: "AcquireInfo.DwellTimePath", rule: "rsciio tia mapping: as is (text)")
        add(tem + "Stage.tilt_alpha", description["Stage_A_deg"], units: "deg", source: "ExperimentalDescription.Stage A_deg",
            rule: "rsciio tia mapping: as is")
        add(tem + "Stage.tilt_beta", description["Stage_B_deg"], units: "deg", source: "ExperimentalDescription.Stage B_deg",
            rule: "rsciio tia mapping: as is")
        for axis in ["X", "Y", "Z"] {
            add(tem + "Stage.\(axis.lowercased())", number("Stage_\(axis)_um", times: 1e-3), units: "mm",
                source: "ExperimentalDescription.Stage \(axis)_um", rule: "rsciio tia mapping: x * 1e-3")
        }
        add("General.authors", description["User"], units: nil, source: "ExperimentalDescription.User", rule: "rsciio tia mapping: as is")
        return out
    }

    // MARK: ElementTree's view of a Foundation tree

    static func children(_ e: XMLElement, _ name: String) -> [XMLElement] {
        e.children?.compactMap { $0 as? XMLElement }.filter { $0.name == name } ?? []
    }

    static func firstChild(_ e: XMLElement, _ name: String) -> XMLElement? { children(e, name).first }

    /// ElementTree's `.text`: the text before the first child element, nil when empty.
    static func text(_ e: XMLElement) -> String? {
        var out = ""
        for node in e.children ?? [] {
            if node is XMLElement { break }
            if node.kind == .text, let s = node.stringValue { out += s }
        }
        return out.isEmpty ? nil : out
    }

    /// HyperSpy's `slugify(value, valid_variable_name=True)`: NFKD to ASCII, every character of codes 0 to 255 that is not a
    /// letter, a digit, "_" or a space removed, trimmed, spaces to "_", "Number_" before a name that is not an identifier.
    static func slug(_ value: String) -> String {
        func letter(_ v: UInt32) -> Bool { (65...90).contains(v) || (97...122).contains(v) }
        var kept = String.UnicodeScalarView()
        for scalar in value.decomposedStringWithCompatibilityMapping.unicodeScalars {
            let v = scalar.value
            if letter(v) || (48...57).contains(v) || v == 95 || v == 32 { kept.append(scalar) }
        }
        let slug = String(kept).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard let first = slug.unicodeScalars.first?.value, first == 95 || letter(first) else { return "Number_" + slug }
        return slug
    }

    /// Python's `float(text)` for decimal text: surrounding whitespace allowed, digits with one point and an exponent,
    /// "nan" and "inf"/"infinity" with a sign; nil for anything else (where RosettaSciIO keeps the text).
    static func pythonFloat(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let body = lower.hasPrefix("+") || lower.hasPrefix("-") ? String(lower.dropFirst()) : lower
        let negative = lower.hasPrefix("-")
        if body == "nan" { return .nan }
        if body == "inf" || body == "infinity" { return negative ? -.infinity : .infinity }
        guard !body.isEmpty, body.allSatisfy({ "0123456789.e+-".contains($0) }), body.contains(where: \.isNumber) else { return nil }
        return Double(t)
    }
}
