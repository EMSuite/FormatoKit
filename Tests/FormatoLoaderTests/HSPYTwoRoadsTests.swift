//
//  HSPYTwoRoadsTests.swift
//  Pin H3 (FormatoKit#151; docs/design/files-exports.md in the suite): the same content by two roads. RosettaSciIO 0.14.0 reading
//  a Velox EMD, DM3, DM4 or MSA fixture must equal RosettaSciIO reading the .hspy the kit writes from that fixture: the data
//  `array_equal`, every axis's name, units, size and navigate equal and its scale and offset to the bit (the tolerance the
//  formats' own pins use: dm-velox-pins and msa-pins compare axes bit for bit).
//
//  Here, on every run: each signal `FormatoLoader.load` gives for the fixture is written by `HSPYWriter.write` (the kind from its
//  signal type, generic otherwise) and read back by `HSPYReader.readStored`: data type, shape and bytes, and every axis field, equal
//  what was loaded. A committed fixture's signal the writer refuses is one of `typedRefusals` (a DM spectrum image, as RosettaSciIO's
//  reader gives it, has two signal axes; HyperSpy makes it a spectrum only in `post_process`), and is then written as generic; a
//  committed file RosettaSciIO itself raises on is `referenceRaises`, not one of H3's. The reference's side is the Mac and nightly step:
//      FORMATO_HSPY_OUT=<folder> swift test -c release --filter HSPYTwoRoadsTests
//      References/hspy-venv/bin/python -I -B tools/hspy-writer/check_h3.py <folder>
//  which reads `<folder>/h3/manifest.json` (each written file with its fixture, the signal's place in the kit's list and its
//  title) and compares RosettaSciIO's two readings. The public DM and Velox files of the pinned RosettaSciIO clone join the
//  committed fixtures where References/ and tools/test.sh's unzip are present (the files dm-velox-pins.json pins).
//

import Foundation
import Testing
import Formato
import FormatoCore
import FormatoHSPY

@Suite(.serialized) struct HSPYTwoRoadsTests {

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The committed fixtures the kit pins, repository-relative: RosettaSciIO's public MSA files, its EELS spectrum image DM4,
    /// the planted DM4 EDX spectrum image, and planted Velox files RosettaSciIO 0.14.0 reads (seven images; one EDS spectrum; an
    /// image and an EDS spectrum image).
    static let committed: [String] = [
        "Tests/FormatoMSATests/Fixtures/public/example1.msa",
        "Tests/FormatoMSATests/Fixtures/public/example2.msa",
        "Tests/FormatoMSATests/Fixtures/public/ISO_22029_2022_compliance.msa",
        "Tests/FormatoMSATests/Fixtures/public/ISO_22029_2022_compliance_XY_NCOLUMNS2.msa",
        "Tests/FormatoDMTests/Fixtures/rsciio-EELS_SI.dm4",
        "Tests/FormatoDMTests/Fixtures/demo-edx-tiny.dm4",
        "Tests/FormatoEMDTests/Fixtures/image-readers/velox-objects.emd",
        "Tests/FormatoEMDTests/Fixtures/spectra/sp-single.emd",
        "Tests/FormatoEMDTests/Fixtures/velox-spectrum-image/si-planted-v11.emd",
    ]

    /// A typed write the writer refuses on a committed fixture, by the signal's place in `FormatoLoader.load`'s list.
    struct TypedRefusal {
        let source: String
        let index: Int
        let error: HSPYError
    }

    /// RosettaSciIO 0.14.0's `digitalmicrograph.file_reader` gives a 3D spectrum image (`Meta Data.Format` "Spectrum image" or a
    /// `spim` group) as stored, energy first, with `navigate` [True, False, False] (its `ImageObject.navigate`: the last two axes
    /// are the signal's), and `signal_type` "EELS" or "EDS_TEM"; `hs.load` makes it a spectrum only through the dictionary's
    /// `post_process` (`to_signal1D`, energy last). `DMSignals` is the reader's dictionary and leaves `post_process` to its consumer,
    /// so the writer refuses it as exspy's spectrum kinds (one signal axis) and the test writes it as generic: data and axes still
    /// go by two roads. Checked against RosettaSciIO 0.14.0 on 2026-11-25.
    static let typedRefusals: [TypedRefusal] = [
        TypedRefusal(source: "Tests/FormatoDMTests/Fixtures/rsciio-EELS_SI.dm4", index: 0,
                     error: .signalDimension(kind: .eels, expected: 1, found: 2)),
        TypedRefusal(source: "Tests/FormatoDMTests/Fixtures/demo-edx-tiny.dm4", index: 3,
                     error: .signalDimension(kind: .edsTEM, expected: 1, found: 2)),
    ]

