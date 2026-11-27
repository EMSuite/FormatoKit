//
//  ANGWriter.swift
//  Moved from Electron Microscopy Studio's Sources/TEMSEM/Export (at 7b09bf5) by FormatoKit#147.
//  Role: write an orientation map laid out on its data extent (`EBSDMapGrid`) as an EDAX TSL `.ang` file, as orix 0.15.0's
//        `orix/io/plugins/ang.py` `file_writer` writes it (GPL-3.0-or-later, see NOTICE): the header with the phases in reversed order
//        (EDAX TSL OIM Analysis 7.2 reads them so), each phase's proper point group under EDAX's alias, the lattice at three decimals,
//        the grid and steps; then one row per cell of the data extent with phi1, Phi, phi2 (the rotations' Bunge angles, `to_euler`),
//        x, y, image quality, confidence index, phase id, detector signal, pattern fit and any extra columns, every number rounded to
//        five decimals as numpy rounds (`np.round`: times 10⁵, half to even, divided) and the property columns held in float32 as orix
//        holds them. Cells not indexed or not in data take orix's values (Euler 4π, IQ 0, CI −1, phase 0 on a multi-phase map and −1
//        on a one-phase map, detector signal 0, fit 180, extra 0). Coordinates restart at 0 on the data extent with the map's steps
//        (`create_coordinate_arrays`); a 1D map is one row with y step 1.
//
//        Parity: Electron Microscopy Studio's bundles `m8/write-ang-*` (figure F18; the written bytes equal orix's for the sdss map, its
//        ferrite points, a 10 × 10 window and the Ti head) hold the whole chain from a `CrystalMap` and stay with the app, which builds
//        the grid; here, Tests/FormatoEBSDTests/MapWriterTests.swift reads written files back through `ANGReader`.
//

import FormatoCore
import Foundation

