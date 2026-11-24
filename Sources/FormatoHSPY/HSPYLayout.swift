//
//  HSPYLayout.swift
//  Role: HyperSpy's file layout, version 3.3, as RosettaSciIO 0.14.0's `hspy` writer and HyperSpy 2.5.0 make it
//        (rsciio/hspy/_api.py `file_writer`, rsciio/_hierarchical.py `HierarchicalWriter.write_signal` and `dict2group`),
//        checked attribute by attribute against what HyperSpy writes for the same signals (tools/hspy-writer, pin H2):
//
//    /                              file_format = "HyperSpy", file_format_version = "3.3"
//    /Experiments/<title>           package, package_version (the Python package that owns the class)
//      axis-<i>                     one per dimension in array order: _type = "UniformDataAxis", name, units ("_None_" for
//                                   none), size (int64), scale, offset (float64), navigate, is_binned (bool)
//      data                         the values in their stored type, chunked (HyperSpy's own rule), no filters
//      metadata/General             title; FileIO/0: operation = "save", io_plugin = "FormatoHSPY", software, timestamp
//      metadata/Signal              signal_type
//      metadata/_HyperSpy/Folding   original_axes_manager = original_shape = "_None_", signal_unfolded = unfolded = false
//      metadata/...                 the signal's metadata and the options' metadata, a group per key component
//      original_metadata            empty
//      learning_results             empty
//      attributes                   _lazy = false, ragged = false
//
//  Text is variable-length UTF-8, as h5py writes a Python `str` (fixed-length text does not load). A bool is h5py's
//  enumeration (a uint8 bool fails on `navigate`). Where it differs from HyperSpy: the data is not compressed (HyperSpy: gzip
//  and shuffle); a list is a `_list_<N>_<key>` group of text attributes where HyperSpy writes a `_list_<key>` dataset (both
//  read back as the same list); the FileIO entry is the kit's.
//

import Foundation
import FormatoCore
import FormatoHDF5

