//
//  HSPYGolden.swift
//  The layout HyperSpy 2.5.0 writes for the planted signals (Fixtures/hyperspy-layout.json, tools/hspy-writer/generate.py),
//  the planted signals rebuilt from it, and the comparison of a kit-written file with that layout through the kit's own HDF5
//  layer. Shared by the whole-signal and the streamed tests.
//

import CryptoKit
import Foundation
import Testing
import FormatoCore
import FormatoHDF5
import FormatoHSPY

struct HSPYGoldenFile: Decodable {
    var versions: [String: String]
    var signals: [HSPYPlanted]
}

struct HSPYPlantedAxis: Decodable {
    var name: String?
    var size: Int
    var scale: Double
    var offset: Double
    var units: String
    var navigate: Bool
}

struct HSPYPlantedEntry: Decodable {
    var key: String
    var type: String
    var via: String
    var value: FormatoValue

    enum CodingKeys: String, CodingKey { case key, type, via, value }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        type = try c.decode(String.self, forKey: .type)
        via = try c.decode(String.self, forKey: .via)
        switch type {
        case "number": value = .number(try c.decode(Double.self, forKey: .value))
        case "flag": value = .flag(try c.decode(Bool.self, forKey: .value))
        case "texts": value = .texts(try c.decode([String].self, forKey: .value))
        default: value = .text(try c.decode(String.self, forKey: .value))
        }
    }
}

/// One attribute as h5py recorded it: its class (`string`, `bool`, `float`, `integer`) and value (a real as `float.hex`).
struct HSPYGoldenAttribute: Decodable {
    var kind: String
    var scalar: Bool
    var variable: Bool?
    var utf8: Bool?
    var size: Int?
    var signed: Bool?
    var text: String?
    var flag: Bool?
    var integer: Int64?

    enum CodingKeys: String, CodingKey { case kind = "class", scalar, variable, utf8, size, signed, value }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        scalar = try c.decode(Bool.self, forKey: .scalar)
        variable = try c.decodeIfPresent(Bool.self, forKey: .variable)
        utf8 = try c.decodeIfPresent(Bool.self, forKey: .utf8)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        signed = try c.decodeIfPresent(Bool.self, forKey: .signed)
        switch kind {
        case "bool": flag = try c.decode(Bool.self, forKey: .value)
        case "integer": integer = try c.decode(Int64.self, forKey: .value)
        default: text = try c.decode(String.self, forKey: .value)        // text, or a real as float.hex
        }
    }
}

struct HSPYGoldenDataset: Decodable {
    var dtype: String
    var shape: [Int]
    var chunks: [Int]?
    var compression: String?
    var sha256: String?
    var strings: [String]?
    var attributes: [String: HSPYGoldenAttribute]
}

struct HSPYGoldenLayout: Decodable {
    var rootAttributes: [String: HSPYGoldenAttribute]
    var experimentsAttributes: [String: HSPYGoldenAttribute]
    var experiment: String
    var groups: [String]
    var attributes: [String: [String: HSPYGoldenAttribute]]
    var datasets: [String: HSPYGoldenDataset]
    var fileIO: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case rootAttributes = "root_attributes", experimentsAttributes = "experiments_attributes", experiment, groups, attributes
        case datasets, fileIO = "file_io"
    }
}

struct HSPYPlanted: Decodable {
    var name: String
    var kind: String
    var title: String
    var dtype: String
    var shape: [Int]
    var axes: [HSPYPlantedAxis]
    var metadata: [HSPYPlantedEntry]
    var dataSHA256: String
    var hyperspyClass: String
    var layout: HSPYGoldenLayout

    enum CodingKeys: String, CodingKey {
        case name, kind, title, dtype, shape, axes, metadata, dataSHA256 = "data_sha256", hyperspyClass = "hyperspy_class", layout
    }
}

enum HSPYGolden {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func load() throws -> HSPYGoldenFile {
        try JSONDecoder().decode(HSPYGoldenFile.self, from: Data(contentsOf: fixtures.appendingPathComponent("hyperspy-layout.json")))
    }

