//
//  HSPYReaderTests.swift
//  `HSPYReader` against RosettaSciIO 0.14.0's reading of the files HyperSpy 2.5.0 writes (pin H4, FormatoKit#98;
//  tools/hspy-reader/generate.py, Fixtures/reader): pin H2's small planted signals saved by HyperSpy (gzip, shuffle,
//  HyperSpy's chunks, lists as `_list_<key>` datasets; rank 1 to 4, uint8 to float64, text with Å and µ, lists of elements),
//  the same EDS map in small chunks with partial edge chunks, int8, int64 and uint64 as three experiments of one file, a
//  signal saved lazily, and exspy 0.3.2's public `EDS_SEM_TM002` (layout 3.0). Each experiment's title, signal type, data
//  (type, shape, bytes), axes (scale and offset to the bit) and metadata tree (keys in RosettaSciIO's order, values exact)
//  equal RosettaSciIO's. Each refusal is named: complex data, non-uniform and functional axes, a ragged signal, five
//  dimensions, a layout older than 1.2, no experiment, an HDF5 file that is not HyperSpy's. And the kit reads back what
//  the kit writes: every pin H2 signal written by `HSPYWriter` is read back equal, and written again is HyperSpy's layout.
//

import Foundation
import Testing
import FormatoCore
import FormatoHDF5
import FormatoHSPY

struct HSPYReaderTruth: Decodable {
    var versions: [String: String]
    var tm002SourceSHA256: String
    var files: [HSPYTruthFile]

    enum CodingKeys: String, CodingKey { case versions, tm002SourceSHA256 = "tm002_source_sha256", files }
}

struct HSPYTruthFile: Decodable {
    var file: String
    var sha256: String
    var experiments: [HSPYTruthExperiment]?
    /// The kit's `HSPYError` case by experiment name ("(file)" for a whole file).
    var refusals: [String: String]?
}

struct HSPYTruthExperiment: Decodable {
    var name: String
    var title: String
    var signalType: String
    var dtype: String
    var shape: [Int]
    var dataSHA256: String
    var axes: [HSPYTruthAxis]
    var metadata: [HSPYTruthEntry]

    enum CodingKeys: String, CodingKey {
        case name, title, signalType = "signal_type", dtype, shape, dataSHA256 = "data_sha256", axes, metadata
    }
}

struct HSPYTruthAxis: Decodable {
    var axis: FormatoAxis

    enum CodingKeys: String, CodingKey { case name, size, scale, offset, units, navigate }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func real(_ key: CodingKeys) throws -> Double {
            let hex = try c.decode(String.self, forKey: key)
            guard let value = Double(hex) else { throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: hex) }
            return value
        }
        axis = FormatoAxis(name: try c.decodeIfPresent(String.self, forKey: .name), size: try c.decode(Int.self, forKey: .size),
                           scale: try real(.scale), offset: try real(.offset), units: try c.decode(String.self, forKey: .units),
                           navigate: try c.decode(Bool.self, forKey: .navigate))
    }
}

/// One metadata entry as the generator flattened RosettaSciIO's tree: a number as `float.hex`.
struct HSPYTruthEntry: Decodable {
    var key: String
    var value: FormatoValue

    enum CodingKeys: String, CodingKey { case key, type, value }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        switch try c.decode(String.self, forKey: .type) {
        case "number":
            let hex = try c.decode(String.self, forKey: .value)
            guard let number = Double(hex) else { throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: hex) }
            value = .number(number)
        case "flag": value = .flag(try c.decode(Bool.self, forKey: .value))
        case "texts": value = .texts(try c.decode([String].self, forKey: .value))
        default: value = .text(try c.decode(String.self, forKey: .value))
        }
    }
}

enum HSPYReaderPin {
    static let folder = HSPYGolden.fixtures.appendingPathComponent("reader")

    static func load() throws -> HSPYReaderTruth {
        try JSONDecoder().decode(HSPYReaderTruth.self, from: Data(contentsOf: folder.appendingPathComponent("reader-truth.json")))
    }

    /// The files the kit reads, for parameterized tests (empty when the truth does not decode; `theTruthIsPinned` then fails).
    static let readable: [String] = (try? load().files.filter { $0.experiments != nil }.map(\.file)) ?? []

