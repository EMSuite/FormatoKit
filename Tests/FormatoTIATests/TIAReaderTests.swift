//
//  TIAReaderTests.swift
//  FormatoTIA against RosettaSciIO 049e7d70's `ser_reader` on its public .ser test files (pin T1, tools/tia/pins.py): dtype,
//  shape, the values' sha256, every axis bit for bit, for `only_valid_data` true and false; the header facts; slabs equal to
//  the whole read; and what is refused by name (not a .ser, no valid element, a truncated element, complex values).
//

import CryptoKit
import Foundation
import Testing
import FormatoCore
import FormatoTIA

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

private struct Pins: @unchecked Sendable {  // immutable after load
    let files: [String: [String: Any]]
}

private let pins: Pins = {
    let url = fixtures.appendingPathComponent("tia-pins.json")
    let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    return Pins(files: json["files"] as! [String: [String: Any]])
}()

private func bits(_ hex: String) -> UInt64 {
    var value: UInt64 = 0
    let bytes = stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }
    for (i, b) in bytes.enumerated() { value |= UInt64(b) << (8 * UInt64(i)) }
    return value
}

private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func url(_ key: String) -> URL { fixtures.appendingPathComponent("public").appendingPathComponent(key) }

private let keys: [String] = pins.files.keys.sorted()

@Suite("TIA .ser against RosettaSciIO")
struct TIAReaderTests {
    @Test func everyPublicFileIsPinned() {
        #expect(keys.count == 28)
    }

    @Test(arguments: keys, [true, false])
    func readEqualsRosettaSciIO(key: String, onlyValid: Bool) throws {
        let entry = pins.files[key]!
        #expect(sha256(try Data(contentsOf: url(key))) == entry["sha256"] as! String, "\(key): the fixture is the public file")
        let want = entry[onlyValid ? "valid_only" : "all"] as! [String: Any]
        if want["error"] != nil {
            #expect(throws: (any Error).self, "\(key)") { _ = try TIAReader.read(url: url(key), onlyValidData: onlyValid) }
            return
        }
        let signal = try TIAReader.read(url: url(key), onlyValidData: onlyValid)
        #expect(signal.array.dataType.rawValue == want["dtype"] as! String, "\(key) dtype")
        #expect(signal.array.shape == want["shape"] as! [Int], "\(key) shape")
        let data = try signal.array.readAll()
        #expect(sha256(data.bytes) == want["sha256"] as! String, "\(key) values")
        let axes = want["axes"] as! [[String: Any]]
        #expect(signal.axes.count == axes.count, "\(key) axis count")
        for (got, a) in zip(signal.axes, axes) {
            #expect(got.name == a["name"] as? String, "\(key) name")
            #expect(got.size == a["size"] as! Int, "\(key) size")
            #expect(got.units == a["units"] as! String, "\(key) units")
            #expect(got.navigate == a["navigate"] as! Bool, "\(key) navigate")
            #expect(got.scale.bitPattern == bits(a["scale"] as! String), "\(key) scale \(got.scale)")
            #expect(got.offset.bitPattern == bits(a["offset"] as! String), "\(key) offset \(got.offset)")
        }
        #expect(signal.metadata["General.original_filename"]?.value.text == want["original_filename"] as? String)
    }

    @Test(arguments: keys)
    func headerEqualsRosettaSciIO(key: String) throws {
        let want = pins.files[key]!["header"] as! [String: Any]
        let h = try TIAReader.header(url: url(key))
        #expect(h.seriesVersion == want["series_version"] as! Int)
        #expect(h.dataTypeID == want["data_type_id"] as! Int)
        #expect(h.tagTypeID == want["tag_type_id"] as! Int)
        #expect(h.totalElements == want["total"] as! Int)
        #expect(h.validElements == want["valid"] as! Int)
        #expect(h.offsetArrayOffset == want["offset_array_offset"] as! Int)
        let dims = want["dimensions"] as! [[String: Any]]
        #expect(h.dimensions.count == dims.count)
        for (got, d) in zip(h.dimensions, dims) {
            #expect(got.size == d["size"] as! Int)
            #expect(got.calibrationOffset.bitPattern == bits(d["offset"] as! String))
            #expect(got.calibrationDelta.bitPattern == bits(d["delta"] as! String))
            #expect(got.calibrationElement == d["element"] as! Int)
            #expect(got.description == d["description"] as! String)
            #expect(got.units == d["units"] as! String)
        }
    }

