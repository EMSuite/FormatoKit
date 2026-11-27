//
//  EBSDMapColumns.swift
//  Role: an orientation map as the readers hand it over, plain columns and no crystallography type (ADR 0005): Bunge Euler angles
//        in radians as orix's readers hold them (lab to crystal; no quaternion is made here), the phase id of every point, x and y,
//        every other column by its name, the points `is_in_data` keeps, the scan unit, and the file's phase headers (name, formula,
//        space group, point group as orix names it, lattice and its unit, colour). DiffractoKit's
//        `CrystalMap.init(euler:quaternions:phaseIDs:x:y:properties:phaseHeaders:scanUnit:isInData:)` takes these columns as they
//        are (`phaseHeaderTuples`), and matches the headers to the ids as orix matches them.
//        Beside them: orix's `create_coordinate_arrays` (`coordinates`), and its `_step_size_from_coordinates` and
//        `_data_slices_from_coordinates` for the few checks a reader makes on the grid itself (an ASTAR `.ctf`'s regenerated
//        coordinates, a vendor map whose positions must give one point a cell), ported from DiffractoKit's `CrystalMap` (orix 0.15.0,
//        orix.crystal_map.crystal_map; GPL-3.0-or-later, see NOTICE) with the same arithmetic.
//

import Foundation

/// One phase of a map's header, as the file states it.
public nonisolated struct EBSDPhaseHeader: Sendable, Equatable {
    public var id: Int
    public var name: String
    /// The formula where the file writes one beside the name (`.ang`).
    public var formula: String?
    public var spaceGroup: Int?
    /// The point group as orix names it (`m-3m`, `6/mmm`, `432`, ...); nil where the file gives none.
    public var pointGroup: String?
    /// a, b, c (in `latticeUnit`), alpha, beta, gamma (degrees), as the file gives them.
    public var lattice: [Double]?
    /// `angstrom` or `nanometre` where the file states its unit (.ang, .ctf, Bruker and EDAX h5ebsd: Å); nil where it states none.
    public var latticeUnit: String?
    /// The matplotlib colour the file writes (orix's own HDF5 file, kikuchipy's); nil for orix's default, the next free Tableau
    /// colour in id order.
    public var color: String?

    public init(id: Int, name: String, formula: String? = nil, spaceGroup: Int? = nil, pointGroup: String? = nil, lattice: [Double]? = nil,
                latticeUnit: String? = nil, color: String? = nil) {
        self.id = id; self.name = name; self.formula = formula; self.spaceGroup = spaceGroup; self.pointGroup = pointGroup
        self.lattice = lattice; self.latticeUnit = latticeUnit; self.color = color
    }

    /// The `latticeUnit` of a file that gives its lattice in Å.
    public static let angstrom = "angstrom"
}