    static func file(_ name: String) throws -> HSPYTruthFile {
        let files = try load().files
        return try #require(files.first { $0.file == name }, "\(name) is not in reader-truth.json")
    }

    /// Equal, a number to the bit.
    static func same(_ a: FormatoValue, _ b: FormatoValue) -> Bool {
        if case .number(let x) = a, case .number(let y) = b { return x.bitPattern == y.bitPattern }
        return a == b
    }

    static func sameAxes(_ a: [FormatoAxis], _ b: [FormatoAxis]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.bitwiseEquals($1) }
    }

    /// The case's name, as the generator writes it ("complexData").
    static func caseName(_ error: HSPYError) -> String { String(String(describing: error).prefix { $0 != "(" }) }
}

@Suite(.serialized) struct HSPYReaderTests {

    // MARK: Pin H4

    @Test func theTruthIsPinned() throws {
        let truth = try HSPYReaderPin.load()
        #expect(truth.versions["hyperspy"] == "2.5.0" && truth.versions["rosettasciio"] == "0.14.0")
        #expect(truth.versions["exspy"] == "0.3.2" && truth.versions["pyxem"] == "0.21.0" && truth.versions["h5py"] == "3.16.0")
        let experiments = truth.files.compactMap(\.experiments).flatMap { $0 }
        #expect(HSPYReaderPin.readable.count == 18 && truth.files.count == 22)
        #expect(Set(experiments.map(\.shape.count)) == [1, 2, 3, 4])
        #expect(Set(experiments.map(\.dtype)) == ["uint8", "int8", "uint16", "int16", "uint32", "int32", "int64", "uint64", "float32",
                                                  "float64"])
        #expect(Set(experiments.map(\.signalType)) == ["", "EDS_TEM", "EDS_SEM", "EELS", "electron_diffraction"])
        // Pin H2's small signals, saved by HyperSpy: RosettaSciIO reads the planted values back.
        let golden = try HSPYGolden.load()
        var saved = 0
        for planted in golden.signals {
            guard let file = truth.files.first(where: { $0.file == planted.name + ".hspy" }) else { continue }
            saved += 1
            let experiment = try #require(file.experiments?.first)
            #expect(experiment.dataSHA256 == planted.dataSHA256 && experiment.title == planted.title, "\(planted.name)")
        }
        #expect(saved == 14)
        // exspy's example is its wheel's file, unchanged.
        #expect(try HSPYReaderPin.file("EDS_SEM_TM002.hspy").sha256 == truth.tm002SourceSHA256)
    }

    @Test(arguments: HSPYReaderPin.readable)
    func theKitReadsWhatHyperSpyWrites(_ file: String) throws {
        let entry = try HSPYReaderPin.file(file)
        let url = HSPYReaderPin.folder.appendingPathComponent(file)
        #expect(HSPYGolden.sha256(try Data(contentsOf: url)) == entry.sha256, "\(file): the committed fixture")
        let wanted = try #require(entry.experiments)
        let listed = try HSPYReader.experiments(url: url)
        #expect(listed.map(\.name) == wanted.map(\.name), "\(file): the experiments, in the file's order")
        for (want, got) in zip(wanted, listed) {
            let at = "\(file) \(want.name)"
            let type = try #require(HSPYGolden.dataType(want.dtype))
            let axes = want.axes.map(\.axis)
            #expect(got.refusal == nil && got.dataType == type && got.shape == want.shape, "\(at): \(got)")
            #expect(got.title == want.title && got.signalType == want.signalType, "\(at)")
            #expect(got.kind == HSPYSignalKind(signalType: want.signalType), "\(at)")
            #expect(HSPYReaderPin.sameAxes(got.axes, axes), "\(at): axes \(got.axes)")

            let signal = try HSPYReader.readStored(url: url, experiment: want.name)
            #expect(signal.title == want.title && signal.signalType == want.signalType, "\(at)")
            #expect(signal.data.dataType == type && signal.data.shape == want.shape, "\(at)")
            #expect(HSPYGolden.sha256(signal.data.bytes) == want.dataSHA256, "\(at): the data")
            #expect(HSPYReaderPin.sameAxes(signal.axes, axes), "\(at): axes \(signal.axes)")
            #expect(signal.metadata.keys == want.metadata.map(\.key), "\(at): the metadata keys \(signal.metadata.keys)")
            for (found, expected) in zip(signal.metadata.entries, want.metadata) where found.key == expected.key {
                #expect(HSPYReaderPin.same(found.value, expected.value), "\(at): \(found.key) = \(found.value), RosettaSciIO \(expected.value)")
            }
        }
    }

    @Test func exspysExampleReads() throws {
        let url = HSPYReaderPin.folder.appendingPathComponent("EDS_SEM_TM002.hspy")
        let signal = try HSPYReader.readStored(url: url)
        // Layout 3.0: no `_type` on the axis, an empty name (not none), no `attributes` group.
        #expect(signal.axes.count == 1 && signal.axes[0].name == "" && signal.axes[0].units == "keV" && !signal.axes[0].navigate)
        #expect(signal.data.dataType == .int32 && signal.data.shape == [1024])
        #expect(HSPYSignalKind(signalType: signal.signalType) == .edsSEM)
        #expect(signal.metadata["Sample.elements"]?.value == .texts(["Al", "C", "Cu", "Mn", "Zr"]))
        #expect(signal.metadata["Signal.binned"]?.value == .flag(true))
        #expect(signal.metadata["Acquisition_instrument.SEM.beam_energy"]?.value == .number(10))
        #expect(signal.metadata["Acquisition_instrument.SEM.beam_energy"]?.provenance.rule == "rsciio hspy _group2dict")
    }

    @Test func aLazyReadCrossesChunks() throws {
        let url = HSPYReaderPin.folder.appendingPathComponent("chunked-edges.hspy")
        #expect(try HDF5Reader(url: url).chunkShape(of: "/Experiments/EDS map/data") == [2, 3, 7])
        let lazy = try HSPYReader.read(url: url)
        let whole = try HSPYReader.readStored(url: url).data
        #expect(lazy.array.shape == [3, 4, 20] && lazy.array.dataType == .uint16)
        for (start, count) in [([1, 2, 5], [2, 2, 11]), ([0, 0, 0], [3, 4, 20]), ([2, 3, 19], [1, 1, 1]), ([1, 0, 0], [0, 4, 20])] {
            let slab = try lazy.array.read(start: start, count: count)
            #expect(try slab == whole.slab(start: start, count: count), "\(start) \(count)")
        }
        #expect(throws: FormatoArrayError.self) { _ = try lazy.array.read(start: [2, 0, 0], count: [2, 4, 20]) }
        // A lazy read of a file the kit wrote, too.
        let planted = try HSPYGolden.planted("eds-sem-map-u16")
        #expect(HSPYGolden.sha256(whole.bytes) == planted.dataSHA256)
    }

    @Test func eachRefusalIsNamed() throws {
        let url = HSPYReaderPin.folder.appendingPathComponent("refusals.hspy")
        let expected: [String: HSPYError] = [
            "complex": .complexData(experiment: "complex"),
            "functional": .nonUniformAxis(experiment: "functional", index: 0, type: "FunctionalDataAxis"),
            "non-uniform": .nonUniformAxis(experiment: "non-uniform", index: 0, type: "DataAxis"),
            "ragged": .raggedSignal(experiment: "ragged"),
            "rank 5": .unsupportedRank(5),
        ]
        let cases = try #require(try HSPYReaderPin.file("refusals.hspy").refusals)
        #expect(Set(cases.keys) == Set(expected.keys))
        let listed = try HSPYReader.experiments(url: url)
        #expect(listed.map(\.name) == ["complex", "functional", "non-uniform", "ragged", "rank 5"])
        for experiment in listed {
            let want = try #require(expected[experiment.name])
            #expect(experiment.refusal == want && experiment.dataType == nil && experiment.axes.isEmpty, "\(experiment.name)")
            #expect(HSPYReaderPin.caseName(want) == cases[experiment.name], "\(experiment.name)")
            #expect(throws: want) { _ = try HSPYReader.read(url: url, experiment: experiment.name) }
            #expect(want.errorDescription?.isEmpty == false)
        }
        #expect(listed.first(where: { $0.name == "rank 5" })?.shape == [2, 2, 2, 2, 3])
        #expect(listed.first(where: { $0.name == "complex" })?.title == "complex")
        // No experiment named: the first, refused.
        #expect(throws: HSPYError.complexData(experiment: "complex")) { _ = try HSPYReader.readStored(url: url) }

        // Whole files.
        let files: [(String, HSPYError)] = [
            ("refused-version-1.1.hspy", .unsupportedVersion("1.1")),
            ("refused-no-experiment.hspy", .noExperiment("refused-no-experiment.hspy")),
            ("refused-not-hyperspy.hspy", .notHyperSpyFile("refused-not-hyperspy.hspy")),
        ]
        for (file, want) in files {
            #expect(try HSPYReaderPin.file(file).refusals?["(file)"] == HSPYReaderPin.caseName(want), "\(file)")
            let at = HSPYReaderPin.folder.appendingPathComponent(file)
            #expect(throws: want) { _ = try HSPYReader.experiments(url: at) }
            #expect(throws: want) { _ = try HSPYReader.read(url: at) }
        }
        let image = HSPYReaderPin.folder.appendingPathComponent("image-u8.hspy")
        #expect(throws: HSPYError.unknownExperiment("Image")) { _ = try HSPYReader.read(url: image, experiment: "Image") }
        #expect(throws: HDF5FileError.self) { _ = try HSPYReader.read(url: HSPYGolden.fixtures.appendingPathComponent("hyperspy-layout.json")) }
    }

    // MARK: The kit's own files

    @Test(arguments: HSPYGolden.names)
    func theKitReadsWhatTheKitWrites(_ name: String) throws {
        let planted = try HSPYGolden.planted(name)
        let (signal, kind, options) = try HSPYGolden.signal(planted)
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(name).hspy")
        try HSPYWriter.write(signal, kind: kind, options: options, to: url, cancelled: { false })

        let listed = try HSPYReader.experiments(url: url)
        #expect(listed.count == 1 && listed.first?.title == planted.title && listed.first?.kind == kind, "\(name)")
        let back = try HSPYReader.readStored(url: url)
        #expect(back.data == signal.data, "\(name): the data")
        #expect(HSPYReaderPin.sameAxes(back.axes, signal.axes), "\(name): the axes \(back.axes)")
        #expect(back.title == planted.title && back.signalType == kind.signalType, "\(name)")
        for entry in planted.metadata {
            #expect(back.metadata[entry.key]?.value == entry.value, "\(name): \(entry.key)")
        }
        #expect(back.metadata["General.title"]?.value == .text(planted.title))
        #expect(back.metadata["Signal.signal_type"]?.value == .text(kind.signalType))
        #expect(back.metadata["General.FileIO.0.io_plugin"]?.value == .text("FormatoHSPY"))
        #expect(back.metadata["General.FileIO.0.software"]?.value == .text(HSPYGolden.software))
        #expect(back.metadata["_HyperSpy.Folding.unfolded"]?.value == .flag(false))
        #expect(back.metadata["_HyperSpy.Folding.original_shape"] == nil, "\(name): \"_None_\" is none")
        #expect(back.metadata.keys.count == planted.metadata.count + 8, "\(name): \(back.metadata.keys)")

        // Written again from what was read: HyperSpy's layout once more (the writer leaves out the keys it writes itself).
        let again = dir.appendingPathComponent("again.hspy")
        let backKind = try #require(HSPYSignalKind(signalType: back.signalType))
        try HSPYWriter.write(back, kind: backKind,
                             options: HSPYWriteOptions(software: HSPYGolden.software, timestamp: HSPYGolden.timestamp), to: again)
        try HSPYGolden.expectLayout(again, planted)

        // The lazy signal reads the same values a slab at a time.
        let lazy = try HSPYReader.read(url: url)
        let start = planted.shape.map { $0 / 2 }, count = planted.shape.map { $0 - $0 / 2 }
        #expect(try lazy.array.read(start: start, count: count) == signal.data.slab(start: start, count: count), "\(name)")
    }
}
