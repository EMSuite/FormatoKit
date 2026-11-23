//
//  HSPYReader.swift
//  Role: read a HyperSpy file (.hspy) the way RosettaSciIO 0.14.0's `rsciio.hspy.file_reader` reads it
//        (rsciio/_hierarchical.py `HierarchicalReader.read`, `group2signaldict`, `_group2dict`), pinned exact by pin H4
//        (tools/hspy-reader): the files HyperSpy 2.5.0 writes (gzip and shuffle, HyperSpy's chunks, lists as `_list_<key>`
//        datasets, layout 3.3), exspy's own example of layout 3.0, and the files `HSPYWriter` writes.
//
//    /Experiments/<name>          one signal each that holds `data`, listed in the file's (h5py's) order
//      data                       numeric, read at its stored type a hyperslab at a time (the lazy signal) or whole
//      axis-<i>                   name, units ("_None_" is none), size, scale, offset, navigate; uniform only
//      metadata                   the tree, flattened to dotted keys in RosettaSciIO's order: a group's attributes (by name),
//                                 then its members (by name); text, numbers, h5py's bools and lists of text
//      attributes                 `ragged`: a ragged signal is refused
//
//  What RosettaSciIO returns and a `FormatoValue` cannot hold is left out of the metadata: "_None_" (None), lists that are
//  not all text, tuples, arrays, binary strings, nested signals (`_sig_`), the old `_datetime_` keys. `original_metadata`,
//  learning results and models are not read; an attribute RosettaSciIO keeps that FormatoValue cannot hold (a uint64 past
//  Int64.max, a one-character fixed-length string array) is left out, and an axis is refused as functional only by its
//  `_type`. A layout newer than 3.3 is read as RosettaSciIO reads it (it warns, then tries); one older than 1.2 is refused.
//  Files older than 3.0 get RosettaSciIO's two metadata moves (tilt_stage, exposure).
//
//  Refused by name (`HSPYError`), per experiment: ragged signals, complex data, any other non-numeric type, a rank outside
//  1 to 4, non-uniform axes (DataAxis, FunctionalDataAxis), an axis missing or without its navigate flag. A file saved from
//  a lazy HyperSpy signal (`attributes._lazy` true) is an ordinary file and is read.
//

import Foundation
import FormatoCore
import FormatoHDF5

