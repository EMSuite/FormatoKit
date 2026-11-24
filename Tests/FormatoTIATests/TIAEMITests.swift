//
//  TIAEMITests.swift
//  FormatoTIA's .emi reading against HyperSpy 2.5.0 loading RosettaSciIO 049e7d70's public .emi files (pin T2,
//  tools/tia/emi-pins.py): one signal per .ser, its values' sha256, every axis bit for bit (an image's units now from the
//  .emi's mode), General.date and General.time, and every mapped metadata entry (numbers bit for bit); then planted .emi
//  files for what no public file shows (a `_0.ser`, a document missing AcquireInfo, refusals) and a truncation fuzz.
//

import CryptoKit
import Foundation
import Testing
import FormatoCore
import FormatoTIA

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

private struct EMIPins: @unchecked Sendable {  // immutable after load
    let files: [String: [String: Any]]
}

private let emiPins: EMIPins = {
    let url = fixtures.appendingPathComponent("tia-emi-pins.json")
    let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    return EMIPins(files: json["files"] as! [String: [String: Any]])
}()

private func bitPattern(_ hex: String) -> UInt64 {
    var value: UInt64 = 0
    let bytes = stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }
    for (i, b) in bytes.enumerated() { value |= UInt64(b) << (8 * UInt64(i)) }
    return value
}

private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func publicURL(_ key: String) -> URL { fixtures.appendingPathComponent("public").appendingPathComponent(key) }

private let emiKeys: [String] = emiPins.files.keys.sorted()