    /// The planted signals' names, for parameterized tests (empty when the fixture does not decode; `theGoldenIsPinned` then fails).
    static let names: [String] = (try? load().signals.map(\.name)) ?? []

    static func planted(_ name: String) throws -> HSPYPlanted {
        let signals = try load().signals
        return try #require(signals.first { $0.name == name }, "\(name) is not planted")
    }

    /// The fixed FileIO time of the tests' files.
    static let timestamp = Date(timeIntervalSince1970: 1_795_000_000)
    static let software = "FormatoKit tests (FormatoHSPYTests)"

    static func dataType(_ numpy: String) -> FormatoDataType? {
        ["uint8": .uint8, "int8": .int8, "uint16": .uint16, "int16": .int16, "uint32": .uint32, "int32": .int32, "int64": .int64,
         "uint64": .uint64, "float32": .float32, "float64": .float64,
         "|u1": .uint8, "|i1": .int8, "<u2": .uint16, "<i2": .int16, "<u4": .uint32, "<i4": .int32, "<i8": .int64, "<u8": .uint64,
         "<f4": .float32, "<f8": .float64][numpy]
    }

    /// tools/hspy-writer/generate.py `data_rule`: v(i) = (i * 2654435761 + 12345) mod 2^32 for the flat index i, mapped into the
    /// type exactly. Little-endian bytes in C order.
    static func plantedValues(_ type: FormatoDataType, count: Int, from first: Int = 0) -> Data {
        func v(_ i: Int) -> Int64 { Int64((UInt64(i) &* 2_654_435_761 &+ 12_345) & 0xFFFF_FFFF) }
        let indices = first..<(first + count)
        func bytes<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }       // Apple silicon is little-endian
        switch type {
        case .uint8: return bytes(indices.map { UInt8(v($0) % 256) })
        case .int8: return bytes(indices.map { Int8(v($0) % 256 - 128) })
        case .uint16: return bytes(indices.map { UInt16(v($0) % 65_536) })
        case .int16: return bytes(indices.map { Int16(v($0) % 65_536 - 32_768) })
        case .uint32: return bytes(indices.map { UInt32(v($0)) })
        case .int32: return bytes(indices.map { Int32(v($0) - (1 << 31)) })
        case .int64: return bytes(indices.map { v($0) * 4096 - (1 << 43) })
        case .uint64: return bytes(indices.map { UInt64(v($0)) << 20 })
        case .float32: return bytes(indices.map { Float(Double(v($0) % (1 << 20)) / 64.0 - 8192.0) })
        case .float64: return bytes(indices.map { Double(v($0)) / 1024.0 - Double(1 << 21) })
        case .rgb8, .rgba8, .rgb16, .rgba16: return Data()
        }
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func axes(_ planted: HSPYPlanted) -> [FormatoAxis] {
        planted.axes.map { FormatoAxis(name: $0.name, size: $0.size, scale: $0.scale, offset: $0.offset, units: $0.units, navigate: $0.navigate) }
    }

    /// The planted signal (its metadata entries marked "signal") and the options (those marked "options").
    static func signal(_ planted: HSPYPlanted) throws -> (FormatoSignal, HSPYSignalKind, HSPYWriteOptions) {
        let type = try #require(dataType(planted.dtype))
        let count = try FormatoArray.elementCount(planted.shape)
        let data = try FormatoArray(dataType: type, shape: planted.shape, bytes: plantedValues(type, count: count))
        let provenance = FormatoProvenance(file: "planted", source: "tools/hspy-writer/generate.py", rule: "planted")
        let entries = planted.metadata.filter { $0.via == "signal" }
            .map { FormatoMetadataEntry(key: $0.key, value: $0.value, units: nil, provenance: provenance) }
        var options = HSPYWriteOptions(software: software, timestamp: timestamp)
        for entry in planted.metadata where entry.via == "options" { options.metadata[entry.key] = entry.value }
        let kind = try #require(HSPYSignalKind(rawValue: planted.kind))
        // A signal type that disagrees with the kind: the kind is what is written.
        let signal = FormatoSignal(title: planted.title, signalType: "not read", axes: axes(planted),
                                   metadata: FormatoMetadata(entries), data: data)
        return (signal, kind, options)
    }