    /// A slab is the same cut of the whole read: across elements, across the image flip, into the fill of a stopped series.
    @Test(arguments: ["new/16x16-diffraction_imagel_5x5x256x256_EDS_2.ser", "old/64x64x5_TEM_preview_1.ser",
                      "old/16x16-spectrum_image-5x5x1024_1.ser", "old/03_Scanning Preview_1.ser"])
    func slabsEqualTheWholeRead(key: String) throws {
        for onlyValid in [true, false] {
            let array = try TIAReader.read(url: url(key), onlyValidData: onlyValid).array
            let whole = try array.readAll()
            let shape = array.shape
            let start = shape.map { $0 / 3 }
            let count = zip(shape, start).map { max(1, ($0 - $1) / 2) }
            #expect(try array.read(start: start, count: count) == whole.slab(start: start, count: count), "\(key) \(onlyValid)")
            let last = shape.map { $0 - 1 }
            #expect(try array.read(start: last, count: shape.map { _ in 1 }) == whole.slab(start: last, count: shape.map { _ in 1 }))
        }
    }

    /// A stopped series read whole keeps zeros after its last valid frame (an integer type; floats take NaN).
    @Test func aStoppedSeriesIsFilledAfterItsValidFrames() throws {
        let array = try TIAReader.read(url: url("old/03_Scanning Preview_1.ser"), onlyValidData: false).array
        #expect(array.shape == [200, 128, 128])
        let frame = try array.read(start: [199, 0, 0], count: [1, 128, 128])
        #expect(frame.doubles().allSatisfy { $0 == 0 })
    }

    @Test func refusesByName() throws {
        let source = try Data(contentsOf: url("old/16x16-point_spectrum-1x1024_1.ser"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("formato-tia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func planted(_ name: String, _ edit: (inout Data) -> Void) throws -> URL {
            var d = source
            edit(&d)
            let u = dir.appendingPathComponent(name)
            try d.write(to: u)
            return u
        }
        let notSER = try planted("a.ser") { $0[0] = 0x4D; $0[1] = 0x4D }
        #expect(throws: TIAError.notTIA("byte order 0x4D4D, series id 0x0197")) { _ = try TIAReader.read(url: notSER) }
        let noValid = try planted("b.ser") { d in for k in 18..<22 { d[k] = 0 } }
        #expect(throws: TIAError.noValidData) { _ = try TIAReader.read(url: noValid) }
        let short = try planted("c.ser") { $0 = $0.prefix($0.count - 100) }
        #expect(throws: TIAError.self) { _ = try TIAReader.read(url: short) }
        let tiny = try planted("d.ser") { $0 = $0.prefix(12) }
        #expect(throws: TIAError.self) { _ = try TIAReader.read(url: tiny) }
        // The element's DataType (byte 20 of a spectrum element at offset 84): 9 is complex64.
        let complex = try planted("e.ser") { $0[84 + 20] = 9; $0[84 + 21] = 0 }
        #expect(throws: FormatoReadError.unsupportedDataType("TIA complex64")) { _ = try TIAReader.read(url: complex) }
        let unknown = try planted("f.ser") { $0[84 + 20] = 11; $0[84 + 21] = 0 }
        #expect(throws: TIAError.dataType(11)) { _ = try TIAReader.read(url: unknown) }
    }

    /// Every truncation of a small file is refused or read, never a crash (a cheap fuzz over the header and element bytes).
    @Test func truncationsNeverCrash() throws {
        let source = try Data(contentsOf: url("old/16x16x5_STEM_BF_DF_preview_1.ser"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("formato-tia-fuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in stride(from: 0, to: source.count, by: 7) {
            let u = dir.appendingPathComponent("t\(n).ser")
            try source.prefix(n).write(to: u)
            if let signal = try? TIAReader.read(url: u) { _ = try? signal.array.readAll() }
        }
    }
}
