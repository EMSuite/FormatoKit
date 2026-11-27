//
//  EDSReaderBundleParityTests.swift
//  The SEM-EDS readers (Bruker `.bcf`/`.spx`, EDAX `.spd`/`.lsd`/`.spc`, JEOL `.pts`/`.eds`/`.img`/`.asw`) against RosettaSciIO
//  0.15.0: every m7/read-* bundle (the app's tools/parity/sem emit.py, `_eds_bundle`) holds what rsciio returns for one of its own
//  test files, signal by signal: kind, shape, dtype, axes, the mapped metadata, and the data exact (a spectrum's counts; a
//  spectrum image's nonzero flat indices and counts by sha256, its summed spectrum, its per-pixel totals; an image's pixels by
//  sha256). A file rsciio refuses is refused here. Then what the files hold as the consumer opens them: a .bcf map with its
//  scan image, an EDAX map whose .ipr or .csv cannot be read, a JEOL map held sparse, single spectra, the mode; the sparse
//  store's sums and its dense slabs.
//  Moved from Electron Microscopy Studio's EMStudioTests/SEMEDSMapReaderTests.swift (at f1eaafc) by FormatoKit#148: the bundle
//  comparison unchanged, read through FormatoCore's signals (an absent unit is "" there, rsciio's None); the app's doors
//  (`EDXOpening`, `FileRouting`, `ImageOpening`) stay in the app, their reader facts are checked here on the readers.
//  Mutations each test must go red under: a channel or pixel off by one in any unpacker; the 12-bit nibble order swapped; a gain
//  dropped from a packed run; the incomplete JEOL frame kept; a float32 header value rounded; the x axis of a .bcf map given DX.
//

import CryptoKit
import Foundation
import FormatoCore
import FormatoEDS
import XCTest