    // MARK: The comparison

    /// The kit-written file at `url` has the layout HyperSpy wrote for `planted`, attribute by attribute, except the
    /// documented differences: the data is not compressed, a list is a `_list_<N>_<key>` group of text attributes, and the
    /// FileIO entry is the kit's.
    static func expectLayout(_ url: URL, _ planted: HSPYPlanted) throws {
        let golden = planted.layout
        let reader = try HDF5Reader(url: url)
        let label = planted.name
        try expectAttributes(reader, "/", golden.rootAttributes, label)
        #expect(try reader.children(of: "/") == ["Experiments"], "\(label)")
        #expect(try reader.children(of: "/Experiments") == [golden.experiment], "\(label)")
        try expectAttributes(reader, "/Experiments", golden.experimentsAttributes, label)
        let experiment = "/Experiments/" + golden.experiment
        func relative(_ path: String) -> String { String(path.dropFirst(experiment.count + 1)) }

        // Groups and datasets, the FileIO subtree and the lists aside.
        let walked = try reader.walk(from: experiment)
        let fileIO = "metadata/General/FileIO"
        func isFileIO(_ path: String) -> Bool { path == fileIO || path.hasPrefix(fileIO + "/") }
        let kitGroups = walked.filter { $0.kind == .group }.map { relative($0.path) }
        let listGroups = kitGroups.filter { ($0.split(separator: "/").last ?? "").hasPrefix("_list_") }
        #expect(kitGroups.filter { !isFileIO($0) && !listGroups.contains($0) }.sorted() == golden.groups.filter { !isFileIO($0) }.sorted(),
                "\(label): the groups")
        let kitDatasets = walked.filter { $0.kind == .dataset }.map { relative($0.path) }
        #expect(kitDatasets == ["data"], "\(label): the kit writes one dataset")

        // Every group's attributes.
        for group in golden.groups where !isFileIO(group) {
            try expectAttributes(reader, experiment + "/" + group, golden.attributes[group] ?? [:], label)
        }
        try expectAttributes(reader, experiment, golden.attributes[""] ?? [:], label)