    /// Committed files RosettaSciIO 0.14.0 raises on, for every `select_type`: no reference reading, so not H3's. The kit refuses
    /// at least one of their signals by name, as its readers' own pins say.
    static let referenceRaises: [(source: String, reference: String)] = [
        ("Tests/FormatoEMDTests/Fixtures/velox-tiny.emd",
         "RosettaSciIO 0.14.0 emd.file_reader raises KeyError 'Displays' (no Displays/ImageDisplay) for every select_type"),
    ]

    /// The public DM and Velox files dm-velox-pins.json pins, where they are on disk (References/ and tools/test.sh's unzip).
    static func publicFiles() -> [String] {
        let pins = root.appendingPathComponent("Tests/FormatoCoreTests/Fixtures/dm-velox-pins.json")
        guard let data = try? Data(contentsOf: pins),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else { return [] }
        return files.compactMap { $0["path"] as? String }.compactMap { pinPath -> String? in
            let parts = pinPath.split(separator: "/")
            let relative = parts.count == 3 && parts[0] == "emd" && parts[1].hasSuffix(".zip")
                ? ".build/rsciio-unzipped/" + pinPath
                : "References/rosettasciio-049e7d70/rsciio/tests/data/" + pinPath
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) ? relative : nil
        }
    }

    struct Written: Codable {
        /// The .hspy file, relative to `<out>/h3`.
        let file: String
        /// The fixture, repository-relative.
        let source: String
        /// The signal's place in `FormatoLoader.load`'s list for the fixture.
        let index: Int
        let title: String
        let shape: [Int]
        /// The kind it was written as (`HSPYSignalKind.rawValue`).
        let kind: String
    }

    struct Refused: Codable {
        let source: String
        let index: Int
        let reason: String
    }

    struct Manifest: Codable {
        let written: [Written]
        let refused: [Refused]
    }

    struct Outcome {
        var written: [Written] = []
        /// Every refused write (also the typed one that was then written as generic).
        var refused: [Refused] = []
        /// The typed writes refused, with the writer's error.
        var typedRefusals: [(index: Int, error: HSPYError)] = []
        /// The signals the kit refuses to read (a failure in the list, or a throw from `load()`): not H3's.
        var unread: [Refused] = []
    }

    /// Writes `signal` as `kind` and reads it back as written; throws the writer's `HSPYError` when it refuses.
    private func writeAndReadBack(_ signal: FormatoSignal, kind: HSPYSignalKind, to url: URL) throws {
        try HSPYWriter.write(signal, kind: kind, to: url, cancelled: { false })
        let name = url.lastPathComponent
        let back = try HSPYReader.readStored(url: url)
        #expect(back.data.dataType == signal.data.dataType && back.data.shape == signal.data.shape, "\(name): type and shape")
        #expect(back.data.bytes == signal.data.bytes, "\(name): data")
        #expect(back.axes.count == signal.axes.count, "\(name): axis count")
        for (k, (a, b)) in zip(back.axes, signal.axes).enumerated() {
            #expect(a.size == b.size && a.navigate == b.navigate && a.units == b.units && a.name == b.name,
                    "\(name) axis \(k): \(a) vs \(b)")
            #expect(a.scale.bitPattern == b.scale.bitPattern && a.offset.bitPattern == b.offset.bitPattern,
                    "\(name) axis \(k): scale \(a.scale) offset \(a.offset) vs \(b.scale) \(b.offset)")
        }
    }

    /// Writes every signal of `relative` and reads it back: what was written, what the writer refused, what the kit did not read.
    /// A typed write the writer refuses is tried again as generic.
    private func roundTrip(_ relative: String, into folder: URL) throws -> Outcome {
        let path = Self.root.appendingPathComponent(relative).path
        var outcome = Outcome()
        let stem = relative.replacingOccurrences(of: "/", with: "__")
        for (index, result) in try FormatoLoader.load(path: path).enumerated() {
            let signal: FormatoSignal
            do {
                signal = try result.get().load()
            } catch {
                outcome.unread.append(Refused(source: relative, index: index, reason: "read: \(error)"))
                continue
            }
            let typed = HSPYSignalKind(signalType: signal.signalType) ?? .generic
            let name = "\(stem)__\(index).hspy"
            let url = folder.appendingPathComponent(name)
            for kind in typed == .generic ? [typed] : [typed, .generic] {
                do {
                    try writeAndReadBack(signal, kind: kind, to: url)
                } catch let error as HSPYError {
                    outcome.refused.append(Refused(source: relative, index: index, reason: "as \(kind.rawValue): \(error)"))
                    if kind != .generic { outcome.typedRefusals.append((index: index, error: error)) }
                    continue
                }
                outcome.written.append(Written(file: name, source: relative, index: index, title: signal.title,
                                               shape: signal.data.shape, kind: kind.rawValue))
                break
            }
        }
        return outcome
    }

    /// Every committed fixture's signals are written and read back as loaded; the public ones join where present. With
    /// FORMATO_HSPY_OUT set, the files and the manifest land in `<out>/h3` for tools/hspy-writer/check_h3.py.
    @Test func everyPinnedFixtureIsWrittenAndReadBackAsLoaded() throws {
        let out = ProcessInfo.processInfo.environment["FORMATO_HSPY_OUT"].map { URL(fileURLWithPath: $0).appendingPathComponent("h3") }
        let folder = out ?? FileManager.default.temporaryDirectory.appendingPathComponent("FormatoH3-\(UUID().uuidString)")
        if let out { try? FileManager.default.removeItem(at: out) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if out == nil { try? FileManager.default.removeItem(at: folder) } }

        var written: [Written] = [], refused: [Refused] = []
        for relative in Self.committed {
            let r = try roundTrip(relative, into: folder)
            #expect(!r.written.isEmpty, "\(relative): no signal written")
            #expect(r.unread.isEmpty, "\(relative): the kit did not read \(r.unread.map(\.reason))")
            let expected = Self.typedRefusals.filter { $0.source == relative }
            #expect(r.typedRefusals.map { $0.index } == expected.map(\.index) && r.typedRefusals.map { $0.error } == expected.map(\.error),
                    "\(relative): the writer refused \(r.refused.map(\.reason))")
            #expect(r.refused.count == r.typedRefusals.count, "\(relative): refused as generic too: \(r.refused.map(\.reason))")
            for e in expected {
                #expect(r.written.contains { $0.index == e.index && $0.kind == HSPYSignalKind.generic.rawValue },
                        "\(relative) [\(e.index)]: written as generic")
            }
            written += r.written; refused += r.refused
        }
        // A committed file RosettaSciIO raises on has no reference reading: the kit refuses it too (by name), and it is recorded.
        for (relative, reference) in Self.referenceRaises {
            var reasons: [Refused] = []
            do {
                for (index, result) in try FormatoLoader.load(path: Self.root.appendingPathComponent(relative).path).enumerated() {
                    do { _ = try result.get().load() } catch {
                        reasons.append(Refused(source: relative, index: index, reason: "read: \(error); \(reference)"))
                    }
                }
            } catch {
                reasons.append(Refused(source: relative, index: -1, reason: "read: \(error); \(reference)"))
            }
            #expect(!reasons.isEmpty, "\(relative): \(reference), but the kit reads every signal of it")
            refused += reasons
        }
        let formats = Set(written.map { URL(fileURLWithPath: $0.source).pathExtension.lowercased() })
        #expect(formats.isSuperset(of: ["msa", "dm4", "emd"]), "\(formats)")
        // A public file the kit or the writer refuses is recorded, not failed: its readers' own pins say what it refuses.
        for relative in Self.publicFiles() {
            do {
                let r = try roundTrip(relative, into: folder)
                written += r.written; refused += r.refused + r.unread
            } catch {
                refused.append(Refused(source: relative, index: -1, reason: String(describing: error)))
            }
        }
        if out != nil {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Manifest(written: written, refused: refused)).write(to: folder.appendingPathComponent("manifest.json"))
        }
    }
}
