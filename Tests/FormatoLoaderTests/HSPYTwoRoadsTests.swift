//
//  HSPYTwoRoadsTests.swift
//  Pin H3 (FormatoKit#151; docs/design/files-exports.md in the suite): the same content by two roads. RosettaSciIO 0.14.0 reading
//  a Velox EMD, DM3, DM4 or MSA fixture must equal RosettaSciIO reading the .hspy the kit writes from that fixture: the data
//  `array_equal`, every axis's name, units, size and navigate equal and its scale and offset to the bit (the tolerance the
//  formats' own pins use: dm-velox-pins and msa-pins compare axes bit for bit).
//
//  Here, on every run: each signal `FormatoLoader.load` gives for the fixture is written by `HSPYWriter.write` (the kind from its
//  signal type, generic otherwise) and read back by `HSPYReader.readStored`: data type, shape and bytes, and every axis field, equal
//  what was loaded, and no committed fixture's signal is refused by the writer. The reference's side is the Mac and nightly step:
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
    /// the planted DM4 EDX spectrum image, and the planted Velox files (an image file and a spectrum image).
    static let committed: [String] = [
        "Tests/FormatoMSATests/Fixtures/public/example1.msa",
        "Tests/FormatoMSATests/Fixtures/public/example2.msa",
        "Tests/FormatoMSATests/Fixtures/public/ISO_22029_2022_compliance.msa",
        "Tests/FormatoMSATests/Fixtures/public/ISO_22029_2022_compliance_XY_NCOLUMNS2.msa",
        "Tests/FormatoDMTests/Fixtures/rsciio-EELS_SI.dm4",
        "Tests/FormatoDMTests/Fixtures/demo-edx-tiny.dm4",
        "Tests/FormatoEMDTests/Fixtures/velox-tiny.emd",
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

    /// Writes every signal of `relative` and reads it back; returns what was written and what the writer refused.
    private func roundTrip(_ relative: String, into folder: URL) throws -> (written: [Written], refused: [Refused]) {
        let path = Self.root.appendingPathComponent(relative).path
        var written: [Written] = [], refused: [Refused] = []
        let stem = relative.replacingOccurrences(of: "/", with: "__")
        for (index, result) in try FormatoLoader.load(path: path).enumerated() {
            guard case .success(let lazy) = result else { continue }   // a signal the kit refuses to read is not H3's
            let signal = try lazy.load()
            let kind = HSPYSignalKind(signalType: signal.signalType) ?? .generic
            let name = "\(stem)__\(index).hspy"
            let url = folder.appendingPathComponent(name)
            do {
                try HSPYWriter.write(signal, kind: kind, to: url, cancelled: { false })
            } catch let error as HSPYError {
                refused.append(Refused(source: relative, index: index, reason: String(describing: error)))
                continue
            }
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
            written.append(Written(file: name, source: relative, index: index, title: signal.title, shape: signal.data.shape))
        }
        return (written, refused)
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
            #expect(r.refused.isEmpty, "\(relative): the writer refused \(r.refused.map(\.reason))")
            written += r.written; refused += r.refused
        }
        let formats = Set(written.map { URL(fileURLWithPath: $0.source).pathExtension.lowercased() })
        #expect(formats.isSuperset(of: ["msa", "dm4", "emd"]), "\(formats)")
        // A public file the kit or the writer refuses is recorded, not failed: its readers' own pins say what it refuses.
        for relative in Self.publicFiles() {
            do {
                let r = try roundTrip(relative, into: folder)
                written += r.written; refused += r.refused
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
