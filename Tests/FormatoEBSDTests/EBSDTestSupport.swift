//
//  EBSDTestSupport.swift
//  What the moved EBSD tests share: the fixture folder beside this file (Tests/FormatoEBSDTests/Fixtures, copied byte for byte from
//  Electron Microscopy Studio's EMStudioTests/Fixtures and tools/parity/sem at 67d6df4 by FormatoKit#147), a sha256, and the few
//  numbers orix's `CrystalMap` derives from a map's columns (its points in data, shape, steps and phases in data). The app's tests
//  read those from DiffractoKit's `CrystalMap`; a kit holds no crystal map (ADR 0005), so the tests derive them here with the
//  readers' own port of orix's grid arithmetic (`EBSDMapColumns.stepSize`, `checkedSlices`) and hold them to the same truths.
//

import CryptoKit
import Foundation
@testable import FormatoEBSD

nonisolated enum EBSDFixtures {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A Velox file of FormatoKit's own tests: an HDF5 file that is not an EBSD file.
    static let velox = folder.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("FormatoEMDTests/Fixtures/velox-tiny.emd")
}

/// orix 0.15.0's `CrystalMap` view of a map's columns: the points `is_in_data` keeps and what orix derives from them.
nonisolated struct OrixView {
    let map: EBSDMapColumns

    init(_ map: EBSDMapColumns) { self.map = map }

    /// The indices of the points in data.
    var inData: [Int] {
        guard let keep = map.isInData else { return Array(0..<map.pointCount) }
        return keep.indices.filter { keep[$0] }
    }

    /// The points in data.
    var size: Int { inData.count }

    /// x of the points in data; orix's 0, 1, 2, ... where the file gives neither x nor y.
    var x: [Double] {
        if map.x == nil, map.y == nil { return inData.map(Double.init) }
        return (map.x ?? []).isEmpty ? [] : inData.map { map.x![$0] }
    }

    var y: [Double] { (map.y ?? []).isEmpty ? [] : inData.map { map.y![$0] } }

    var phaseIDs: [Int] { inData.map { map.phaseIDs?[$0] ?? 0 } }

    var euler: [SIMD3<Double>] { inData.map { map.euler[$0] } }

    func property(_ name: String) -> [Double]? { map.properties[name].map { values in inData.map { values[$0] } } }

    /// orix's `dx`, `dy`: the step from the sorted unique coordinates, 0 for fewer than two.
    var dx: Double { EBSDMapColumns.stepSize(x) }
    var dy: Double { EBSDMapColumns.stepSize(y) }

    /// orix's `shape`: the extent of every axis with a step (y, then x).
    func shape() throws -> [Int] {
        try EBSDMapColumns.checkedSlices([("y", y), ("x", x)]).map { $0.stop - $0.start }
    }

    /// The file's phase headers of the ids in data (orix's `CrystalMap` keeps those of its phase list), in id order.
    var phases: [EBSDPhaseHeader] {
        let ids = Set(phaseIDs)
        return map.phaseHeaders.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
    }

    /// orix's phase ids of the map: the not-indexed −1 first where a point has it, then the headers' ids in data, then the ids in data
    /// no header names (orix's unnamed phases).
    var phaseList: [Int] {
        let ids = Set(phaseIDs)
        var out = ids.contains(-1) ? [-1] : []
        let named = phases.map(\.id)
        out += named
        out += ids.subtracting(named).subtracting([-1]).sorted()
        return out
    }

    func phase(id: Int) -> EBSDPhaseHeader? { map.phaseHeaders.first { $0.id == id } }
}