/// A fresh folder for planted files, removed by the caller.
private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("formato-emi-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// An .emi of `documents` (each an `<ObjectInfo>` body), after a few bytes of binary header as TIA writes.
private func emiBytes(_ documents: [String]) -> Data {
    var d = Data([0x4A, 0x00, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00])
    for doc in documents { d += Data("<ObjectInfo>\(doc)</ObjectInfo>".utf8) + Data([0, 0, 0, 0]) }
    return d
}

private func experimentalDescription(_ rows: [(String, String, String)]) -> String {
    "<ExperimentalDescription><Root>" + rows.map { "<Data><Label>\($0.0)</Label><Value>\($0.1)</Value><Unit>\($0.2)</Unit></Data>" }
        .joined() + "</Root></ExperimentalDescription>"
}

@Suite("TIA .emi against HyperSpy and RosettaSciIO")
struct TIAEMITests {
    @Test func everyPublicEMIIsPinned() {
        #expect(emiKeys.count == 21)
    }

    @Test(arguments: emiKeys)
    func readEqualsHyperSpy(key: String) throws {
        let entry = emiPins.files[key]!
        #expect(digest(try Data(contentsOf: publicURL(key))) == entry["sha256"] as! String, "\(key): the fixture is the public file")
        if entry["error"] != nil {
            #expect(throws: (any Error).self, "\(key)") { _ = try TIAReader.readEMI(url: publicURL(key)) }
            return
        }
        let want = entry["signals"] as! [[String: Any]]
        let signals = try TIAReader.readEMI(url: publicURL(key))
        #expect(signals.count == want.count, "\(key) signal count")
        for (signal, w) in zip(signals, want) {
            let name = w["original_filename"] as! String
            #expect(signal.metadata["General.original_filename"]?.value.text == name, "\(key)")
            #expect(signal.array.dataType.rawValue == w["dtype"] as! String, "\(name) dtype")
            #expect(signal.array.shape == w["shape"] as! [Int], "\(name) shape")
            #expect(digest(try signal.array.readAll().bytes) == w["sha256"] as! String, "\(name) values")
            let axes = w["axes"] as! [[String: Any]]
            #expect(signal.axes.count == axes.count, "\(name) axis count")
            for (got, a) in zip(signal.axes, axes) {
                #expect(got.name == a["name"] as? String, "\(name) axis name")
                #expect(got.size == a["size"] as! Int, "\(name) axis size")
                #expect(got.units == a["units"] as! String, "\(name) axis units")
                #expect(got.navigate == a["navigate"] as! Bool, "\(name) navigate")
                #expect(got.scale.bitPattern == bitPattern(a["scale"] as! String), "\(name) scale \(got.scale)")
                #expect(got.offset.bitPattern == bitPattern(a["offset"] as! String), "\(name) offset \(got.offset)")
            }
            #expect(signal.metadata["General.date"]?.value.text == w["date"] as? String, "\(name) date")
            #expect(signal.metadata["General.time"]?.value.text == w["time"] as? String, "\(name) time")
            let mapped = w["mapped"] as! [[String: Any]]
            let keys = Set(signal.metadata.keys.filter { $0.hasPrefix("Acquisition_instrument.") || $0 == "General.authors" })
            #expect(keys == Set(mapped.map { $0["key"] as! String }), "\(name) mapped keys")
            for m in mapped {
                let k = m["key"] as! String
                let got = signal.metadata[k]?.value
                if m["kind"] as! String == "number" {
                    #expect(got?.number?.bitPattern == bitPattern(m["bits"] as! String), "\(name) \(k): \(String(describing: got))")
                } else {
                    #expect(got?.text == m["value"] as? String, "\(name) \(k): \(String(describing: got))")
                }
            }
        }
    }

    /// The .emi changes only an image's units: values and every other axis are what the .ser alone gives.
    @Test func theEMIGivesADiffractionPatternReciprocalUnits() throws {
        let alone = try TIAReader.read(url: publicURL("old/64x64_diffraction_acquire_1.ser"))
        let viaEMI = try #require(try TIAReader.readEMI(url: publicURL("old/64x64_diffraction_acquire.emi")).first)
        #expect(alone.axes.map(\.units) == ["nm", "nm"])
        #expect(viaEMI.axes.map(\.units) == ["1 / nm", "1 / nm"])
        #expect(try viaEMI.array.readAll().bytes == alone.array.readAll().bytes)
        #expect(viaEMI.metadata["Acquisition_instrument.TEM.camera_length"]?.units == "mm")
    }

    /// A folder that cannot be listed (what an App Sandbox app sees when it was given the .emi alone, here a folder without
    /// read permission): the .ser files are still found by name (#163). It used to throw `cannotOpen` on the folder.
    @Test func aFolderThatCannotBeListedStillGivesItsSeries() throws {
        let dir = try scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let ser = try Data(contentsOf: publicURL("old/64x64_TEM_images_acquire_1.ser"))
        try emiBytes([experimentalDescription([("User", "first", "")])]).write(to: dir.appendingPathComponent("p.emi"))
        try ser.write(to: dir.appendingPathComponent("p_1.ser"))
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: dir.path)   // enter and write, not list
        let signals = try TIAReader.readEMI(url: dir.appendingPathComponent("p.emi"))
        #expect(signals.map { $0.metadata["General.original_filename"]?.value.text } == ["p_1.ser"])
    }

    /// Planted: `_0.ser` takes the last document (Python's index −1); `_2.ser` the second; units and dates come from the first.
    @Test func eachSeriesTakesItsDocument() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ser = try Data(contentsOf: publicURL("old/64x64_TEM_images_acquire_1.ser"))
        let first = "<AcquireDate>Sun Feb 21 17:50:18 2016</AcquireDate><AcquireInfo><CameraNamePath>A</CameraNamePath></AcquireInfo>"
            + experimentalDescription([("Mode", " TEM Diffraction", ""), ("User", "first", "")])
        let second = "<AcquireDate>Mon Feb 22 01:02:03 2016</AcquireDate>" + experimentalDescription([("User", "second", ""), ("High tension", "300", "kV")])
        let third = experimentalDescription([("User", "third", ""), ("Stage X", "-0.159", "um"), ("Microscope", "Microscope X Microscope Y", "")])
        try emiBytes([first, second, third]).write(to: dir.appendingPathComponent("p.emi"))
        for d in [0, 2] { try ser.write(to: dir.appendingPathComponent("p_\(d).ser")) }
        try ser.write(to: dir.appendingPathComponent("p_10.ser"))  // not one digit: not read
        try ser.write(to: dir.appendingPathComponent("p_1.SER"))  // another case: not read
        let signals = try TIAReader.readEMI(url: dir.appendingPathComponent("p.emi"))
        #expect(signals.map { $0.metadata["General.original_filename"]?.value.text } == ["p_0.ser", "p_2.ser"])
        #expect(signals.map { $0.metadata["General.authors"]?.value.text } == ["third", "second"])
        #expect(signals.allSatisfy { $0.metadata["General.date"]?.value.text == "2016-02-21" })
        #expect(signals.allSatisfy { $0.metadata["General.time"]?.value.text == "17:50:18" })
        #expect(signals.allSatisfy { $0.axes.map(\.units) == ["1 / nm", "1 / nm"] })
        #expect(signals[0].metadata["Acquisition_instrument.TEM.Stage.x"]?.value.number == -0.159 * 1e-3)
        #expect(signals[0].metadata["Acquisition_instrument.TEM.microscope"]?.value.text == "X Y")
        #expect(signals[1].metadata["Acquisition_instrument.TEM.beam_energy"]?.value.number == 300)
        #expect(signals[1].metadata["Acquisition_instrument.TEM.acquisition_mode"] == nil)
    }

    /// Planted: Diffraction mode without AcquireInfo stays in metres (RosettaSciIO's AttributeError path); STEM mode with no
    /// camera and an image stack too; a value that does not read as a number stays text; an odd date gives no date.
    @Test func unitsAndValuesFollowRosettaSciIOsBranches() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ser = try Data(contentsOf: publicURL("old/64x64_TEM_images_acquire_1.ser"))
        func read(_ doc: String) throws -> FormatoLazySignal {
            let name = "q\(UUID().uuidString.prefix(8))"
            try emiBytes([doc]).write(to: dir.appendingPathComponent("\(name).emi"))
            try ser.write(to: dir.appendingPathComponent("\(name)_1.ser"))
            return try #require(try TIAReader.readEMI(url: dir.appendingPathComponent("\(name).emi")).first)
        }
        let noInfo = try read("<AcquireDate>2016-02-21T17:50:18</AcquireDate>" + experimentalDescription([("Mode", "Diffraction", "")]))
        #expect(noInfo.axes.map(\.units) == ["nm", "nm"])
        #expect(noInfo.metadata["General.date"] == nil && noInfo.metadata["General.time"] == nil)
        let emptyInfo = try read("<AcquireInfo></AcquireInfo>" + experimentalDescription([("Mode", "Diffraction", ""), ("Magnification", "V", "x")]))
        #expect(emptyInfo.axes.map(\.units) == ["1 / nm", "1 / nm"])
        #expect(emptyInfo.metadata["Acquisition_instrument.TEM.magnification"]?.value.text == "V")
        let stem = try read("<AcquireInfo><DwellTimePath>1</DwellTimePath></AcquireInfo>" + experimentalDescription([("Mode", "STEM", "")]))
        #expect(stem.axes.map(\.units) == ["nm", "nm"])
        #expect(stem.metadata["Acquisition_instrument.TEM.acquisition_mode"]?.value.text == "STEM")
        #expect(stem.metadata["Acquisition_instrument.TEM.Detector.Camera.exposure"]?.value.text == "1")
        let spaced = try read(experimentalDescription([("Camera length", " 0.25 ", "m"), ("Stage A", "-0.00", "deg")]))
        #expect(spaced.metadata["Acquisition_instrument.TEM.camera_length"]?.value.number == 250)
        #expect(spaced.metadata["Acquisition_instrument.TEM.Stage.tilt_alpha"]?.value.number?.sign == .minus)
    }

    @Test func refusesByName() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ser = try Data(contentsOf: publicURL("old/64x64_TEM_images_acquire_1.ser"))
        func plant(_ name: String, _ bytes: Data, series: Bool = true) throws -> URL {
            try bytes.write(to: dir.appendingPathComponent("\(name).emi"))
            if series { try ser.write(to: dir.appendingPathComponent("\(name)_1.ser")) }
            return dir.appendingPathComponent("\(name).emi")
        }
        #expect(throws: TIAError.emi("no <ObjectInfo> document")) { _ = try TIAReader.readEMI(url: try plant("a", Data("no xml here".utf8))) }
        #expect(throws: TIAError.emi("an <ObjectInfo> with no </ObjectInfo>")) {
            _ = try TIAReader.readEMI(url: try plant("b", Data("xx<ObjectInfo><Uuid>1</Uuid>".utf8)))
        }
        #expect(throws: TIAError.self) { _ = try TIAReader.readEMI(url: try plant("c", emiBytes(["<A><B></A>"]))) }
        #expect(throws: TIAError.self) {
            _ = try TIAReader.readEMI(url: try plant("d", Data("xx<ObjectInfo>".utf8) + Data([0xFF, 0xFE]) + Data("</ObjectInfo>".utf8)))
        }
        let deep = String(repeating: "<a>", count: 100) + String(repeating: "</a>", count: 100)
        #expect(throws: TIAError.self) { _ = try TIAReader.readEMI(url: try plant("e", emiBytes([deep]))) }
        #expect(throws: TIAError.self) { _ = try TIAReader.readEMI(url: try plant("f", emiBytes(["<Uuid>1</Uuid>"]), series: false)) }
    }

    /// Every truncation of a public .emi is refused or read, never a crash.
    @Test func truncationsNeverCrash() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Data(contentsOf: publicURL("old/64x64_diffraction_acquire.emi"))
        let ser = try Data(contentsOf: publicURL("old/64x64_diffraction_acquire_1.ser"))
        for n in stride(from: 0, to: source.count, by: max(1, source.count / 300)) {
            try source.prefix(n).write(to: dir.appendingPathComponent("t\(n).emi"))
            try ser.write(to: dir.appendingPathComponent("t\(n)_1.ser"))
            _ = try? TIAReader.readEMI(url: dir.appendingPathComponent("t\(n).emi"))
        }
    }
}
