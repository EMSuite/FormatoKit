import Testing
import Foundation
import FormatoCore
import FormatoHSPY
import FormatoTIA
import Formato

private let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private func path(_ relative: String) -> String { tests.appendingPathComponent(relative).path }

@Test func sniffsEachFormatByExtensionAndBytes() {
    #expect(FormatoLoader.sniff(path: path("FormatoDMTests/Fixtures/eels-planted.dm4")) == .digitalMicrograph)
    #expect(FormatoLoader.sniff(path: path("FormatoTIFFTests/Fixtures/planted/fei-helios.tif")) == .tiff)
    #expect(FormatoLoader.sniff(path: path("FormatoEMDTests/Fixtures/velox-titles-v6-image.emd")) == .veloxEMD)
    #expect(FormatoLoader.sniff(path: path("FormatoEMDTests/Fixtures/spectra/sp-single.emd")) == .veloxEMD)
    #expect(FormatoLoader.sniff(path: path("FormatoMSATests/Fixtures/public/example1.msa")) == .msa)
    // The extension of one format on the bytes of another is unknown; a missing file is unknown.
    #expect(FormatoLoader.sniff(path: path("FormatoMSATests/Fixtures/public/example1.msa").replacingOccurrences(of: ".msa", with: ".dm4")) == .unknown)
    #expect(FormatoLoader.sniff(path: path("FormatoDMTests/Fixtures/eels-planted.truth.json")) == .unknown)
}

@Test func loadsSignalsAndNamesTheOthers() throws {
    // A DM file: every object, the refused ones as errors.
    let dm = try FormatoLoader.load(path: path("FormatoDMTests/Fixtures/eels-planted.dm4"))
    #expect(dm.count == 21)
    // A Velox file with single spectra: spectra first, then images, then spectrum images (RosettaSciIO's order).
    let spectra = try FormatoLoader.load(path: path("FormatoEMDTests/Fixtures/spectra/sp-stream.emd"))
    let titles = try spectra.map { try $0.get().title }
    #expect(titles.first == "SuperXG11" && spectra.count >= 1)
    let one = try FormatoLoader.load(path: path("FormatoEMDTests/Fixtures/spectra/sp-single.emd"))
    #expect(try one.count == 1 && one[0].get().signalType == "EDS_TEM" && one[0].get().array.shape == [12])
    // MSA arrives as an in-memory lazy signal.
    let msa = try FormatoLoader.load(path: path("FormatoMSATests/Fixtures/public/example1.msa"))
    #expect(try msa.count == 1 && msa[0].get().load().data.dataType == .float64)
    // 4D formats are named, not loaded; an unknown file is refused by name.
    #expect(throws: FormatoLoadError.self) { _ = try FormatoLoader.load(path: path("FormatoDMTests/Fixtures/eels-planted.truth.json")) }
}

@Test func loadsATifffileWrittenFileWithItsShapedDescription() throws {
    // `tifffile.imwrite(array)` with default metadata: sniffed as TIFF and loaded through the shaped series rule.
    let stack = try FormatoLoader.load(path: path("FormatoTIFFTests/Fixtures/shaped/stack_f4.tif"))
    #expect(stack.count == 1)
    let signal = try stack[0].get().load()
    #expect(signal.data.dataType == .float32 && signal.data.shape == [5, 7, 9])
    let two = try FormatoLoader.load(path: path("FormatoTIFFTests/Fixtures/shaped/series_two.tif"))
    #expect(try two.map { try $0.get().array.shape } == [[2, 7, 9], [7, 9]])
}

@Test func sniffsAndLoadsHyperSpyFiles() throws {
    let folder = "FormatoHSPYTests/Fixtures/reader/"
    #expect(FormatoLoader.sniff(path: path(folder + "image-u8.hspy")) == .hyperSpy)
    #expect(FormatoLoader.sniff(path: path(folder + "EDS_SEM_TM002.hspy")) == .hyperSpy)
    // HDF5's signature under .hspy is HyperSpy's kind; the reader then refuses a file that is not HyperSpy's.
    #expect(FormatoLoader.sniff(path: path(folder + "refused-not-hyperspy.hspy")) == .hyperSpy)
    // The .hspy extension on other bytes is unknown.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let text = dir.appendingPathComponent("text.hspy")
    try Data("not an HDF5 file".utf8).write(to: text)
    #expect(FormatoLoader.sniff(path: text.path) == .unknown)
    // RosettaSciIO's hspy plugin also takes .hdf5, older HyperSpy's default: HyperSpy's root names it; other HDF5 stays .hdf5.
    let old = dir.appendingPathComponent("old.hdf5"), plain = dir.appendingPathComponent("plain.h5")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: path(folder + "image-u8.hspy")), to: old)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: path(folder + "refused-not-hyperspy.hspy")), to: plain)
    #expect(FormatoLoader.sniff(path: old.path) == .hyperSpy)
    #expect(FormatoLoader.sniff(path: plain.path) == .hdf5)
    // One signal per experiment, in the file's order; a refused experiment is its failure.
    let types = try FormatoLoader.load(path: path(folder + "more-types.hspy"))
    #expect(try types.map { try $0.get().array.dataType } == [.int64, .int8, .uint64])
    let image = try FormatoLoader.load(path: path(folder + "image-u8.hspy"))
    #expect(try image.count == 1 && image[0].get().title == "Image µm" && image[0].get().load().data.shape == [5, 6])
    let refused = try FormatoLoader.load(path: path(folder + "refusals.hspy"))
    #expect(refused.count == 5 && refused.allSatisfy { (try? $0.get()) == nil })
    #expect(throws: HSPYError.notHyperSpyFile("refused-not-hyperspy.hspy")) {
        _ = try FormatoLoader.load(path: path(folder + "refused-not-hyperspy.hspy"))
    }
}

@Test func sniffsAndLoadsTIAFiles() throws {
    let folder = "FormatoTIATests/Fixtures/public/old/"
    #expect(FormatoLoader.sniff(path: path(folder + "64x64_diffraction_acquire_1.ser")) == .tia)
    #expect(FormatoLoader.sniff(path: path(folder + "64x64_diffraction_acquire.emi")) == .tia)
    // A .ser is its series header's "II" and 0x0197; other bytes under .ser are unknown.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loader-tia-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fake = dir.appendingPathComponent("fake_1.ser")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: path("FormatoMSATests/Fixtures/public/example1.msa")), to: fake)
    #expect(FormatoLoader.sniff(path: fake.path) == .unknown)
    // A .ser loads as RosettaSciIO reads it alone (metres); its .emi loads every series beside it with the .emi's units.
    let ser = try FormatoLoader.load(path: path(folder + "64x64_diffraction_acquire_1.ser"))
    #expect(try ser.count == 1 && ser[0].get().axes.map(\.units) == ["nm", "nm"])
    let emi = try FormatoLoader.load(path: path(folder + "64x64_diffraction_acquire.emi"))
    #expect(try emi.count == 1 && emi[0].get().axes.map(\.units) == ["1 / nm", "1 / nm"])
    let two = try FormatoLoader.load(path: path(folder + "16x16_STEM_BF_DF_acquire.emi"))
    let direct = try TIAReader.readEMI(url: URL(fileURLWithPath: path(folder + "16x16_STEM_BF_DF_acquire.emi")))
    #expect(try two.map { try $0.get().array.shape } == direct.map(\.array.shape))
    #expect(two.count == 2)
}
