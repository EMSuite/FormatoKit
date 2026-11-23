//
//  HSPYWriterTests.swift
//  `HSPYWriter.write` against the layout HyperSpy 2.5.0 writes (pin H2, FormatoKit#142; tools/hspy-writer/generate.py): each
//  planted signal (rank 1 to 4; uint8, uint16, int16, uint32, int32, float32, float64; text with Å and µ; lists of elements;
//  EDS, EELS, electron diffraction and generic; data large enough for HyperSpy's chunk rule to cut) is written by the kit and
//  read back with the kit's own HDF5 layer: every group, every attribute's name, HDF5 class (variable-length UTF-8 text, h5py's
//  bool, float64, int64) and value, the data's type, shape, chunk shape and bytes equal what HyperSpy wrote for the same
//  signal (Fixtures/hyperspy-layout.json). The documented differences: no compression, a list as a `_list_<N>_<key>` group,
//  the kit's FileIO entry.
//
//  HyperSpy's reading of the kit's files (class, axes, data, metadata; `hs.load` also with `lazy=True`) is the Mac or nightly
//  step: FORMATO_HSPY_OUT=<folder> swift test -c release --filter HSPYWriterTests, then tools/hspy-writer/check.py <folder>.
//

import Foundation
import Testing
import FormatoCore
import FormatoHDF5
@testable import FormatoHSPY

@Suite(.serialized) struct HSPYWriterTests {

    // MARK: Pin H2