public nonisolated enum ANGWriter {
    public static let fileExtension = "ang"

    /// orix's `file_writer` keywords: which property feeds each column (nil: orix's search by name), extra columns, and the
    /// `OPERATOR:` line (orix writes `orix_v<version>`).
    public struct Options: Sendable, Equatable {
        public var imageQuality: String?
        public var confidenceIndex: String?
        public var detectorSignal: String?
        public var patternFit: String?
        public var extraProperties: [String]
        public var operatorName: String
        /// The pattern centre, working distance and writing software the header states; nil writes orix's zeros.
        public var acquisition: EBSDMapAcquisition?

        public init(imageQuality: String? = nil, confidenceIndex: String? = nil, detectorSignal: String? = nil, patternFit: String? = nil,
                    extraProperties: [String] = [], operatorName: String = "FormatoKit", acquisition: EBSDMapAcquisition? = nil) {
            self.imageQuality = imageQuality; self.confidenceIndex = confidenceIndex; self.detectorSignal = detectorSignal
            self.patternFit = patternFit; self.extraProperties = extraProperties; self.operatorName = operatorName
            self.acquisition = acquisition
        }
    }

    /// orix's `_get_prop_arrays` names, lowercased with underscores removed, in its order per column.
    static let searchNames: [[String]] = [["iq", "imagequality"], ["ci", "confidenceindex", "scores", "correlation"],
                                          ["ss", "semsignal", "detectorsignal"], ["fit", "patternfit"]]

    /// orix's `_EDAX_POINT_GROUP_ALIASES` (`orix.quaternion.symmetry`): the name EDAX writes for a proper point group.
    static let edaxAliases = ["121": "20", "2/m": "2", "222": "22", "422": "42", "321": "32", "622": "62", "432": "43", "m-3m": "m3m"]

    /// The file's text.
    public static func text(of grid: EBSDMapGrid, options: Options = Options()) throws -> String {
        let n = grid.count
        let phases = grid.phases.filter { $0.id != -1 }

        // The pattern centre (EDAX TSL convention) and working distance where the caller knows them; orix writes zeros.
        let pc = options.acquisition?.patternCentreTSL ?? .zero
        let wd = options.acquisition?.workingDistanceMM ?? 0
        var header = "TEM_PIXperUM           1.000000\n"
            + String(format: "x-star                 %.6f\ny-star                 %.6f\nz-star                 %.6f\n", pc.x, pc.y, pc.z)
            + String(format: "WorkingDistance        %.6f\n\n", wd)
        for (i, phase) in phases.enumerated().reversed() {
            let lattice = (phase.lattice ?? EBSDMapGrid.defaultLattice).map { String(format: "%.3f", $0) }.joined(separator: " ")
            let name = phase.name.isEmpty ? "phase\(i + 1)" : phase.name
            var symmetry = "1"
            if let proper = phase.properPointGroup { symmetry = edaxAliases[proper] ?? proper }
            header += "Phase \(i + 1)\nMaterialName    \(name)\nFormula    \(name)\nInfo\nSymmetry    \(symmetry)\n"
                + "LatticeConstants    \(lattice)\nNumberFamilies    0\n"
        }
        header += "GRID: SqrGrid\nXSTEP: \(String(format: "%.6f", grid.dx))\nYSTEP: \(String(format: "%.6f", grid.mapDY))\n"
            + "NCOLS_ODD: \(grid.columns)\nNCOLS_EVEN: \(grid.columns)\nNROWS: \(grid.rows)\n\nOPERATOR: \(options.operatorName)\n\n"
            + "SAMPLEID:\n\nSCANID:\n"
        if let software = options.acquisition?.software {
            // EDAX's notes block: the build that wrote the file, and what the caller knows that the header has no field for.
            var notes = ["Written by \(software)"]
            if let a = options.acquisition {
                if let kv = a.beamEnergyKeV { notes.append("Beam energy \(EBSDMapAcquisition.headerNumber(kv)) kV") }
                if let mag = a.magnification { notes.append("Magnification \(EBSDMapAcquisition.headerNumber(mag))") }
                if let tilt = a.sampleTiltDegrees { notes.append("Sample tilt \(EBSDMapAcquisition.headerNumber(tilt)) deg") }
            }
            header += "\nNOTES: Start\n" + notes.map { "NOTES: \($0.replacingOccurrences(of: "\n", with: " "))\n" }.joined() + "NOTES: End\n"
        }
        header += "\nColumn names: phi1, Phi, phi2, x, y, image_quality, confidence_index, phase_id, detector_signal, pattern_fit"
        for name in options.extraProperties { header += ", \(name)" }
        header += "\n"

        // Rotations: Bunge angles of the points in data, 0 elsewhere, rounded; 4π where not indexed or not in data.
        var euler = [[Double]](repeating: [], count: 3)
        for k in 0..<3 { euler[k] = grid.euler.map { round5($0[k]) } }
        let indexed = grid.indexed
        for i in 0..<n where !indexed[i] { for k in 0..<3 { euler[k][i] = 4 * .pi } }

        // Properties in float32, as orix's `prop_arrays`.
        let chosen = [options.imageQuality, options.confidenceIndex, options.detectorSignal, options.patternFit]
        var columns: [[Double]] = []
        for (k, given) in chosen.enumerated() {
            columns.append(try column(grid, given: given, search: searchNames[k]))
        }
        for name in options.extraProperties { columns.append(try column(grid, given: name, search: [])) }
        for i in 0..<n where !indexed[i] {
            columns[0][i] = 0; columns[1][i] = -1; columns[2][i] = 0; columns[3][i] = 180
            for k in 4..<columns.count { columns[k][i] = 0 }
        }

        // Phase ids: position + 1 in the list (header order reversed); not indexed 0 on a multi-phase map, −1 on one phase.
        let originalIDs = grid.phaseIDs
        var phaseColumn = [Int](repeating: phases.count > 1 ? 0 : -1, count: n)
        for (i, phase) in phases.enumerated().reversed() {
            for p in 0..<n where originalIDs[p] == Double(phase.id) { phaseColumn[p] = i + 1 }
        }

        // Every format is built once with its column width (orix's `fmt`), as numpy's `savetxt` applies it to each row.
        let lead = "%8.5f  %8.5f  %8.5f  %\(width(grid.x.max() ?? 0)).5f  %\(width(grid.y.max() ?? 0)).5f  "
        let widths = columns.map { width($0.max() ?? 0) }
        let middle = "%\(widths[0]).5f  %\(widths[1]).5f  %2ld  %\(widths[2]).5f  %\(widths[3]).5f"
        let extras = widths.dropFirst(4).map { "  %\($0).5f" }
        var out = ""
        out.reserveCapacity(header.utf8.count + n * (70 + 12 * options.extraProperties.count))
        for line in header.split(separator: "\n", omittingEmptySubsequences: false).dropLast() { out += "# \(line)\n" }
        out += "# \n"
        for i in 0..<n {
            out += String(format: lead, euler[0][i], euler[1][i], euler[2][i], grid.x[i], grid.y[i])
            out += String(format: middle, columns[0][i], columns[1][i], phaseColumn[i], columns[2][i], columns[3][i])
            for (k, format) in extras.enumerated() { out += String(format: format, columns[4 + k][i]) }
            out += "\n"
        }
        return out
    }

    /// Writes the file through `FormatoFileWrite` (a scratch file first, then over `url`).
    public static func write(_ grid: EBSDMapGrid, to url: URL, options: Options = Options()) throws {
        try FormatoFileWrite.write(Data(try text(of: grid, options: options).utf8), to: url)
    }

    // MARK: - Helpers

    /// numpy's `np.round(x, 5)`: x · 10⁵ rounded half to even, divided by 10⁵.
    static func round5(_ x: Double) -> Double { (x * 100_000.0).rounded(.toNearestOrEven) / 100_000.0 }

    /// orix's `_get_column_width`: the digits of the integer part of the column's largest value, a point, five decimals and
    /// a sign.
    /// A column whose largest value is not a finite number is as wide as "nan" (orix's `int(nan)` raises there instead).
    package static func width(_ largest: Double) -> Int {
        guard let whole = ReaderNumber.int(largest.rounded(.down)) else { return 3 + 7 }
        return String(whole).count + 7
    }

    /// One property column on the extent, rounded to five decimals and held in float32 (orix's `_get_prop_array`); zeros
    /// when the map has no such property.
    private static func column(_ grid: EBSDMapGrid, given: String?, search: [String]) throws -> [Double] {
        let name: String?
        if let given {
            guard grid.properties[given] != nil else { throw EBSDMapGrid.Refusal.noProperty(given) }
            name = given
        } else {
            name = grid.property(named: search)
        }
        guard let name, let values = grid.properties[name] else { return [Double](repeating: 0, count: grid.count) }
        return values.map { Double(Float(round5($0))) }
    }
}