/// An orientation map's columns, one value per point.
public nonisolated struct EBSDMapColumns: Sendable, Equatable {
    /// Bunge Euler angles (phi1, Phi, phi2) in radians, as orix's reader holds them.
    public var euler: [SIMD3<Double>]
    /// The phase id of each point (−1 not indexed, as orix numbers it); nil for one phase, id 0.
    public var phaseIDs: [Int]?
    /// x and y of each point in `scanUnit`; nil where the file gives no such axis (both nil: orix's x = 0, 1, 2, ...).
    public var x: [Double]?
    public var y: [Double]?
    /// Every other per-point column, by orix's name for it.
    public var properties: [String: [Double]]
    /// The file's phases, by id; empty where the file lists none (orix's unnamed phases of the ids in the data).
    public var phaseHeaders: [EBSDPhaseHeader]
    /// The length unit of x, y and the steps: `um`, `nm` (an ASTAR `.ang`) or the file's own (orix's HDF5 `scan_unit`, else `px`).
    public var scanUnit: String
    /// orix's `is_in_data`: the points the map shows (a map cut from a larger one keeps the others hidden); nil keeps them all.
    public var isInData: [Bool]?

    public init(euler: [SIMD3<Double>], phaseIDs: [Int]? = nil, x: [Double]? = nil, y: [Double]? = nil, properties: [String: [Double]] = [:],
                phaseHeaders: [EBSDPhaseHeader] = [], scanUnit: String = "px", isInData: [Bool]? = nil) {
        self.euler = euler; self.phaseIDs = phaseIDs; self.x = x; self.y = y; self.properties = properties
        self.phaseHeaders = phaseHeaders; self.scanUnit = scanUnit; self.isInData = isInData
    }

    /// Every point of the map, in data or not.
    public var pointCount: Int { euler.count }

    /// The property names, sorted.
    public var propertyNames: [String] { properties.keys.sorted() }

    /// The points not indexed (phase id −1).
    public var notIndexedCount: Int { (phaseIDs ?? []).reduce(0) { $0 + ($1 == -1 ? 1 : 0) } }

    /// The phase headers in the form DiffractoKit's `CrystalMap(euler:quaternions:phaseIDs:x:y:properties:phaseHeaders:scanUnit:isInData:)`
    /// takes them.
    public var phaseHeaderTuples: [(id: Int, name: String, formula: String?, spaceGroup: Int?, pointGroup: String?, lattice: [Double]?,
                                    latticeUnit: String?, color: String?)] {
        phaseHeaders.map { (id: $0.id, name: $0.name, formula: $0.formula, spaceGroup: $0.spaceGroup, pointGroup: $0.pointGroup,
                            lattice: $0.lattice, latticeUnit: $0.latticeUnit, color: $0.color) }
    }

    // MARK: The grid (orix)

    /// orix's `create_coordinate_arrays`: x and y of a row-major map of `shape` (rows, columns) with `steps` (dy, dx).
    public static func coordinates(shape: (rows: Int, columns: Int), steps: (dy: Double, dx: Double) = (1, 1)) -> (x: [Double], y: [Double]) {
        var x: [Double] = [], y: [Double] = []
        x.reserveCapacity(shape.rows * shape.columns); y.reserveCapacity(shape.rows * shape.columns)
        for r in 0..<shape.rows {
            for c in 0..<shape.columns {
                x.append(Double(c) * steps.dx)
                y.append(Double(r) * steps.dy)
            }
        }
        return (x, y)
    }

    /// orix `_step_size_from_coordinates`: `unique[1] - unique[0]` of the sorted unique values, 0 for fewer than two (a NaN passed
    /// over, −0 and 0 one value).
    static func stepSize(_ coordinates: [Double]) -> Double {
        var lowest = 0.0, second = 0.0, distinct = 0
        for v in coordinates where !v.isNaN {
            switch distinct {
            case 0:
                lowest = v; distinct = 1
            case 1:
                if v < lowest { second = lowest; lowest = v; distinct = 2 } else if v > lowest { second = v; distinct = 2 }
            default:
                if v < lowest { second = lowest; lowest = v } else if v > lowest, v < second { second = v }
            }
        }
        return distinct == 2 ? second - lowest : 0
    }

    /// orix `_data_slices_from_coordinates` on named coordinate arrays with their own steps (an empty array or a zero step is
    /// skipped), refused where its arithmetic cannot run: a value that is not finite, or a slice bound past 2^53 steps. The refusal
    /// is the clause that says why.
    static func checkedSlices(_ axes: [(name: String, values: [Double])]) throws -> [(start: Int, stop: Int)] {
        for axis in axes where !axis.values.allSatisfy(\.isFinite) {
            throw GridRefusal(why: "\(axis.name) holds a value that is not a finite number")
        }
        var out: [(start: Int, stop: Int)] = []
        for axis in axes {
            let step = stepSize(axis.values)
            guard let lo = axis.values.min(), let hi = axis.values.max(), step != 0 else { continue }
            guard abs((lo / step).rounded(.toNearestOrEven)) < 0x1p53, abs((hi / step + 1).rounded(.toNearestOrEven)) < 0x1p53 else {
                throw GridRefusal(why: "\(axis.name) spans more than 2^53 times its smallest step")
            }
            out.append((Int((lo / step).rounded(.toNearestOrEven)), Int((hi / step + 1).rounded(.toNearestOrEven))))
        }
        return out
    }

    /// Why coordinates make no grid, as a clause.
    struct GridRefusal: Error { let why: String }

    /// The most grid cells a map may span, as DiffractoKit's `CrystalMap.maximumCells` holds it.
    public static let maximumCells = 1 << 28

    /// The columns as building the map from them takes them (DiffractoKit's `CrystalMap`), refused where it would refuse them, so a
    /// reader refuses the file it reads (the app's readers built the map and refused there): a column with another number of
    /// values than the Euler angles, or x and y that make no grid of at most `maximumCells` cells. `name`, the file's, leads the
    /// sentence where given.
    func checked(file name: String? = nil) throws -> EBSDMapColumns {
        let n = pointCount
        let prefix = name.map { "\($0): " } ?? ""
        func mismatch(_ what: String) -> EBSDReadError {
            EBSDReadError(.unreadable, prefix + "its \(what) have another length than its \(n) orientations.")
        }
        if let phaseIDs, phaseIDs.count != n { throw mismatch("phase ids") }
        if let x, x.count != n { throw mismatch("x coordinates") }
        if let y, y.count != n { throw mismatch("y coordinates") }
        if let isInData, isInData.count != n { throw mismatch("in-data mask values") }
        for (key, values) in properties.sorted(by: { $0.key < $1.key }) where values.count != n { throw mismatch("values of \(key)") }
        let cells: Int?
        do { cells = try spannedCells() } catch let refusal as GridRefusal {
            throw EBSDReadError(.unreadable, prefix + "the crystal map's coordinates make no grid: \(refusal.why).")
        }
        guard let cells, cells <= Self.maximumCells else {
            throw EBSDReadError(.tooLarge, prefix + "the crystal map's coordinates span more than \(Self.maximumCells) grid cells.")
        }
        return self
    }

    /// The grid cells the map's x and y span (orix's `_original_shape`, multiplied out), as `CrystalMap` derives it; nil where the
    /// count overflows.
    func spannedCells() throws -> Int? {
        let n = pointCount
        let xs = (x == nil && y == nil) ? (0..<n).map(Double.init) : (x ?? [])
        let extents = try Self.checkedSlices([("y", y ?? []), ("x", xs)]).map { $0.stop - $0.start }
        return ReaderNumber.product(extents)
    }
}
