//
//  NORDIFOpeningTests.swift
//  Moved from Electron Microscopy Studio's EMStudioTests (at 67d6df4) by FormatoKit#147; the app's routing and Info rows stay in the app.
//  A NORDIF acquisition as one dataset (`NORDIFOpening`): `Pattern.dat` opens as an `EBSDDataset` whose patterns are read from the
//  file by map position and equal NORDIFScan's bit for bit (the scan's parity against kikuchipy 0.13.1 is NORDIFReaderTests); a `.dat`
//  counts only with a NORDIF `Setting.txt` beside it; a short pattern file reads its whole records and the rest as 0, with a note; a
//  background bitmap that is there and cannot be read is named in a note; a `Setting.txt` that is there and may not be read is named
//  in the refusal (`notPermitted`).
//

import Darwin
import Foundation
import FormatoCore
import XCTest
@testable import FormatoEBSD

nonisolated final class NORDIFOpeningTests: XCTestCase {
    private static let folder = EBSDFixtures.url("sem/nordif")

    /// The dataset of `url` and its pattern reader, as a consumer opens them.
    private func open(_ url: URL) throws -> (dataset: EBSDDataset, reader: EBSDPatternReader) {
        let dataset = try NORDIFOpening.open(url: url).validated()
        return (dataset, try EBSDPatternReader(dataset))
    }
    private func url(_ name: String) -> URL { Self.folder.appendingPathComponent(name) }
    private var scratch: [URL] = []

    override func tearDown() {
        for folder in scratch { try? FileManager.default.removeItem(at: folder) }
        scratch = []
        super.tearDown()
    }

    /// A fresh folder holding the given pattern bytes as `Pattern.dat` and, when `settings` names one, that fixture as `Setting.txt`.
    private func folder(patternBytes: Data, settings: String? = "Setting.txt") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nordif-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scratch.append(folder)
        if let settings { try FileManager.default.copyItem(at: url(settings), to: folder.appendingPathComponent("Setting.txt")) }
        try patternBytes.write(to: folder.appendingPathComponent("Pattern.dat"))
        return folder
    }

    func testPatternDatOpensAsADatasetWithTheSettingsGridDetectorAndHeader() throws {
        let (dataset, _) = try open(url("Pattern.dat"))
        XCTAssertEqual(dataset.format, .nordif)
        XCTAssertEqual(dataset.manufacturer, "NORDIF")
        XCTAssertEqual(dataset.version, "3.1.2")
        XCTAssertEqual([dataset.scanRows, dataset.scanColumns, dataset.patternRows, dataset.patternColumns], [3, 3, 60, 60])
        XCTAssertEqual(dataset.dataType, .uint8)
        XCTAssertEqual([dataset.stepY, dataset.stepX], [1.5, 1.5])
        XCTAssertEqual(dataset.scanUnit, "um")
        XCTAssertEqual(dataset.detector.sampleTilt, 70)
        XCTAssertEqual(dataset.detector.tilt, 0)
        XCTAssertEqual(dataset.detector.projectionCenters, [SIMD3(0.5, 0.5, 0.5)])
        XCTAssertEqual(dataset.sem, EBSDSEMHeader(beamEnergyKeV: 20, magnification: 200, workingDistanceMM: 24.7, microscope: "Hitachi SU-6600"))
        XCTAssertEqual(dataset.notes, [])
        let background = try XCTUnwrap(dataset.staticBackground)
        XCTAssertEqual(background.shape, [60, 60])
        XCTAssertEqual(background.bytes, Data(try NORDIFBitmap.read(path: url("Background acquisition pattern.bmp").path).pixels))
    }

    func testThePatternsReadFromTheFileEqualTheScanBitForBit() throws {
        let scan = try NORDIFScan.read(patternFile: url("Pattern.dat").path)
        let (dataset, reader) = try open(url("Pattern.dat"))
        for row in 0..<3 {
            for column in 0..<3 {
                XCTAssertEqual(try reader.pattern(row: row, column: column).bytes, Data(scan.pattern(row: row, column: column)), "(\(row), \(column))")
            }
            let start = row * 3 * 3600
            XCTAssertEqual(try reader.row(row).bytes, Data(scan.patterns[start..<(start + 3 * 3600)]), "row \(row)")
        }
        XCTAssertEqual(try dataset.allPatterns().bytes, Data(scan.patterns))
    }

    func testAShortPatternFileReadsItsWholeRecordsAndTheRestAsZero() throws {
        let whole = try Data(contentsOf: url("Pattern.dat"))
        let folder = try folder(patternBytes: whole.prefix(whole.count - 3600 - 100))
        let (dataset, reader) = try open(folder.appendingPathComponent("Pattern.dat"))
        XCTAssertEqual(dataset.notes, ["Pattern.dat holds 7 of the 3 x 3 patterns of 60 x 60 px the settings give; the missing ones read 0."])
        XCTAssertEqual(try reader.pattern(row: 2, column: 0).bytes, whole[(6 * 3600)..<(7 * 3600)])
        XCTAssertEqual(try reader.pattern(row: 2, column: 1).bytes, Data(count: 3600), "the incomplete record reads 0")
        XCTAssertEqual(try reader.pattern(row: 2, column: 2).bytes, Data(count: 3600))
    }

    func testAPatternDatCountsOnlyWithItsSettings() throws {
        XCTAssertTrue(NORDIFOpening.isNORDIFFile(url("Pattern.dat")))
        XCTAssertTrue(NORDIFOpening.isSettingsFile(url("Setting.txt")))
        let lone = try folder(patternBytes: Data([1, 2, 3]), settings: nil)
        XCTAssertFalse(NORDIFOpening.isNORDIFFile(lone.appendingPathComponent("Pattern.dat")), "no Setting.txt beside it")
        XCTAssertEqual(NORDIFOpening.readableExtensions, ["dat"])
    }

    func testABrokenSettingsFileIsRefusedWithItsSentence() throws {
        let whole = try Data(contentsOf: url("Pattern.dat"))
        let folder = try folder(patternBytes: whole)
        let settings = folder.appendingPathComponent("Setting.txt")
        let lines = try String(contentsOf: settings, encoding: .isoLatin1).components(separatedBy: "\r\n").filter { !$0.hasPrefix("Number of samples") }
        try lines.joined(separator: "\r\n").data(using: .isoLatin1)!.write(to: settings)
        let pattern = folder.appendingPathComponent("Pattern.dat")
        let sentence = "Setting.txt cannot be read: its [Area] section has no 'Number of samples' line."
        XCTAssertThrowsError(try open(pattern)) { error in
            XCTAssertEqual(error as? EBSDReadError, EBSDReadError(.missing("Number of samples"), sentence))
        }
    }

    /// A `Background acquisition pattern.bmp` that is there and cannot be read leaves the scan without a static background and says
    /// so in one note that names the bitmap and why; a folder without one keeps no note (kikuchipy
    /// reads on without it). File mode 000 stands in for the sandbox. Red before: the bitmap was dropped with its reason, no note.
    func testABackgroundThatIsThereAndCannotBeReadIsNamedInANote() throws {
        XCTAssertNotEqual(geteuid(), 0, "root reads a mode-000 file; run this as a user")
        let whole = try Data(contentsOf: url("Pattern.dat"))
        let none = try folder(patternBytes: whole)
        let (plain, _) = try open(none.appendingPathComponent("Pattern.dat"))
        XCTAssertNil(plain.staticBackground)
        XCTAssertEqual(plain.notes, [], "no bitmap there: no note")

        let locked = try folder(patternBytes: whole)
        let bitmap = locked.appendingPathComponent("Background acquisition pattern.bmp")
        try FileManager.default.copyItem(at: url("Background acquisition pattern.bmp"), to: bitmap)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: bitmap.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bitmap.path) }
        let (dataset, _) = try open(locked.appendingPathComponent("Pattern.dat"))
        XCTAssertNil(dataset.staticBackground)
        XCTAssertEqual(dataset.notes.count, 1)
        let note = try XCTUnwrap(dataset.notes.first)
        XCTAssertTrue(note.hasPrefix("Background acquisition pattern.bmp beside Pattern.dat could not be read, so the scan's mean pattern "
            + "stands in for it: "), note)

        // A bitmap the decoder refuses is named in the decoder's own sentence.
        let broken = try folder(patternBytes: whole)
        try Data("not a bitmap".utf8).write(to: broken.appendingPathComponent("Background acquisition pattern.bmp"))
        let (refused, _) = try open(broken.appendingPathComponent("Pattern.dat"))
        XCTAssertNil(refused.staticBackground)
        XCTAssertEqual(refused.notes, ["Background acquisition pattern.bmp is not a Windows bitmap. The scan's mean pattern stands in for it."])
    }

    /// A `Setting.txt` that is there and may not be read (the sandbox's case: a signed build is granted the picked `Pattern.dat`, not
    /// its folder) is named in the refusal, with the folder; file mode 000 stands in for the sandbox. A `.dat` with no settings file,
    /// or with one that opens, gets no such sentence. Red before: Foundation's error.
    func testASettingsFileThatMayNotBeReadIsNamedInTheRefusal() throws {
        XCTAssertNotEqual(geteuid(), 0, "root reads a mode-000 file; run this as a user")
        let folder = try folder(patternBytes: try Data(contentsOf: url("Pattern.dat")))
        let settings = folder.appendingPathComponent("Setting.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path) }
        let pattern = folder.appendingPathComponent("Pattern.dat")
        XCTAssertFalse(NORDIFOpening.isNORDIFFile(pattern), "a settings file that cannot be opened cannot be recognised")
        let refusal = EBSDReadError(.notPermitted, "Setting.txt beside Pattern.dat cannot be read: macOS does not let this process open it "
            + "(Permission denied); a NORDIF scan needs the acquisition's folder, not Pattern.dat alone.")
        XCTAssertEqual(NORDIFOpening.unreadableSettingsRefusal(pattern), refusal)
        // The open gives the same refusal, not Foundation's error.
        XCTAssertThrowsError(try open(pattern)) { error in
            XCTAssertEqual(error as? EBSDReadError, refusal)
        }
        let lone = try self.folder(patternBytes: Data([1, 2, 3]), settings: nil)
        XCTAssertNil(NORDIFOpening.unreadableSettingsRefusal(lone.appendingPathComponent("Pattern.dat")), "no Setting.txt beside it")
        XCTAssertNil(NORDIFOpening.unreadableSettingsRefusal(url("Pattern.dat")), "its Setting.txt opens")
        XCTAssertNil(NORDIFOpening.unreadableSettingsRefusal(settings), "not a .dat")
    }

    /// The probe an app's Open decides by (whether to ask for the folder): 0 for a settings file that opens, ENOENT for none
    /// beside the `.dat`, the file mode's EACCES, nil for a file that is not a `.dat`; the sandbox's refusal is EPERM, which only a
    /// signed build shows. Red under: the probe answering anything but the open's errno (a file mode would read as the sandbox's).
    func testTheSettingsProbeTellsAReadableAMissingAndALockedSettingsFileApart() throws {
        XCTAssertNotEqual(geteuid(), 0, "root reads a mode-000 file; run this as a user")
        XCTAssertEqual(NORDIFOpening.settingsOpenError(url("Pattern.dat")), 0)
        XCTAssertNil(NORDIFOpening.settingsOpenError(url("Setting.txt")), "not a .dat")
        let lone = try folder(patternBytes: Data([1, 2, 3]), settings: nil)
        XCTAssertEqual(NORDIFOpening.settingsOpenError(lone.appendingPathComponent("Pattern.dat")), ENOENT)
        let locked = try folder(patternBytes: Data([1, 2, 3]))
        let settings = locked.appendingPathComponent("Setting.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path) }
        XCTAssertEqual(NORDIFOpening.settingsOpenError(locked.appendingPathComponent("Pattern.dat")), EACCES)
    }
}