    @Test func theGoldenIsPinned() throws {
        let golden = try HSPYGolden.load()
        #expect(golden.versions["hyperspy"] == "2.5.0" && golden.versions["rosettasciio"] == "0.14.0")
        #expect(golden.versions["exspy"] == "0.3.2" && golden.versions["pyxem"] == "0.21.0" && golden.versions["h5py"] == "3.16.0")
        #expect(golden.signals.count == 18 && HSPYGolden.names.count == 18)
        #expect(Set(golden.signals.map(\.shape.count)) == [1, 2, 3, 4])
        #expect(Set(golden.signals.map(\.dtype)) == ["uint8", "uint16", "int16", "uint32", "int32", "float32", "float64"])
        #expect(Set(golden.signals.map(\.kind)) == Set(HSPYSignalKind.allCases.map(\.rawValue)))
        #expect(Set(golden.signals.map(\.hyperspyClass)) == ["Signal1D", "Signal2D", "EDSTEMSpectrum", "EDSSEMSpectrum", "EELSSpectrum",
                                                             "ElectronDiffraction2D"])
        // The kit's planted values are the generator's.
        for planted in golden.signals {
            let type = try #require(HSPYGolden.dataType(planted.dtype))
            let count = try FormatoArray.elementCount(planted.shape)
            let values = HSPYGolden.plantedValues(type, count: count)
            #expect(HSPYGolden.sha256(values) == planted.dataSHA256, "\(planted.name)")
        }
    }

    @Test(arguments: HSPYGolden.names)
    func theKitWritesWhatHyperSpyWrites(_ name: String) throws {
        let planted = try HSPYGolden.planted(name)
        let (signal, kind, options) = try HSPYGolden.signal(planted)
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(name).hspy")
        try HSPYWriter.write(signal, kind: kind, options: options, to: url, cancelled: { false })
        try HSPYGolden.expectLayout(url, planted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["\(name).hspy"], "no scratch is left")
        // The Mac and nightly step: the files tools/hspy-writer/check.py loads in HyperSpy.
        if let out = ProcessInfo.processInfo.environment["FORMATO_HSPY_OUT"] {
            let folder = URL(fileURLWithPath: out)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(url.lastPathComponent))
            try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
    }

    // MARK: The chunk rule

    /// RosettaSciIO 0.14.0 `get_signal_chunks(shape, dtype, signal_axes)`, run for these shapes on 23 Nov 2026 (the golden pins
    /// four more through HyperSpy's own save).
    @Test func theChunkRuleIsRosettaSciIOs() {
        let cases: [(shape: [Int], bytes: Int, signal: [Int], chunks: [Int])] = [
            ([256, 256, 2048], 2, [2], [15, 15, 2048]),
            ([10, 4096, 4096], 4, [1, 2], [1, 4096, 4096]),
            ([100, 100, 128, 128], 2, [2, 3], [5, 5, 128, 128]),
            ([3, 500, 500, 64], 8, [3], [3, 25, 25, 64]),
            ([2, 7, 300, 1000], 1, [3], [2, 7, 71, 1000]),
            ([1000], 8, [0], [1000]),
            ([40, 30], 4, [0, 1], [40, 30]),
            ([5, 2000], 2, [1], [5, 2000]),
            ([50, 2, 256, 256], 2, [2, 3], [2, 2, 256, 256]),
            ([1, 1, 64, 64], 2, [2, 3], [1, 1, 64, 64]),
        ]
        for c in cases {
            #expect(HSPYLayout.hyperSpyChunks(shape: c.shape, byteSize: c.bytes, signalAxes: c.signal) == c.chunks, "\(c.shape)")
        }
    }

    @Test func aChunkShapeCanBeAsked() throws {
        let planted = try HSPYGolden.planted("eds-tem-map-chunked-u16")
        let (signal, kind, baseOptions) = try HSPYGolden.signal(planted)
        var options = baseOptions
        options.chunkShape = [1, 48, 512]
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("asked.hspy")
        try HSPYWriter.write(signal, kind: kind, options: options, to: url)
        let reader = try HDF5Reader(url: url)
        #expect(try reader.chunkShape(of: "/Experiments/Chunked EDS map/data") == [1, 48, 512])
        #expect(HSPYGolden.sha256(try reader.readDataset("/Experiments/Chunked EDS map/data").bytes) == planted.dataSHA256)
    }

    // MARK: Metadata and names

    @Test func theKindNamesTheClassAndItsPackage() {
        #expect(HSPYSignalKind.allCases.map(\.signalType) == ["", "EDS_TEM", "EDS_SEM", "EELS", "electron_diffraction"])
        #expect(HSPYSignalKind.allCases.map(\.package) == ["hyperspy", "exspy", "exspy", "exspy", "pyxem"])
        #expect(HSPYSignalKind(signalType: "EELS") == .eels && HSPYSignalKind(signalType: "") == .generic)
        #expect(HSPYSignalKind(signalType: "CL") == nil)
        #expect(HSPYSignalKind.allCases.map(\.signalDimension) == [nil, 1, 1, 1, 2])
    }

    @Test func theOptionsTitleAndMetadataWin() throws {
        let planted = try HSPYGolden.planted("eels-map-f64")
        let (signal, kind, baseOptions) = try HSPYGolden.signal(planted)
        var options = baseOptions
        options.title = "Other/title"
        options.metadata["General.authors"] = .text("µ-lab only")             // replaces the signal's entry
        options.metadata["Sample.elements"] = .texts(["C", "N"])
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("title.hspy")
        try HSPYWriter.write(signal, kind: kind, options: options, to: url)
        let reader = try HDF5Reader(url: url)
        #expect(try reader.children(of: "/Experiments") == ["Other-title"])
        let metadata = "/Experiments/Other-title/metadata"
        #expect(try reader.attribute("title", of: metadata + "/General") == .text("Other/title"))
        #expect(try reader.attribute("authors", of: metadata + "/General") == .text("µ-lab only"))
        #expect(try reader.attribute("0", of: metadata + "/Sample/_list_2_elements") == .text("C"))
        #expect(try reader.attribute("1", of: metadata + "/Sample/_list_2_elements") == .text("N"))
        // The signal's own title, type and FileIO entries are not taken from its metadata.
        let entries = signal.metadata.entries + [
            FormatoMetadataEntry(key: "General.title", value: .text("ignored"), units: nil, provenance: signal.metadata.entries[0].provenance),
            FormatoMetadataEntry(key: "Signal.signal_type", value: .text("EDS_TEM"), units: nil, provenance: signal.metadata.entries[0].provenance),
            FormatoMetadataEntry(key: "General.FileIO.0.operation", value: .text("load"), units: nil, provenance: signal.metadata.entries[0].provenance),
        ]
        let owned = FormatoSignal(title: "Own", signalType: "EDS_TEM", axes: signal.axes, metadata: FormatoMetadata(entries), data: signal.data)
        let ownURL = dir.appendingPathComponent("own.hspy")
        try HSPYWriter.write(owned, kind: .eels, options: HSPYWriteOptions(), to: ownURL)
        let own = try HDF5Reader(url: ownURL)
        #expect(try own.attribute("title", of: "/Experiments/Own/metadata/General") == .text("Own"))
        #expect(try own.attribute("signal_type", of: "/Experiments/Own/metadata/Signal") == .text("EELS"))
        #expect(try own.attribute("operation", of: "/Experiments/Own/metadata/General/FileIO/0") == .text("save"))
        #expect(try own.attributeNames(of: "/Experiments/Own/metadata/General/FileIO/0") == ["io_plugin", "operation", "timestamp"])
        // An empty title is HyperSpy's `__unnamed__` group.
        let unnamed = dir.appendingPathComponent("unnamed.hspy")
        try HSPYWriter.write(signal, kind: kind, options: HSPYWriteOptions(title: ""), to: unnamed)
        #expect(try HDF5Reader(url: unnamed).children(of: "/Experiments") == ["__unnamed__"])
    }

    // MARK: Refusals

    @Test func everyRefusalIsNamedAndLeavesNothing() throws {
        let planted = try HSPYGolden.planted("eds-sem-map-u16")
        let (signal, kind, _) = try HSPYGolden.signal(planted)
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("refused.hspy")
        let axes = signal.axes
        func refused(_ error: HSPYError, shape: [Int]? = nil, type: FormatoDataType = .uint16, axes theAxes: [FormatoAxis]? = nil,
                     kind theKind: HSPYSignalKind? = nil, options: HSPYWriteOptions = HSPYWriteOptions()) {
            #expect(throws: error) {
                _ = try HSPYWriter.open(shape: shape ?? signal.data.shape, dataType: type, axes: theAxes ?? axes, kind: theKind ?? kind,
                                        options: options, to: url, cancelled: { false })
            }
        }
        let nav = FormatoAxis(name: "n", size: 3, scale: 1, offset: 0, units: "", navigate: true)
        let sig = FormatoAxis(name: "s", size: 3, scale: 1, offset: 0, units: "", navigate: false)
        refused(.unsupportedDataType(.rgb8), type: .rgb8)
        refused(.unsupportedRank(5), shape: [3, 3, 3, 3, 3], axes: [nav, nav, nav, sig, sig])
        refused(.axesDoNotMatchShape(sizes: [3, 4], shape: [3, 4, 20]), axes: Array(axes.prefix(2)))
        refused(.axesDoNotMatchShape(sizes: [3, 3, 3], shape: [3, 4, 20]), axes: [nav, nav, sig])
        refused(.emptyDimension(index: 1), shape: [3, 0, 3], axes: [nav, FormatoAxis(name: nil, size: 0, scale: 1, offset: 0, units: "", navigate: true), sig])
        refused(.nonFiniteAxis(index: 0), shape: [3, 3],
                axes: [FormatoAxis(name: nil, size: 3, scale: .nan, offset: 0, units: "", navigate: true), sig], kind: .generic)
        refused(.noSignalAxis, shape: [3, 3], axes: [nav, nav], kind: .generic)
        refused(.signalAxesNotLast, shape: [3, 3], axes: [sig, nav], kind: .generic)
        refused(.signalDimension(kind: .edsSEM, expected: 1, found: 2), shape: [3, 3, 3], axes: [nav, sig, sig])
        refused(.signalDimension(kind: .electronDiffraction, expected: 2, found: 1), kind: .electronDiffraction)
        refused(.invalidTitle(".."), options: HSPYWriteOptions(title: ".."))
        refused(.invalidTitle("a\0b"), options: HSPYWriteOptions(title: "a\0b"))
        refused(.invalidMetadataKey("A..b"), options: HSPYWriteOptions(metadata: ["A..b": .number(1)]))
        refused(.invalidMetadataKey("A/b"), options: HSPYWriteOptions(metadata: ["A/b": .number(1)]))
        refused(.invalidMetadataKey("Sample._list_3_x"), options: HSPYWriteOptions(metadata: ["Sample._list_3_x": .number(1)]))
        refused(.reservedMetadataKey("General.title"), options: HSPYWriteOptions(metadata: ["General.title": .text("x")]))
        refused(.reservedMetadataKey("General.FileIO.1.operation"), options: HSPYWriteOptions(metadata: ["General.FileIO.1.operation": .text("x")]))
        refused(.reservedMetadataKey("_HyperSpy.Folding.unfolded"), options: HSPYWriteOptions(metadata: ["_HyperSpy.Folding.unfolded": .flag(true)]))
        refused(.conflictingMetadataKeys("A.b", "A.b.c"), options: HSPYWriteOptions(metadata: ["A.b": .number(1), "A.b-x": .number(2), "A.b.c": .number(3)]))
        refused(.conflictingMetadataKeys("General", "General.title"), options: HSPYWriteOptions(metadata: ["General": .text("x")]))
        refused(.textWithNUL(key: "General.notes"), options: HSPYWriteOptions(metadata: ["General.notes": .texts(["ok", "a\0b"])]))
        refused(.invalidChunkShape([3, 4]), options: HSPYWriteOptions(chunkShape: [3, 4]))
        refused(.invalidChunkShape([3, 5, 20]), options: HSPYWriteOptions(chunkShape: [3, 5, 20]))
        refused(.invalidChunkShape([0, 4, 20]), options: HSPYWriteOptions(chunkShape: [0, 4, 20]))
        // The whole-signal writer refuses the same, from the signal's own axes.
        let wrong = FormatoSignal(title: "t", signalType: "", axes: Array(axes.reversed()), metadata: FormatoMetadata(), data: signal.data)
        #expect(throws: HSPYError.axesDoNotMatchShape(sizes: [20, 4, 3], shape: [3, 4, 20])) {
            try HSPYWriter.write(wrong, kind: .generic, to: url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty, "nothing was written")
        // An existing file stays as it was.
        try Data("keep".utf8).write(to: url)
        #expect(throws: HSPYError.self) { try HSPYWriter.write(wrong, kind: .generic, to: url) }
        #expect(try Data(contentsOf: url) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["refused.hspy"])
    }

    @Test func anExistingFileIsReplacedWhole() throws {
        let planted = try HSPYGolden.planted("spectrum-f64")
        let (signal, kind, options) = try HSPYGolden.signal(planted)
        let dir = try hspyScratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("spectrum-f64.hspy")
        try Data("an older file".utf8).write(to: url)
        try HSPYWriter.write(signal, kind: kind, options: options, to: url)
        try HSPYGolden.expectLayout(url, planted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["spectrum-f64.hspy"])
    }
}
