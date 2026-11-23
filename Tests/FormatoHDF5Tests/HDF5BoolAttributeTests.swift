//
//  HDF5BoolAttributeTests.swift
//  `HDF5WriteSession.setBoolAttribute` against h5py 3.16.0 (pin H1, FormatoKit#141; tools/hdf5-bool/generate.py): the type the kit
//  writes equals the type h5py writes for a NumPy `bool` (an enumeration over a signed 8-bit integer, FALSE = 0, TRUE = 1, scalar),
//  read back with the kit's own HDF5 layer and compared with the facts h5py recorded (Fixtures/bool/h5py-pins.json), exactly; the
//  file h5py wrote has those facts too; and, once the Mac step below has committed swift-bool.h5 and check-result.json, h5py reads
//  that kit-written file as `numpy.bool_` (the test is skipped until then).
//
//  Regenerating the kit-written file (a change on purpose): FORMATO_WRITE_GOLDEN=1 swift test -c release --filter
//  HDF5BoolAttributeTests, then tools/hdf5-bool/generate.py (it writes check-result.json), then commit both.
//

import CryptoKit
import Foundation
import Testing
import FormatoCore
import FormatoHDF5

struct BoolBasePin: Decodable {
    var kind: String, size: Int, signed: Bool, order: String
    enum CodingKeys: String, CodingKey { case kind = "class", size, signed, order }
}

struct BoolAttributePin: Decodable {
    var kind: String, size: Int, scalar: Bool, base: BoolBasePin?, members: [String: Int64]?, stored: Int64
    var numpyType: String, dtype: String, value: Bool
    enum CodingKeys: String, CodingKey {
        case kind = "class", size, scalar, base, members, stored, numpyType = "numpy_type", dtype, value
    }
}

struct BoolPins: Decodable {
    var h5pyVersion: String, attributes: [String: BoolAttributePin]
    enum CodingKeys: String, CodingKey { case h5pyVersion = "h5py_version", attributes }
}

struct BoolCheckResult: Decodable {
    struct File: Decodable {
        var sha256: String, attributes: [String: BoolAttributePin], readsAsNumpyBool: Bool
        enum CodingKeys: String, CodingKey { case sha256, attributes, readsAsNumpyBool = "reads_as_numpy_bool" }
    }
    var h5pyVersion: String, files: [String: File]
    enum CodingKeys: String, CodingKey { case h5pyVersion = "h5py_version", files }
}