public nonisolated enum HSPYReader {
    /// The experiments of the HyperSpy file at `url` that hold data, in the file's order: each one's title, signal type,
    /// shape, stored type and axes, or why `read` refuses it. No data is read.
    /// - Throws: `HSPYError` for a file that is not HyperSpy's, of a layout older than 1.2, or without an experiment;
    ///   `HDF5FileError` for the file itself.
    public static func experiments(url: URL) throws -> [HSPYExperiment] {
        let reader = try HDF5Reader(url: url)
        var listed: [HSPYExperiment] = []
        for name in try experimentNames(reader, file: formatoDisplayFileName(url.path)) {
            let group = HSPYLayout.experimentsPath + "/" + name
            // One experiment the reader cannot take is listed with its refusal; the others are still listed.
            let stated = (try? statedTitle(reader, group)) ?? name, type = (try? statedSignalType(reader, group)) ?? ""
            let shape = (try? reader.datasetInfo(group + "/data").shape) ?? []
            do {
                let found = try inspect(reader, name)
                listed.append(HSPYExperiment(name: name, title: stated, signalType: type, shape: shape, dataType: found.dataType,
                                             axes: found.axes, refusal: nil))
            } catch let refusal as HSPYError {
                listed.append(HSPYExperiment(name: name, title: stated, signalType: type, shape: shape, dataType: nil, axes: [],
                                             refusal: refusal))
            } catch let error as HDF5FileError {
                listed.append(HSPYExperiment(name: name, title: stated, signalType: type, shape: shape, dataType: nil, axes: [],
                                             refusal: .unreadable(experiment: name, reason: error.localizedDescription)))
            }
        }
        return listed
    }

    /// The experiment `experiment` (a group name from `experiments(url:)`; nil for the first) as a lazy signal: the axes and
    /// the metadata tree now, the data a hyperslab at a time from the file, at its stored type (`FormatoLazyArray.read`).
    /// - Throws: `HSPYError` for what is refused, `HDF5FileError` for the file.
    public static func read(url: URL, experiment: String? = nil) throws -> FormatoLazySignal {
        let reader = try HDF5Reader(url: url)
        let file = formatoDisplayFileName(url.path)
        let names = try experimentNames(reader, file: file)
        let name: String
        if let experiment {
            guard names.contains(experiment) else { throw HSPYError.unknownExperiment(experiment) }
            name = experiment
        } else {
            name = names[0]
        }
        let found = try inspect(reader, name)
        let group = HSPYLayout.experimentsPath + "/" + name
        var metadata = FormatoMetadata()
        try readTree(reader, group: group + "/metadata", prefix: "", file: file, into: &metadata, depth: 0)
        if try isBefore3(formatVersion(reader, file: file)) { metadata = movedBefore3(metadata, file: file) }
        let stated = try statedTitle(reader, group), type = try statedSignalType(reader, group)
        let array = HSPYDataArray(reader: reader, path: group + "/data", dataType: found.dataType, shape: found.shape)
        return FormatoLazySignal(title: stated, signalType: type, axes: found.axes, metadata: metadata, array: array)
    }

    /// `read(url:experiment:)` with the data read whole, at its stored type: the signal `HSPYWriter.write` takes back.
    public static func readStored(url: URL, experiment: String? = nil) throws -> FormatoSignal {
        try read(url: url, experiment: experiment).load()
    }

    /// Whether the HDF5 file at `path` is HyperSpy's: its root says `file_format` "HyperSpy", or it has `/Experiments`.
    package static func isHyperSpyFile(path: String) -> Bool {
        guard let reader = try? HDF5Reader(url: URL(fileURLWithPath: path)) else { return false }
        if (try? textAttribute(reader, "file_format", of: "/")) == "HyperSpy" { return true }
        return (try? reader.exists(HSPYLayout.experimentsPath)) == true
    }

    // MARK: The file

    /// RosettaSciIO's `get_format_version`: the root's `file_format_version`, else "1.0" for a file with `Experiments` and
    /// "2.0" for one with `Analysis`; a file with none of them is not HyperSpy's.
    static func formatVersion(_ reader: HDF5Reader, file: String) throws -> String {
        if try reader.attributeNames(of: "/").contains("file_format_version") {
            switch try reader.attribute("file_format_version", of: "/") {
            case .text(let text): return text
            case .real(let real): return "\((real * 100).rounded() / 100)"                       // str(round(version, 2))
            default: throw HSPYError.unsupportedVersion("(not text)")
            }
        }
        if try reader.exists(HSPYLayout.experimentsPath) { return "1.0" }
        if try reader.exists("/Analysis") { return "2.0" }
        throw HSPYError.notHyperSpyFile(file)
    }

    /// The group names under `/Experiments` that hold `data`, in the file's order; the layout version checked first.
    static func experimentNames(_ reader: HDF5Reader, file: String) throws -> [String] {
        let version = try formatVersion(reader, file: file)
        let parts = version.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else { throw HSPYError.unsupportedVersion(version) }
        guard major > 1 || (major == 1 && minor >= 2) else { throw HSPYError.unsupportedVersion(version) }
        guard try reader.exists(HSPYLayout.experimentsPath), try reader.kind(of: HSPYLayout.experimentsPath) == .group else {
            throw HSPYError.noExperiment(file)
        }
        var names: [String] = []
        for name in try reader.children(of: HSPYLayout.experimentsPath) {
            let group = HSPYLayout.experimentsPath + "/" + name
            guard try reader.kind(of: group) == .group, try reader.exists(group + "/data") else { continue }
            names.append(name)
        }
        guard !names.isEmpty else { throw HSPYError.noExperiment(file) }
        return names
    }

    /// Whether `version` is older than layout 3.0.
    static func isBefore3(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return (parts.first ?? 0) < 3
    }

    /// RosettaSciIO's moves for layouts older than 3.0 (`group2signaldict`): `TEM.tilt_stage` and `SEM.tilt_stage` become
    /// `Stage.tilt_alpha`, and `TEM.exposure_time` (else `TEM.exposure`) becomes `Detector.Camera.exposure`. As in Python, the
    /// new group replaces an old one in its place, or else goes last in its parent group.
    static func movedBefore3(_ metadata: FormatoMetadata, file: String) -> FormatoMetadata {
        var entries = metadata.entries
        func move(_ from: String, to: String) {
            guard let old = entries.first(where: { $0.key == from }) else { return }
            var parents = to.split(separator: ".").map(String.init)
            parents.removeLast()
            let group = parents.joined(separator: ".")
            func isGone(_ key: String) -> Bool { key == from || key.hasPrefix(group + ".") }
            let kept = entries.filter { !isGone($0.key) }
            var at = kept.count
            if let first = entries.firstIndex(where: { $0.key.hasPrefix(group + ".") }) {
                at = entries[..<first].filter { !isGone($0.key) }.count
            } else {
                // The nearest ancestor group that is left: the new group goes after its last entry.
                while parents.count > 2 {
                    parents.removeLast()
                    let ancestor = parents.joined(separator: ".") + "."
                    if let last = kept.lastIndex(where: { $0.key.hasPrefix(ancestor) }) {
                        at = last + 1
                        break
                    }
                }
            }
            let moved = FormatoMetadataEntry(key: to, value: old.value, units: old.units,
                                             provenance: FormatoProvenance(file: file, source: old.provenance.source,
                                                                           rule: "rsciio hspy group2signaldict, layout before 3.0"))
            entries = kept
            entries.insert(moved, at: at)
        }
        for microscope in ["TEM", "SEM"] {
            let base = "Acquisition_instrument." + microscope
            move(base + ".tilt_stage", to: base + ".Stage.tilt_alpha")
        }
        let tem = "Acquisition_instrument.TEM"
        let exposure = entries.contains { $0.key == tem + ".exposure_time" } ? tem + ".exposure_time" : tem + ".exposure"
        move(exposure, to: tem + ".Detector.Camera.exposure")
        return FormatoMetadata(entries)
    }

    // MARK: One experiment

    /// The checked facts of a readable experiment.
    struct Inspected {
        var dataType: FormatoDataType
        var shape: [Int]
        var axes: [FormatoAxis]
    }

    /// Everything `read` refuses, checked without reading data: ragged, the stored type, the rank, the axes.
    static func inspect(_ reader: HDF5Reader, _ name: String) throws -> Inspected {
        let group = HSPYLayout.experimentsPath + "/" + name
        let attributes = group + "/attributes"
        if try reader.exists(attributes), try reader.attributeNames(of: attributes).contains("ragged"),
           case .integer(let ragged) = try reader.attribute("ragged", of: attributes), ragged != 0 {
            throw HSPYError.raggedSignal(experiment: name)
        }
        let raggedShapes = try reader.exists(group + "/_ragged_shapes_data")
        let oldRaggedShapes = try reader.exists(group + "/ragged_shapes")
        if raggedShapes || oldRaggedShapes { throw HSPYError.raggedSignal(experiment: name) }
        let dataPath = group + "/data"
        let info = try reader.datasetInfo(dataPath)
        let dataType: FormatoDataType
        switch info.type {
        case .numeric(let type): dataType = type
        case .unsupported("float16"): dataType = .float32                // read widened, exactly (HDF5Reader.readDataset)
        case .unsupported("vlen"): throw HSPYError.raggedSignal(experiment: name)
        case .unsupported("compound"):
            if try reader.compoundMemberNames(of: dataPath) == ["r", "i"] { throw HSPYError.complexData(experiment: name) }
            throw HSPYError.unsupportedStoredType(experiment: name, type: "compound")
        case .unsupported(let type): throw HSPYError.unsupportedStoredType(experiment: name, type: type)
        case .string: throw HSPYError.unsupportedStoredType(experiment: name, type: "string")
        }
        let shape = info.shape
        guard (1...4).contains(shape.count) else { throw HSPYError.unsupportedRank(shape.count) }
        let axes = try shape.indices.map { try axis($0, size: shape[$0], reader, experiment: name) }
        return Inspected(dataType: dataType, shape: shape, axes: axes)
    }

    /// `axis-<index>` of the experiment, as RosettaSciIO reads the group's attributes ("_None_" is None) and HyperSpy builds a
    /// uniform axis from them (scale 1 and offset 0 when absent).
    static func axis(_ index: Int, size: Int, _ reader: HDF5Reader, experiment: String) throws -> FormatoAxis {
        let path = HSPYLayout.experimentsPath + "/" + experiment + "/axis-\(index)"
        guard try reader.exists(path), try reader.kind(of: path) == .group else {
            throw HSPYError.invalidAxis(experiment: experiment, index: index, reason: "the file has no axis-\(index) group")
        }
        let names = Set(try reader.attributeNames(of: path))
        func value(_ name: String) throws -> HDF5AttributeValue? {
            guard names.contains(name) else { return nil }
            return try reader.attribute(name, of: path)
        }
        if let type = try value("_type") {
            guard case .text(let typeName) = type, typeName == "UniformDataAxis" else {
                throw HSPYError.nonUniformAxis(experiment: experiment, index: index, type: text(type) ?? "axis")
            }
        } else if try reader.exists(path + "/axis") {
            throw HSPYError.nonUniformAxis(experiment: experiment, index: index, type: "DataAxis")
        }
        func number(_ name: String, default fallback: Double) throws -> Double {
            switch try value(name) {
            case nil: return fallback
            case .real(let real)?: return real
            case .integer(let integer)?: return Double(integer)
            default: throw HSPYError.invalidAxis(experiment: experiment, index: index, reason: "its \(name) is not a number")
            }
        }
        if let stored = try value("size") {
            guard case .integer(let found) = stored, found == Int64(size) else {
                throw HSPYError.invalidAxis(experiment: experiment, index: index, reason: "its size is not the data's \(size)")
            }
        }
        guard case .integer(let navigate)? = try value("navigate") else {
            throw HSPYError.invalidAxis(experiment: experiment, index: index, reason: "it has no navigate flag")
        }
        let name = try text(value("name")).flatMap { $0 == "_None_" ? nil : $0 }
        let units = try text(value("units")).flatMap { $0 == "_None_" ? nil : $0 } ?? ""
        let scale = try number("scale", default: 1), offset = try number("offset", default: 0)
        return FormatoAxis(name: name, size: size, scale: scale, offset: offset, units: units, navigate: navigate != 0)
    }

    /// `metadata.General.title`, "" when absent or `__unnamed__` (RosettaSciIO's `group2signaldict`).
    static func statedTitle(_ reader: HDF5Reader, _ group: String) throws -> String {
        let text = try textAttribute(reader, "title", of: group + "/metadata/General") ?? ""
        return text == "__unnamed__" ? "" : text
    }

    /// `metadata.Signal.signal_type`, "" when absent.
    static func statedSignalType(_ reader: HDF5Reader, _ group: String) throws -> String {
        try textAttribute(reader, "signal_type", of: group + "/metadata/Signal") ?? ""
    }

    static func textAttribute(_ reader: HDF5Reader, _ name: String, of path: String) throws -> String? {
        guard try reader.exists(path), try reader.attributeNames(of: path).contains(name) else { return nil }
        guard let found = try text(reader.attribute(name, of: path)), found != "_None_" else { return nil }
        return found
    }

    /// The text of a scalar text attribute, nil for anything else.
    static func text(_ value: HDF5AttributeValue?) -> String? {
        if case .text(let text)? = value { return text }
        return nil
    }

    // MARK: The metadata tree

    /// RosettaSciIO's `_group2dict` of `group`, flattened into `metadata` under `prefix`: the attributes by name, then the
    /// members by name (a `_list_<key>` dataset or `_list_<N>_<key>` group as a list of text, any other group as a branch).
    static func readTree(_ reader: HDF5Reader, group: String, prefix: String, file: String, into metadata: inout FormatoMetadata,
                         depth: Int) throws {
        guard depth <= 64 else { throw HDF5FileError.limitExceeded("metadata nests deeper than 64 below \(group)") }
        guard try reader.exists(group), try reader.kind(of: group) == .group else { return }
        func add(_ key: String, _ value: FormatoValue, _ source: String) {
            var value = value
            if prefix + key == "General.title", value == .text("__unnamed__") { value = .text("") }
            metadata.set(FormatoMetadataEntry(key: prefix + key, value: value, units: nil,
                                              provenance: FormatoProvenance(file: file, source: source, rule: "rsciio hspy _group2dict")))
        }
        let skipped = ["_sig_", "_bs_", "_tuple_empty_", "_datetime_"]
        for name in try reader.attributeNames(of: group) where !skipped.contains(where: { name.hasPrefix($0) }) {
            if name.hasPrefix("_list_empty_") {
                add(String(name.dropFirst("_list_empty_".count)), .texts([]), group + "@" + name)
            } else if let value = try plainValue(reader, name, of: group) {
                add(name, value, group + "@" + name)
            }
        }
        let skippedMembers = ["_ragged_shapes_", "_sig_", "_hspy_AxesManager_", "_tuple_"]
        for name in try reader.children(of: group) where !skippedMembers.contains(where: { name.hasPrefix($0) }) {
            let path = group + "/" + name
            switch try reader.kind(of: path) {
            case .dataset:
                // `_list_<key>`: a list HyperSpy stored as a dataset; only a list of text is kept.
                guard name.hasPrefix("_list_") else { continue }
                let info = try reader.datasetInfo(path)
                guard info.shape.count == 1, case .string = info.type else { continue }
                add(String(name.dropFirst("_list_".count)), .texts(try reader.readStrings(path)), path)
            case .group:
                if name.hasPrefix("_list_") {
                    if let texts = try listGroup(reader, path) { add(listKey(name), .texts(texts), path) }
                } else {
                    try readTree(reader, group: path, prefix: prefix + name + ".", file: file, into: &metadata, depth: depth + 1)
                }
            case .other:
                continue
            }
        }
    }

    /// An attribute's value as RosettaSciIO returns it, when a `FormatoValue` holds it: text ("_None_" is None, left out), a
    /// number (a real, or an integer as a float64) or h5py's bool; arrays and other types are left out.
    static func plainValue(_ reader: HDF5Reader, _ name: String, of path: String) throws -> FormatoValue? {
        let stored: HDF5AttributeValue
        do {
            stored = try reader.attribute(name, of: path)
        } catch let error as HDF5FileError {
            // A value FormatoValue cannot hold (another type, a uint64 past Int64.max, text that is not UTF-8) is left out.
            switch error {
            case .unsupportedType, .limitExceeded, .invalidUTF8: return nil
            default: throw error
            }
        }
        switch stored {
        case .text(let text): return text == "_None_" ? nil : .text(text)
        case .real(let real): return .number(real)
        case .integer(let integer):
            // h5py's bool is a one-byte enumeration, which `attribute` reads as the integers 0 and 1.
            if try reader.attributeTypeFacts(name, of: path).typeClass == 8 { return .flag(integer != 0) }
            return .number(Double(integer))
        case .texts, .integers, .reals: return nil
        }
    }

    /// The items of a `_list_<N>_<key>` group in RosettaSciIO's order (sorted by name), when every item is text and the group
    /// holds nothing else; nil otherwise (a list FormatoValue cannot hold).
    static func listGroup(_ reader: HDF5Reader, _ path: String) throws -> [String]? {
        guard try reader.children(of: path).isEmpty else { return nil }
        var texts: [String] = []
        for name in try reader.attributeNames(of: path) {
            guard case .text(let item)? = try plainValue(reader, name, of: path) else { return nil }
            texts.append(item)
        }
        return texts
    }

    /// RosettaSciIO's key of a `_list_<N>_<key>` group: `key[7 + key[6:].find("_"):]`.
    static func listKey(_ name: String) -> String {
        let rest = name.dropFirst("_list_".count)
        guard let underscore = rest.firstIndex(of: "_") else { return String(rest) }
        return String(rest[rest.index(after: underscore)...])
    }
}

/// An experiment's data, read from the file a hyperslab at a time at its stored type (a float16 dataset as float32).
nonisolated struct HSPYDataArray: FormatoLazyArray {
    let reader: HDF5Reader
    let path: String
    let dataType: FormatoDataType
    let shape: [Int]

    func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.validateSlab(start: start, count: count, shape: shape)
        try FormatoCancellation.check(FormatoCancellation.task)
        return try reader.readDataset(path, start: start, count: count)
    }
}