nonisolated enum HSPYLayout {
    static let formatVersion = "3.3"
    /// RosettaSciIO's `HyperspyWriter.target_size`: about this many bytes a chunk.
    static let chunkTargetBytes = 1_000_000
    static let experimentsPath = "/Experiments"
    static let ioPlugin = "FormatoHSPY"

    /// The checked axes and layout facts of one file.
    struct Plan {
        var axes: [FormatoAxis]
        var kind: HSPYSignalKind
        var title: String
        var groupPath: String
        var chunk: [Int]
        var metadata: [(key: String, value: FormatoValue)]
        var software: String?
        var timestamp: Date
        var dataPath: String { groupPath + "/data" }
    }

    /// Checks everything that can be refused before a byte is written.
    static func plan(shape: [Int], dataType: FormatoDataType, axes: [FormatoAxis], kind: HSPYSignalKind, title: String,
                     signalMetadata: FormatoMetadata, options: HSPYWriteOptions) throws -> Plan {
        guard dataType.components == 1 else { throw HSPYError.unsupportedDataType(dataType) }
        guard (1...4).contains(shape.count) else { throw HSPYError.unsupportedRank(shape.count) }
        if let empty = shape.firstIndex(where: { $0 < 1 }) { throw HSPYError.emptyDimension(index: empty) }
        guard axes.map(\.size) == shape else { throw HSPYError.axesDoNotMatchShape(sizes: axes.map(\.size), shape: shape) }
        if let bad = axes.firstIndex(where: { !$0.scale.isFinite || !$0.offset.isFinite }) { throw HSPYError.nonFiniteAxis(index: bad) }
        let signalAxes = axes.indices.filter { !axes[$0].navigate }
        guard let firstSignal = signalAxes.first else { throw HSPYError.noSignalAxis }
        guard signalAxes == Array(firstSignal..<axes.count) else { throw HSPYError.signalAxesNotLast }
        if let needed = kind.signalDimension, needed != signalAxes.count {
            throw HSPYError.signalDimension(kind: kind, expected: needed, found: signalAxes.count)
        }
        guard title != ".", title != "..", !title.utf8.contains(0) else { throw HSPYError.invalidTitle(title) }
        let chunk: [Int]
        if let asked = options.chunkShape {
            guard asked.count == shape.count, zip(asked, shape).allSatisfy({ $0 >= 1 && $0 <= $1 }),
                  let elements = try? FormatoArray.elementCount(asked) else { throw HSPYError.invalidChunkShape(asked) }
            let (bytes, overflow) = elements.multipliedReportingOverflow(by: dataType.byteSize)
            guard !overflow, bytes < (1 << 32) else { throw HSPYError.invalidChunkShape(asked) }
            chunk = asked
        } else {
            chunk = hyperSpyChunks(shape: shape, byteSize: dataType.byteSize, signalAxes: signalAxes)
        }
        let group = title.isEmpty ? "__unnamed__" : title.replacingOccurrences(of: "/", with: "-")
        return Plan(axes: axes, kind: kind, title: title, groupPath: experimentsPath + "/" + group,
                    chunk: chunk, metadata: try metadataEntries(signalMetadata, options.metadata), software: options.software,
                    timestamp: options.timestamp ?? Date())
    }

    // MARK: Chunks

    /// RosettaSciIO 0.14.0 `rsciio._hierarchical.get_signal_chunks(shape, dtype, signal_axes, target_size=1e6)`, line for line:
    /// whole signals in a chunk; about `chunkTargetBytes` a chunk, the navigation axes cut evenly (an axis shorter than its
    /// share kept whole); one signal a chunk when a signal is over half the target.
    static func hyperSpyChunks(shape: [Int], byteSize: Int, signalAxes: [Int]) -> [Int] {
        let bytesPerSignal = signalAxes.reduce(byteSize) { $0 * shape[$1] }
        let signalsPerChunk = chunkTargetBytes / bytesPerSignal                   // np.floor_divide(1e6, bytes), positive
        let navigation = shape.indices.filter { !signalAxes.contains($0) }
        let signalCount = navigation.reduce(1) { $0 * shape[$1] }
        if signalsPerChunk < 2 || navigation.isEmpty {
            return shape.indices.map { signalAxes.contains($0) ? shape[$0] : 1 }
        }
        if signalsPerChunk > signalCount { return shape }
        var small: [Int] = []
        var smallProduct = 1.0
        var navigationChunk = 0
        var iterate = true
        while iterate {
            iterate = false
            // Every navigation axis short cannot happen (the signals would fit one chunk, returned above); kept whole if it did.
            guard small.count < navigation.count else { return shape }
            let share = pow(Double(signalsPerChunk) / smallProduct, 1.0 / Double(navigation.count - small.count))
            navigationChunk = Int(share.rounded(.down))
            for index in shape.indices where !signalAxes.contains(index) && !small.contains(index) && shape[index] < navigationChunk {
                small.append(index)
                smallProduct *= Double(shape[index])
                iterate = true
            }
        }
        return shape.indices.map { signalAxes.contains($0) || small.contains($0) ? shape[$0] : navigationChunk }
    }

    // MARK: Metadata

    /// The keys the writer writes itself, and the groups under which every key is its own.
    static let ownedKeys: Set<String> = ["General.title", "Signal.signal_type"]
    static let ownedGroups = ["General.FileIO", "_HyperSpy"]
    /// Name prefixes RosettaSciIO reads as structures of their own (`_group2dict`), never as a plain key.
    static let structurePrefixes = ["_list_", "_tuple_", "_sig_", "_bs_", "_datetime_", "_hspy_AxesManager_", "_ragged_shapes_"]

    static func isOwned(_ key: String) -> Bool {
        ownedKeys.contains(key) || ownedGroups.contains { key == $0 || key.hasPrefix($0 + ".") }
    }

    /// The signal's entries (in order; the ones the writer owns are left to it) then the options' (sorted by key, each
    /// replacing the signal's of the same key), every key checked.
    static func metadataEntries(_ signal: FormatoMetadata, _ extra: [String: FormatoValue]) throws -> [(key: String, value: FormatoValue)] {
        var entries: [(key: String, value: FormatoValue)] = []
        for entry in signal.entries where !isOwned(entry.key) && extra[entry.key] == nil { entries.append((entry.key, entry.value)) }
        for key in extra.keys.sorted() {
            guard !isOwned(key) else { throw HSPYError.reservedMetadataKey(key) }
            entries.append((key, extra[key]!))
        }
        for (key, value) in entries {
            let parts = key.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ part in
                !part.isEmpty && !part.contains("/") && !part.utf8.contains(0) && !structurePrefixes.contains { part.hasPrefix($0) }
            }) else { throw HSPYError.invalidMetadataKey(key) }
            let texts: [String] = switch value {
            case .text(let text): [text]
            case .texts(let all): all
            case .number, .flag: []
            }
            if texts.contains(where: { $0.utf8.contains(0) }) { throw HSPYError.textWithNUL(key: key) }
        }
        // A key may not be a group of another, nor of a key the writer writes (General.title is a value under General).
        let values = Set(entries.map(\.key))
        for key in (entries.map(\.key) + ownedKeys.sorted() + ownedGroups.map { $0 + ".0" }) {
            var parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            while parts.count > 1 {
                parts.removeLast()
                let group = parts.joined(separator: ".")
                if values.contains(group) { throw HSPYError.conflictingMetadataKeys(group, key) }
            }
        }
        return entries
    }

    // MARK: Writing

    /// Everything around the data: the file's attributes, the experiment, its axes, metadata and the empty groups.
    static func writeStructure(_ plan: Plan, _ session: HDF5WriteSession) throws {
        try session.setVariableLengthTextAttribute("file_format", on: "/", "HyperSpy")
        try session.setVariableLengthTextAttribute("file_format_version", on: "/", formatVersion)
        let group = plan.groupPath
        try session.createGroup(group)
        try session.setVariableLengthTextAttribute("package", on: group, plan.kind.package)
        try session.setVariableLengthTextAttribute("package_version", on: group, plan.kind.packageVersion)
        for (index, axis) in plan.axes.enumerated() {
            let path = group + "/axis-\(index)"
            try session.createGroup(path)
            try session.setVariableLengthTextAttribute("_type", on: path, "UniformDataAxis")
            try session.setBoolAttribute("is_binned", on: path, plan.kind.binsSignalAxis && !axis.navigate)
            try session.setVariableLengthTextAttribute("name", on: path, axis.name ?? "_None_")
            try session.setBoolAttribute("navigate", on: path, axis.navigate)
            try session.setAttribute("offset", on: path, .real(axis.offset))
            try session.setAttribute("scale", on: path, .real(axis.scale))
            try session.setAttribute("size", on: path, .integer(Int64(axis.size)))
            try session.setVariableLengthTextAttribute("units", on: path, axis.units.isEmpty ? "_None_" : axis.units)
        }
        let metadata = group + "/metadata"
        try session.createGroup(metadata + "/General")
        try session.setVariableLengthTextAttribute("title", on: metadata + "/General", plan.title)
        let fileIO = metadata + "/General/FileIO/0"
        try session.createGroup(fileIO)
        try session.setVariableLengthTextAttribute("operation", on: fileIO, "save")
        try session.setVariableLengthTextAttribute("io_plugin", on: fileIO, ioPlugin)
        if let software = plan.software { try session.setVariableLengthTextAttribute("software", on: fileIO, software) }
        try session.setVariableLengthTextAttribute("timestamp", on: fileIO, timestamp(plan.timestamp))
        try session.createGroup(metadata + "/Signal")
        try session.setVariableLengthTextAttribute("signal_type", on: metadata + "/Signal", plan.kind.signalType)
        let folding = metadata + "/_HyperSpy/Folding"
        try session.createGroup(folding)
        try session.setVariableLengthTextAttribute("original_axes_manager", on: folding, "_None_")
        try session.setVariableLengthTextAttribute("original_shape", on: folding, "_None_")
        try session.setBoolAttribute("signal_unfolded", on: folding, false)
        try session.setBoolAttribute("unfolded", on: folding, false)
        for (key, value) in plan.metadata { try writeEntry(key, value, under: metadata, session) }
        try session.createGroup(group + "/original_metadata")
        try session.createGroup(group + "/learning_results")
        try session.createGroup(group + "/attributes")
        try session.setBoolAttribute("_lazy", on: group + "/attributes", false)
        try session.setBoolAttribute("ragged", on: group + "/attributes", false)
    }

    /// One metadata entry as RosettaSciIO's `dict2group` stores its value: a group per key component, the last one an attribute.
    static func writeEntry(_ key: String, _ value: FormatoValue, under metadata: String, _ session: HDF5WriteSession) throws {
        var parts = key.split(separator: ".").map(String.init)
        let leaf = parts.removeLast()
        let parent = ([metadata] + parts).joined(separator: "/")
        try session.createGroup(parent)
        switch value {
        case .number(let number): try session.setAttribute(leaf, on: parent, .real(number))
        case .text(let text): try session.setVariableLengthTextAttribute(leaf, on: parent, text)
        case .flag(let flag): try session.setBoolAttribute(leaf, on: parent, flag)
        case .texts(let texts) where texts.isEmpty:
            try session.setVariableLengthTextAttribute("_list_empty_" + leaf, on: parent, "_None_")
        case .texts(let texts):
            // RosettaSciIO reads the group's items sorted by name: "10" sorts before "2", so the names share one width.
            let list = parent + "/_list_\(texts.count)_" + leaf
            try session.createGroup(list)
            let width = String(texts.count - 1).count
            for (index, text) in texts.enumerated() {
                let name = String(repeating: "0", count: width - String(index).count) + String(index)
                try session.setVariableLengthTextAttribute(name, on: list, text)
            }
        }
    }

    /// ISO 8601 with fractional seconds, in UTC, as HyperSpy's `datetime.isoformat()` reads back.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
