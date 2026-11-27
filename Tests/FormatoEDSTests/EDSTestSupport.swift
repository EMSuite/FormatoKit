//
//  EDSTestSupport.swift
//  What the moved SEM-EDS tests share: the fixture folder beside this file (Tests/FormatoEDSTests/Fixtures, the app's
//  tools/parity/sem m7/read-* bundles and their rsciio inputs, copied byte for byte from Electron Microscopy Studio at f1eaafc by
//  FormatoKit#148), a fresh temporary folder, the flattened metadata the bundles hold (emit.py's `_eds_metadata` keys), and the
//  sparse counts of a spectrum image's signal.
//

import CryptoKit
import Foundation
import FormatoCore
import FormatoEDS
import XCTest

nonisolated enum EDSFixtures {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// A committed RosettaSciIO test file, by its path under fixtures/rsciio (`bruker/P45_the_default_job.bcf`).
    static func rsciio(_ path: String) -> URL { SEMParityReference.fixturesRoot.appendingPathComponent("rsciio/" + path) }

    static func sha256(_ data: some DataProtocol) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension XCTestCase {
    /// A fresh temporary folder named `<prefix>-<uuid>`, removed after the test.
    func scratchFolder(_ prefix: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}

extension EDSMetadata {
    /// The fields under emit.py's flattened keys (the app's tools/parity/sem/emit.py, `_eds_metadata`), present only where set.
    var flattened: [String: Any] {
        var out: [String: Any] = [:]
        func put(_ key: String, _ value: Any?) { if let value { out[key] = value } }
        put("original_filename", originalFilename); put("title", title); put("date", date); put("time", time)
        put("signal_type", signalType); put("mode", mode); put("beam_energy", beamEnergy); put("magnification", magnification)
        put("azimuth_angle", azimuthAngle); put("elevation_angle", elevationAngle); put("energy_resolution_MnKa", energyResolutionMnKa)
        put("live_time", liveTime); put("real_time", realTime); put("detector_type", detectorType); put("tilt_alpha", tiltAlpha)
        put("sample_name", sampleName); put("elements", elements); put("xray_lines", xrayLines)
        return out
    }
}

extension FormatoLazySignal {
    /// The sparse counts of a spectrum image's signal (a test failure, not a crash, for any other signal).
    func cube(file: StaticString = #filePath, line: UInt = #line) throws -> EDSSparseSpectrumImage {
        try XCTUnwrap(EDSFile.counts(of: self), "not a spectrum image: \(title)", file: file, line: line)
    }

    /// The metadata the reader wrote.
    var eds: EDSMetadata { EDSMetadata(metadata) }
}