        // A list: HyperSpy's `_list_<key>` dataset of strings is the kit's `_list_<N>_<key>` group of text attributes.
        let goldenLists = golden.datasets.filter { $0.key != "data" }
        #expect(goldenLists.count == listGroups.count, "\(label): the lists")
        for (path, list) in goldenLists {
            let strings = try #require(list.strings, "\(label): \(path) is not a list of text")
            var parts = path.split(separator: "/").map(String.init)
            let leaf = parts.removeLast()
            let key = String(leaf.dropFirst("_list_".count))
            let group = (parts + ["_list_\(strings.count)_\(key)"]).joined(separator: "/")
            #expect(listGroups.contains(group), "\(label): \(group)")
            let names = try reader.attributeNames(of: experiment + "/" + group)
            let width = String(strings.count - 1).count
            #expect(names == strings.indices.map { String(repeating: "0", count: width - String($0).count) + String($0) },
                    "\(label): \(group) items")
            for (name, text) in zip(names, strings) {
                #expect(try reader.attribute(name, of: experiment + "/" + group) == .text(text), "\(label): \(group)@\(name)")
                try expectText(reader, experiment + "/" + group, name, label)
            }
        }

        // The data: HyperSpy's type, shape and chunk shape; no filter (HyperSpy: gzip); the planted bytes.
        let data = try #require(golden.datasets["data"])
        let info = try reader.datasetInfo(experiment + "/data")
        let storedType = try #require(dataType(data.dtype))
        #expect(info.type == .numeric(storedType), "\(label): data type")
        #expect(info.shape == data.shape && data.shape == planted.shape, "\(label): data shape")
        #expect(try reader.chunkShape(of: experiment + "/data") == data.chunks, "\(label): HyperSpy's chunk shape")
        #expect(data.compression == "gzip", "\(label): HyperSpy compresses")
        #expect(try reader.filterCount(of: experiment + "/data") == 0, "\(label): the kit does not")
        #expect(data.attributes.isEmpty && (try reader.attributeNames(of: experiment + "/data")).isEmpty, "\(label)")
        let stored = try reader.readDataset(experiment + "/data")
        #expect(sha256(stored.bytes) == data.sha256 && data.sha256 == planted.dataSHA256, "\(label): the data")

        // FileIO: the kit's entry.
        #expect(golden.fileIO.keys.sorted() == ["metadata/General/FileIO/0"], "\(label)")
        let entry = experiment + "/metadata/General/FileIO/0"
        #expect(kitGroups.filter(isFileIO).sorted() == [fileIO, fileIO + "/0"], "\(label): FileIO")
        #expect(try reader.attributeNames(of: entry) == ["io_plugin", "operation", "software", "timestamp"], "\(label)")
        #expect(try reader.attribute("operation", of: entry) == .text("save"))
        #expect(try reader.attribute("io_plugin", of: entry) == .text("FormatoHSPY"))
        #expect(try reader.attribute("software", of: entry) == .text(software))
        #expect(try reader.attribute("timestamp", of: entry) == .text("2026-11-18T11:06:40.000Z"))
        for name in ["io_plugin", "operation", "software", "timestamp"] { try expectText(reader, entry, name, label) }
    }

    /// The object's attribute names equal h5py's, and each attribute has h5py's class, size and value.
    static func expectAttributes(_ reader: HDF5Reader, _ path: String, _ golden: [String: HSPYGoldenAttribute], _ label: String) throws {
        let names = try reader.attributeNames(of: path)
        #expect(names == golden.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }, "\(label): the attributes of \(path)")
        for (name, want) in golden where names.contains(name) {
            let at = "\(label): \(path)@\(name)"
            #expect(want.scalar, "\(at): h5py wrote a scalar")
            let facts = try reader.attributeTypeFacts(name, of: path)
            #expect(facts.shape == [], "\(at) is a scalar")
            switch want.kind {
            case "string":
                #expect(want.variable == true && want.utf8 == true, "\(at): h5py's text")
                try expectText(reader, path, name, label)
                let text = try #require(want.text)
                #expect(try reader.attribute(name, of: path) == .text(text), "\(at)")
            case "bool":
                let found = try reader.enumAttributeFacts(name, of: path)
                let e = try #require(found, "\(at) is not h5py's bool")
                #expect(e.size == 1 && e.baseClass == 0 && e.baseSize == 1 && e.baseSigned, "\(at)")
                #expect(e.members == ["FALSE": 0, "TRUE": 1], "\(at)")
                let flag = try #require(want.flag)
                #expect(e.values == [flag ? 1 : 0], "\(at)")
            case "float":
                #expect(facts.typeClass == 1 && facts.size == want.size && want.size == 8, "\(at): float64")
                let hex = try #require(want.text)
                let bits = try #require(Double(hex), "\(at): \(hex)").bitPattern
                guard case .real(let got) = try reader.attribute(name, of: path) else {
                    Issue.record("\(at) is not a real")
                    continue
                }
                #expect(got.bitPattern == bits, "\(at): \(got)")
            case "integer":
                #expect(facts.typeClass == 0 && facts.size == want.size && want.size == 8 && facts.signed && want.signed == true, "\(at): int64")
                let integer = try #require(want.integer)
                #expect(try reader.attribute(name, of: path) == .integer(integer), "\(at)")
            default:
                Issue.record("\(at): the golden has class \(want.kind)")
            }
        }
    }

    /// The attribute is variable-length UTF-8 text, scalar: what h5py writes for a Python `str`.
    static func expectText(_ reader: HDF5Reader, _ path: String, _ name: String, _ label: String) throws {
        let facts = try reader.attributeTypeFacts(name, of: path)
        #expect(facts.typeClass == 3 && facts.variableLengthText && facts.utf8Text && facts.shape == [],
                "\(label): \(path)@\(name) is not variable-length UTF-8 text: \(facts)")
    }
}

func hspyScratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("formato-hspy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