nonisolated final class EDSReaderBundleParityTests: XCTestCase {

    static func cases() throws -> [String] {
        try SEMParityReference.allCases().filter { $0.hasPrefix("m7/read-") }
    }

    static func sha256(int64 values: some Sequence<Int64>) -> String {
        var h = SHA256()
        var buffer: [UInt8] = []
        buffer.reserveCapacity(1 << 16)
        for v in values {
            let le = UInt64(bitPattern: v).littleEndian
            withUnsafeBytes(of: le) { buffer.append(contentsOf: $0) }
            if buffer.count >= 1 << 16 { h.update(data: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        h.update(data: buffer)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The reference axes decoded by `JSONDecoder`, which parses each float to the nearest Double; `JSONSerialization` rounds some
    /// 17-digit floats (0.014235896058380604, a float32 pixel size widened) one unit in the last place off.
    nonisolated struct Axis: Decodable, Equatable { let name: String; let size: Int; let scale: Double; let offset: Double; let units: String? }
    nonisolated struct AxesManifest: Decodable {
        nonisolated struct Values: Decodable { nonisolated struct Signal: Decodable { let axes: [Axis] }; let signals: [Signal]? }
        let values: Values
    }

    static func referenceAxes(_ name: String) throws -> [[Axis]] {
        let url = SEMParityReference.referencesRoot.appendingPathComponent(name).appendingPathComponent("manifest.json")
        return try JSONDecoder().decode(AxesManifest.self, from: Data(contentsOf: url)).values.signals?.map(\.axes) ?? []
    }

    /// Every committed m7 reader bundle, read by the Swift port and compared field by field.
    func testEveryReaderBundleReadsAsRosettaSciIOReadsIt() throws {
        let names = try Self.cases()
        XCTAssertGreaterThanOrEqual(names.count, 25, "the m7 reader bundles are committed")
        var compared = 0
        for name in names {
            let ref = try SEMParityReference.load(name)
            // A sem-data input is a downloaded dataset, not committed: that bundle is compared where the consumer has the data.
            guard let url = ref.inputURL(), FileManager.default.fileExists(atPath: url.path) else { continue }
            compared += 1
            let signals = ref.values["signals"] as? [[String: Any]] ?? []
            if let refusal = ref.values["refusal"] as? String {
                XCTAssertThrowsError(try EDSReader.read(url: url), "\(name): rsciio refuses it (\(refusal))") { error in
                    XCTAssertFalse((error as? EDSReadError)?.text.isEmpty ?? true, "\(name): a sentence")
                }
                continue
            }
            let file: EDSFile
            do { file = try EDSReader.read(url: url) } catch {
                XCTFail("\(name): \(error.localizedDescription)"); continue
            }
            XCTAssertEqual(file.signals.count, signals.count, "\(name): signal count")
            for (i, (signal, expected)) in zip(file.signals, signals).enumerated() {
                try check(signal, expected, index: i, ref: ref, name: name)
            }
        }
        XCTAssertGreaterThanOrEqual(compared, 23, "the committed fixtures cover every reader")
    }

    func check(_ signal: FormatoLazySignal, _ e: [String: Any], index i: Int, ref: SEMParityReference, name: String) throws {
        let label = "\(name) signal \(i)"
        let kind: String
        switch EDSFile.kind(of: signal) {
        case .spectrumImage: kind = "spectrum_image"
        case .spectrum: kind = "spectrum"
        case .image: kind = "image"
        }
        XCTAssertEqual(kind, e["kind"] as? String, "\(label): kind")
        XCTAssertEqual(signal.array.shape, e["shape"] as? [Int], "\(label): shape")
        XCTAssertEqual(signal.array.dataType.rawValue, e["dtype"] as? String, "\(label): dtype")
        let expectedAxes = try Self.referenceAxes(name)
        // rsciio's None unit is FormatoCore's "".
        XCTAssertEqual(signal.axes.map { Axis(name: $0.name ?? "", size: $0.size, scale: $0.scale, offset: $0.offset, units: $0.units.isEmpty ? nil : $0.units) },
                       expectedAxes.indices.contains(i) ? expectedAxes[i] : [], "\(label): axes")
        XCTAssertEqual(signal.axes.map(\.navigate), signal.axes.indices.map { kind == "spectrum_image" && $0 < signal.axes.count - 1 },
                       "\(label): navigate")
        XCTAssertEqual(NSDictionary(dictionary: signal.eds.flattened), NSDictionary(dictionary: e["metadata"] as? [String: Any] ?? [:]),
                       "\(label): metadata")
        XCTAssertEqual(signal.title, signal.eds.title ?? "", "\(label): title")
        XCTAssertEqual(signal.signalType, signal.eds.signalType ?? "", "\(label): signal type")
        switch EDSFile.kind(of: signal) {
        case .spectrum:
            SEMAssertParity(try signal.array.readAll().doubles(), try ref.array("signal\(i)_counts"))
        case .spectrumImage:
            let cube = try signal.cube()
            let nz = try XCTUnwrap(ref.values["signal\(i)_nonzero"] as? [String: Any], label)
            XCTAssertEqual(cube.counts.count, nz["count"] as? Int, "\(label): nonzero count")
            var flat: [Int64] = []
            flat.reserveCapacity(cube.counts.count)
            for p in 0..<(cube.ny * cube.nx) {
                for k in cube.rowOffsets[p]..<cube.rowOffsets[p + 1] { flat.append(Int64(p * cube.channels + Int(cube.channelIndex[k]))) }
            }
            XCTAssertEqual(Self.sha256(int64: flat), nz["index_sha256"] as? String, "\(label): where the counts are")
            XCTAssertEqual(Self.sha256(int64: cube.counts.map { Int64($0) }), nz["value_sha256"] as? String, "\(label): the counts")
            SEMAssertParity(cube.sum(mask: nil).map { Double($0) }, try ref.array("signal\(i)_sum_spectrum"))
            let totals = try XCTUnwrap(ref.values["signal\(i)_pixel_totals"] as? [String: Any], label)
            XCTAssertEqual(Self.sha256(int64: cube.pixelTotals()), totals["sha256"] as? String, "\(label): per-pixel totals")
        case .image:
            let fp = try XCTUnwrap(ref.values["signal\(i)_pixels"] as? [String: Any], label)
            let pixels = try signal.array.readAll()
            XCTAssertEqual(EDSFixtures.sha256(pixels.bytes), fp["sha256"] as? String, "\(label): pixels")
            SEMAssertParity(pixels.doubles().reduce(0.0, +), ref, scalar: "signal\(i)_pixel_sum")
        }
    }

    // MARK: - What the files hold as the consumer opens them

    /// A .bcf is its 2048-channel map with the BSE image recorded on its grid: the energy axis in keV, the pixel size in µm, the
    /// beam energy and the detector, every count of rsciio's map. Mutation: the scan image left out; the energy offset moved.
    func testABrukerMapHoldsItsScanImage() throws {
        let file = try EDSReader.read(url: EDSFixtures.rsciio("bruker/P45_the_default_job.bcf"))
        let map = try XCTUnwrap(file.spectrumImages.first)
        let cube = try map.cube()
        XCTAssertEqual([cube.nx, cube.ny, cube.channels], [100, 75, 2048])
        let energy = try XCTUnwrap(map.axes.last)
        XCTAssertEqual(energy.offset, -0.472397235, accuracy: 1e-12)
        XCTAssertEqual(energy.scale, 0.010001, accuracy: 1e-15)
        XCTAssertEqual(energy.units, "keV")
        XCTAssertEqual(map.axes[1].units, "µm")
        XCTAssertEqual(map.eds.beamEnergy, 20)
        XCTAssertEqual(map.eds.detectorType, "XFlash 6|10")
        XCTAssertTrue(file.images.contains { $0.array.shape == [cube.ny, cube.nx] }, "the BSE image on the scan grid")
        XCTAssertEqual(cube.sum(mask: nil).reduce(0, +), 165_941, "every count of rsciio's map")
    }

    /// An EDAX map reads its energy axis from the .spc beside it; without the .spc it has none (scale 1, offset 1, no unit), as
    /// rsciio's fallback, which the consumer refuses in its own words.
    func testAnEDAXMapTakesItsEnergyAxisFromItsSPC() throws {
        let folder = try copyEDAX(["spd_map_crop8.spd", "spd_map_crop8.spc", "Live Map 2_Img.ipr"])
        let map = try XCTUnwrap(try EDAXEDSReader.read(url: folder.appendingPathComponent("spd_map_crop8.spd")).spectrumImages.first)
        XCTAssertEqual(try map.cube().channels, 2500)
        XCTAssertEqual(map.axes.last?.scale ?? 0, 0.005, accuracy: 1e-15)
        XCTAssertEqual(map.axes.last?.units, "keV")
        XCTAssertEqual(map.eds.beamEnergy, 22)
        let alone = try scratchFolder("edax-alone").appendingPathComponent("alone.spd")
        try FileManager.default.copyItem(at: folder.appendingPathComponent("spd_map_crop8.spd"), to: alone)
        let bare = try XCTUnwrap(try EDAXEDSReader.read(url: alone).spectrumImages.first)
        XCTAssertEqual(bare.axes.last.map { [$0.scale, $0.offset] }, [1, 1])
        XCTAssertEqual(bare.axes.last?.units, "")
        XCTAssertNil(bare.eds.beamEnergy)
    }

    /// `names` from the committed EDAX fixtures, copied into a fresh temporary folder that is removed after the test.
    private func copyEDAX(_ names: [String]) throws -> URL {
        let folder = try scratchFolder("edax")
        for name in names { try FileManager.default.copyItem(at: EDSFixtures.rsciio("edax/" + name), to: folder.appendingPathComponent(name)) }
        return folder
    }

    /// `url` made mode 000 until the test ends: this process may not read it, as a sandboxed consumer may not read a companion it
    /// was not given.
    private func makeUnreadable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: url.path), "root reads a mode-000 file; run this as a user")
    }

    /// An .ipr beside an EDAX map that is there but cannot be read is left out as a missing one is, with a note: the map reads
    /// with the same counts and the .spc's energy axis, its pixels not calibrated. Red before (in the app): the .ipr's read failure
    /// failed the whole open.
    func testAnEDAXMapWhoseIPRCannotBeReadOpensWithoutItsPixelSize() throws {
        let folder = try copyEDAX(["spd_map_crop8.spd", "spd_map_crop8.spc", "Live Map 2_Img.ipr"])
        let map = folder.appendingPathComponent("spd_map_crop8.spd")
        let whole = try EDAXEDSReader.read(url: map)
        XCTAssertEqual(whole.notes, [])
        let calibrated = try XCTUnwrap(whole.spectrumImages.first)
        XCTAssertEqual(calibrated.axes.map(\.units), ["\u{B5}m", "\u{B5}m", "keV"])
        try makeUnreadable(folder.appendingPathComponent("Live Map 2_Img.ipr"))
        let file = try EDAXEDSReader.read(url: map)
        XCTAssertEqual(file.notes, ["Live Map 2_Img.ipr beside spd_map_crop8.spd could not be read: the map has no pixel size."])
        let uncalibrated = try XCTUnwrap(file.spectrumImages.first)
        XCTAssertEqual(uncalibrated.axes.map(\.units), ["", "", "keV"])
        XCTAssertEqual([uncalibrated.axes[0].scale, uncalibrated.axes[1].scale], [1, 1])
        XCTAssertEqual(uncalibrated.axes.last, calibrated.axes.last, "the .spc's energy axis")
        XCTAssertEqual(try uncalibrated.cube(), try calibrated.cube(), "the same counts")
    }

    /// The same for a line scan's .csv: it reads with the same counts and energy axis, its x axis in steps of one instead of
    /// the distances. Red before (in the app): the .csv's read failure failed the whole open.
    func testAnEDAXLineScanWhoseCSVCannotBeReadOpensWithoutItsDistances() throws {
        let folder = try copyEDAX(["line_scan_crop.lsd", "line_scan_crop.spc", "line_scan_crop.csv"])
        let line = folder.appendingPathComponent("line_scan_crop.lsd")
        let whole = try EDAXEDSReader.read(url: line)
        XCTAssertEqual(whole.notes, [])
        let measured = try XCTUnwrap(whole.spectrumImages.first)
        XCTAssertEqual(measured.axes[0].units, "nm")
        XCTAssertEqual(measured.axes[0].scale, 212)
        try makeUnreadable(folder.appendingPathComponent("line_scan_crop.csv"))
        let file = try EDAXEDSReader.read(url: line)
        XCTAssertEqual(file.notes, ["line_scan_crop.csv beside line_scan_crop.lsd could not be read: the line scan has no distances."])
        let unmeasured = try XCTUnwrap(file.spectrumImages.first)
        XCTAssertEqual(unmeasured.axes[0], FormatoAxis(name: "x", size: measured.axes[0].size, scale: 1, offset: 0, units: "", navigate: true))
        XCTAssertEqual(unmeasured.axes.last, measured.axes.last)
        XCTAssertEqual(try unmeasured.cube(), try measured.cube(), "the same counts")
    }

    /// A JEOL .pts is its 512 x 512 x 4096 map, held sparse; the S(T)EM image of a stream that has one is on the scan grid.
    func testAJEOLMapIsHeldSparseWithItsSTEMImage() throws {
        let file = try JEOLEDSReader.read(url: EDSFixtures.rsciio("jeol/View000_0000006_4frames.pts"))
        let cube = try XCTUnwrap(file.spectrumImages.first).cube()
        XCTAssertEqual([cube.nx, cube.channels], [512, 4096])
        XCTAssertTrue(file.images.isEmpty, "this stream holds no image")
        XCTAssertLessThan(cube.counts.count, 100_000, "only the recorded X-rays are held")
        let withImage = try JEOLEDSReader.read(url: EDSFixtures.rsciio("jeol/InvalidFrame/Dummy-Data_0000015.pts"))
        XCTAssertEqual(withImage.images.first?.array.shape, [64, 64])
    }

    /// Single spectra read as one spectrum: a Bruker .spx, an EDAX .spc, a JEOL .eds.
    func testSingleSpectraReadAsOneSpectrum() throws {
        for (path, channels) in [("bruker/bruker_nano.spx", 4096), ("edax/single_spect.spc", 4096), ("jeol/met03.EDS", 2048)] {
            let file = try EDSReader.read(url: EDSFixtures.rsciio(path))
            XCTAssertEqual(file.signals.map { EDSFile.kind(of: $0) }, [.spectrum], path)
            XCTAssertEqual(file.spectra.first?.array.shape, [channels], path)
            XCTAssertEqual(file.spectra.first?.axes.first?.units, "keV", path)
        }
    }

    /// The mode rsciio reads: an SEM map or spectrum from every vendor is SEM; Bruker's TEM file, its M6 Jetstream spectrum and
    /// the JEOL fixtures (200 kV) are TEM.
    func testTheFilesModeIsRsciios() throws {
        for path in ["bruker/P45_the_default_job.bcf", "bruker/bruker_nano.spx", "edax/spd_map_crop8.spd", "edax/single_spect.spc"] {
            let file = try EDSReader.read(url: EDSFixtures.rsciio(path))
            XCTAssertEqual((file.spectrumImages.first ?? file.spectra.first)?.eds.mode, "SEM", path)
        }
        for path in ["bruker/test_TEM.bcf", "bruker/bruker_m6_jetstream_file_example.spx", "jeol/View000_0000006_4frames.pts",
                     "jeol/met03.EDS"] {
            let file = try EDSReader.read(url: EDSFixtures.rsciio(path))
            XCTAssertEqual((file.spectrumImages.first ?? file.spectra.first)?.eds.mode, "TEM", path)
        }
    }

    /// A JEOL image is [height, width] with its µm per pixel.
    func testAJEOLImageHoldsItsPixelSize() throws {
        let file = try EDSReader.read(url: EDSFixtures.rsciio("jeol/InvalidFrame/Dummy-Data_0000000.img"))
        let image = try XCTUnwrap(file.images.first)
        XCTAssertEqual(image.array.shape.last, 256)
        XCTAssertEqual(image.axes.map(\.units), ["µm", "µm"])
    }

    /// The sparse store sums as a dense cube does: a mask, windows. Mutation: a window's upper bound made inclusive.
    func testTheSparseStoreSumsExactly() throws {
        let cube = try EDSSparseSpectrumImage(ny: 1, nx: 3, channels: 4, rowOffsets: [0, 2, 2, 4], channelIndex: [0, 3, 1, 2], counts: [5, 7, 1, 2])
        XCTAssertEqual(cube.sum(mask: nil), [5, 1, 2, 7])
        XCTAssertEqual(cube.sum(mask: [false, true, true]), [0, 1, 2, 0])
        XCTAssertEqual(cube.windowSums([0..<2, 2..<4]), [[5, 0, 1], [7, 0, 2]])
        XCTAssertEqual(cube.spectrum(pixel: 2), [0, 1, 2, 0])
    }

    /// The lazy array of a spectrum image is its dense cube in rsciio's type and shape: a slab cut from the whole equals the slab
    /// read, the absent channels are 0, and every map of the committed files that fits in memory sums to its sparse sums. A count
    /// past the data type is refused, never wrapped. Mutation: a channel offset dropped from the slab; a pixel skipped.
    func testTheDenseSlabsAreTheSparseCounts() throws {
        let cube = try EDSSparseSpectrumImage(ny: 2, nx: 3, channels: 4, rowOffsets: [0, 2, 2, 4, 5, 5, 6], channelIndex: [0, 3, 1, 2, 3, 0],
                                              counts: [5, 7, 1, 2, 9, 4], dataType: .uint16)
        let whole = try cube.readAll()
        XCTAssertEqual(whole.dataType, .uint16)
        XCTAssertEqual(whole.shape, [2, 3, 4])
        XCTAssertEqual(whole.doubles(), [5, 0, 0, 7, 0, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 9, 0, 0, 0, 0, 4, 0, 0, 0])
        XCTAssertEqual(try cube.read(start: [0, 1, 1], count: [2, 2, 2]), try whole.slab(start: [0, 1, 1], count: [2, 2, 2]))
        let line = try EDSSparseSpectrumImage(ny: 1, nx: 3, channels: 4, rowOffsets: [0, 2, 2, 4], channelIndex: [0, 3, 1, 2],
                                              counts: [5, 7, 1, 2], dataType: .uint8, shape: [3, 4])
        XCTAssertEqual(try line.read(start: [1, 1], count: [2, 3]).doubles(), [0, 0, 0, 1, 2, 0])
        let wide = try EDSSparseSpectrumImage(ny: 1, nx: 1, channels: 2, rowOffsets: [0, 1], channelIndex: [1], counts: [256], dataType: .uint8)
        XCTAssertThrowsError(try wide.readAll()) { XCTAssertEqual(($0 as? EDSReadError)?.reason, .countAboveType, "\($0)") }
        XCTAssertThrowsError(try EDSSparseSpectrumImage(ny: 1, nx: 2, channels: 4, rowOffsets: [0, 0, 0], channelIndex: [], counts: [],
                                                         shape: [3, 4])) { XCTAssertEqual(($0 as? EDSReadError)?.reason, .damaged) }

        for path in ["bruker/30x30_instructively_packed_16bit_compressed.bcf", "bruker/16x16_12bit_packed_8bit.bcf", "edax/spd_map_crop8.spd",
                     "edax/line_scan_crop.lsd"] {
            let map = try XCTUnwrap(try EDSReader.read(url: EDSFixtures.rsciio(path)).spectrumImages.first, path)
            let sparse = try map.cube()
            let dense = try map.array.readAll()
            XCTAssertEqual(dense.shape, map.array.shape, path)
            var sums = [Double](repeating: 0, count: sparse.channels)
            for (k, v) in dense.doubles().enumerated() { sums[k % sparse.channels] += v }
            XCTAssertEqual(sums, sparse.sum(mask: nil).map(Double.init), path)
        }
    }
}
