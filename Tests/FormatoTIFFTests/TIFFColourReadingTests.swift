//
//  TIFFColourReadingTests.swift
//  TIFFAppImage's brightest-channel reading of a colour TIFF (FormatoKit#93) against NumPy's `rgb.max(axis=-1)` on files
//  tifffile wrote (tools/tiff-colour/generate.py, pins in Fixtures/colour/pins.json): exact, both byte orders and LZW, in both
//  `read` (Float32) and `readStored` (uint8). The default still refuses a colour image by name.
//

import Foundation
import Testing
import FormatoCore
import FormatoTIFF

@Suite struct TIFFColourReadingTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/colour")
    static var cases: [[String: Any]] {
        let root = try? JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("pins.json"))) as? [String: Any]
        return root?["cases"] as? [[String: Any]] ?? []
    }

    @Test func theBrightestChannelEqualsNumPysMax() throws {
        #expect(Self.cases.count == 3)
        for c in Self.cases {
            let name = c["name"] as! String
            let shape = c["shape"] as! [Int]
            let expected = (c["brightest"] as! [Int]).map(UInt8.init)
            let path = Self.fixtures.appendingPathComponent(name + ".tif").path

            let stored = try TIFFAppImage.readStored(path: path, colour: .brightestChannel)
            #expect(stored.width == shape[1] && stored.height == shape[0], "\(name)")
            #expect(stored.pixels.dataType == .uint8, "\(name): one byte a pixel")
            #expect([UInt8](stored.pixels.bytes) == expected, "\(name): readStored")
            #expect(stored.notes.contains(TIFFAppImage.Note.colourRender), "\(name)")
            #expect(!stored.notes.contains(TIFFAppImage.Note.render), "\(name)")

            let image = try TIFFAppImage.read(path: path, colour: .brightestChannel)
            #expect(image.pixels == expected.map(Float.init), "\(name): read")
            #expect(image.notes == stored.notes && image.source == stored.source, "\(name)")

            // The default refuses a colour image by name, as before.
            #expect(throws: TIFFAppImage.Refusal.self) { try TIFFAppImage.readStored(path: path) }
            #expect(throws: TIFFAppImage.Refusal.self) { try TIFFAppImage.read(path: path) }
        }
    }

    /// An exact grey render reads the same with or without the option, and keeps its render note.
    @Test func aGreyRenderIsUnchangedByTheOption() throws {
        let path = TIFFAppImageTests.path("rgb-grey-II")
        let plain = try TIFFAppImage.readStored(path: path)
        let option = try TIFFAppImage.readStored(path: path, colour: .brightestChannel)
        #expect(plain == option)
        #expect(option.notes.contains(TIFFAppImage.Note.render))
        #expect(try TIFFAppImage.read(path: path) == TIFFAppImage.read(path: path, colour: .brightestChannel))
    }
}