@Suite(.serialized) struct HDF5BoolAttributeTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/bool")
    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
    static var golden: Bool { ProcessInfo.processInfo.environment["FORMATO_WRITE_GOLDEN"] != nil }
    static var checked: Bool { FileManager.default.fileExists(atPath: fixture("check-result.json").path) }
    /// The attributes both files carry (the generator's PLANTED): on the root, a group and a dataset, true and false.
    static let planted: [(path: String, name: String, value: Bool)] = [
        ("/", "yes", true), ("/", "no", false), ("/g", "yes", true), ("/g", "no", false), ("/g/d", "yes", true), ("/g/d", "no", false),
    ]

    static func pins() throws -> BoolPins {
        try JSONDecoder().decode(BoolPins.self, from: Data(contentsOf: fixture("h5py-pins.json")))
    }

    /// The kit's file: the planted attributes, each set through `setBoolAttribute`.
    static func writeKitFile(_ url: URL) throws {
        try HDF5AppendWriter.append(to: url) { session in
            try session.createGroup("/g")
            try session.writeDataset("/g/d", FormatoArray(dataType: .float32, shape: [3], bytes: Data(count: 12)))
            for (path, name, value) in planted { try session.setBoolAttribute(name, on: path, value) }
        }
    }

    /// The facts the kit's HDF5 layer reads equal the ones h5py recorded for the same attribute.
    static func expectH5pysType(_ url: URL, _ pins: [String: BoolAttributePin]) throws {
        let reader = try HDF5Reader(url: url)
        for (path, name, value) in planted {
            let key = "\(path)@\(name)"
            let pin = try #require(pins[key], "\(key) has no pin")
            let base = try #require(pin.base, "\(key): h5py recorded no base type")
            let facts = try #require(try reader.enumAttributeFacts(name, of: path), "\(key) is not an enumeration")
            // What h5py recorded for numpy.bool_: an enumeration, one byte, scalar, over a signed little-endian 8-bit integer.
            #expect(pin.kind == "enum" && pin.size == 1 && pin.scalar && pin.numpyType == "numpy.bool" && pin.dtype == "bool", "\(key)")
            #expect(base.kind == "integer" && base.size == 1 && base.signed && base.order == "little", "\(key)")
            #expect(pin.members == ["FALSE": 0, "TRUE": 1] && pin.value == value && pin.stored == (value ? 1 : 0), "\(key)")
            // The same facts, read with H5Aget_type, H5Tget_class, H5Tget_super and the member calls.
            #expect(facts.size == pin.size, "\(key)")
            #expect(facts.shape == (pin.scalar ? [] : [1]), "\(key)")
            #expect(facts.baseClass == 0, "\(key): the base is an integer (H5T_INTEGER)")
            #expect(facts.baseSize == base.size && facts.baseSigned == base.signed, "\(key)")
            #expect(facts.baseLittleEndian == (base.order == "little"), "\(key)")
            #expect(facts.members == pin.members, "\(key)")
            #expect(facts.values == [pin.stored], "\(key)")
            // The kit's generic reader takes it as the integer 0 or 1.
            #expect(try reader.attribute(name, of: path) == .integer(value ? 1 : 0), "\(key)")
        }
    }

    // MARK: Pin H1

    @Test func theKitWritesH5pysBooleanType() throws {
        let pins = try Self.pins()
        #expect(pins.h5pyVersion == "3.16.0")
        #expect(pins.attributes.count == Self.planted.count)
        if Self.golden {
            try? FileManager.default.removeItem(at: Self.fixture("swift-bool.h5"))
            try Self.writeKitFile(Self.fixture("swift-bool.h5"))
        }
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bool.h5")
        try Self.writeKitFile(url)
        try Self.expectH5pysType(url, pins.attributes)
    }

    @Test func theFileH5pyWroteHasThePinnedFacts() throws {
        try Self.expectH5pysType(Self.fixture("h5py-bool.h5"), try Self.pins().attributes)
    }

    @Test(.enabled(if: HDF5BoolAttributeTests.checked, "check-result.json is written by tools/hdf5-bool/generate.py from swift-bool.h5"))
    func h5pyReadsTheCommittedKitFileAsNumpyBool() throws {
        let result = try JSONDecoder().decode(BoolCheckResult.self, from: Data(contentsOf: Self.fixture("check-result.json")))
        #expect(result.h5pyVersion == "3.16.0")
        let file = try #require(result.files["swift-bool.h5"])
        let bytes = try Data(contentsOf: Self.fixture("swift-bool.h5"))
        #expect(file.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "check-result.json is of this file")
        #expect(file.readsAsNumpyBool)
        #expect(file.attributes.count == Self.planted.count)
        for (path, name, value) in Self.planted {
            let got = try #require(file.attributes["\(path)@\(name)"])
            #expect(got.numpyType == "numpy.bool" && got.value == value, "\(path)@\(name)")
        }
        try Self.expectH5pysType(Self.fixture("swift-bool.h5"), file.attributes)
    }

    // MARK: Replacing and refusing

    @Test func aBooleanReplacesAnyAttributeOfItsName() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("replace.h5")
        try HDF5AppendWriter.append(to: url) { session in
            try session.createGroup("/g")
            try session.setAttribute("flag", on: "/g", .text("not a bool"))
            try session.setBoolAttribute("flag", on: "/g", true)
            try session.setBoolAttribute("other", on: "/g", true)
            try session.setBoolAttribute("other", on: "/g", false)
        }
        let reader = try HDF5Reader(url: url)
        #expect(try reader.attributeNames(of: "/g") == ["flag", "other"])
        #expect(try reader.enumAttributeFacts("flag", of: "/g")?.values == [1])
        #expect(try reader.enumAttributeFacts("other", of: "/g")?.values == [0])
        #expect(try reader.attribute("other", of: "/g") == .integer(0))
        // Appending again replaces a boolean with a number, and a number is not an enumeration.
        try HDF5AppendWriter.append(to: url) { try $0.setAttribute("flag", on: "/g", .integer(7)) }
        #expect(try reader.enumAttributeFacts("flag", of: "/g") == nil)
    }

    @Test func refusalsByName() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("refuse.h5")
        try HDF5AppendWriter.append(to: url) { session in
            #expect(throws: HDF5FileError.invalidPath("")) { try session.setBoolAttribute("", on: "/", true) }
            #expect(throws: HDF5FileError.invalidPath("a\0b")) { try session.setBoolAttribute("a\0b", on: "/", true) }
            #expect(throws: HDF5FileError.notFound("/missing")) { try session.setBoolAttribute("flag", on: "/missing", true) }
        }
        #expect(try HDF5Reader(url: url).attributeNames(of: "/").isEmpty)
    }
}
