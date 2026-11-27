//
//  EBSDMapGrid.swift
//  Role: what the `.ang` and `.ctf` writers write, as plain arrays: an orientation map laid out on its data extent, one value a grid
//        cell in row-major order. A writer holds no crystallography: the consumer that holds the map (DiffractoKit's `CrystalMap`)
//        fills this from it, as Electron Microscopy Studio's `CrystalMapExtent` did before FormatoKit#147:
//        - `rows`, `columns`: the map's shape on its data extent (`CrystalMap.shape`; a 1D map is one row);
//        - `dx`, `dy`: the extent's steps (`CrystalMap.dx`; `dy` is the map's `dy`, 1 on a 1D map), from which `x` and `y` restart at 0
//          (orix's `create_coordinate_arrays`); `mapDY` is the map's own `dy`, the `.ang` header's YSTEP;
//        - `indexed`: `mapData(isIndexed)`, false where no point is in data;
//        - `euler`: the Bunge angles of the points in data (`qu2eu` of the rotations, as orix's `to_euler`), `mapData` with 0;
//        - `phaseIDs`: `mapData(phaseIDs)` with NaN where no point is;
//        - `properties`: each property's `mapData` with 0;
//        - `phases`: the map's phases without `not_indexed`, in id order, each with its proper point group (orix's
//          `point_group.proper_subgroup.name`, EDAX's alias is the writer's) and its Laue group (orix's `laue.name`).
//

import Foundation

public nonisolated struct EBSDMapGrid: Sendable, Equatable {
    /// One phase of the map, as the writers need it.
    public struct Phase: Sendable, Equatable {
        public var id: Int
        public var name: String
        public var spaceGroup: Int?
        /// a, b, c, alpha, beta, gamma; nil writes orix's lattice of a phase without a structure (1, 1, 1, 90°, 90°, 90°).
        public var lattice: [Double]?
        /// The proper point group's name (`432` for `m-3m`); nil for a phase without a point group (the `.ang` writes symmetry 1).
        public var properPointGroup: String?
        /// The Laue group's name (`m-3m`, `6/mmm`, ...); nil for a phase without a point group (the `.ctf` writes Laue group 1).
        public var laueGroup: String?

        public init(id: Int, name: String, spaceGroup: Int? = nil, lattice: [Double]? = nil, properPointGroup: String? = nil,
                    laueGroup: String? = nil) {
            self.id = id; self.name = name; self.spaceGroup = spaceGroup; self.lattice = lattice
            self.properPointGroup = properPointGroup; self.laueGroup = laueGroup
        }
    }

    /// A grid the writers cannot write.
    public enum Refusal: Error, Equatable, Sendable, LocalizedError {
        /// A map with no axis to write (one point, or no points).
        case noGrid
        /// A property asked for by name that the map does not hold.
        case noProperty(String)
        /// A per-cell array whose length is not `rows * columns`.
        case length(String)

        public var errorDescription: String? {
            switch self {
            case .noGrid: "The map has no rows or columns to write."
            case .noProperty(let name): "The map has no property named \(name)."
            case .length(let what): "The map's \(what) is not one value a grid cell."
            }
        }
    }

    /// orix's lattice when a phase has no structure: 1, 1, 1, 90°, 90°, 90°.
    static let defaultLattice: [Double] = [1, 1, 1, 90, 90, 90]

    public let rows: Int
    public let columns: Int
    public let dx: Double
    public let dy: Double
    public let mapDY: Double
    public let indexed: [Bool]
    public let euler: [SIMD3<Double>]
    public let phaseIDs: [Double]
    public let properties: [String: [Double]]
    public let phases: [Phase]
    /// x and y of every cell, restarted at 0 on the extent with the steps (orix's `create_coordinate_arrays`).
    public let x: [Double]
    public let y: [Double]

    public var count: Int { rows * columns }
    public var propertyNames: [String] { properties.keys.sorted() }

    /// Refused when the extent has no row or column, or a per-cell array is not `rows * columns` long.
    public init(rows: Int, columns: Int, dx: Double, dy: Double, mapDY: Double, indexed: [Bool], euler: [SIMD3<Double>], phaseIDs: [Double],
                properties: [String: [Double]] = [:], phases: [Phase]) throws {
        guard rows > 0, columns > 0, let n = ReaderNumber.product([rows, columns]) else { throw Refusal.noGrid }
        guard indexed.count == n else { throw Refusal.length("indexed mask") }
        guard euler.count == n else { throw Refusal.length("Euler angles") }
        guard phaseIDs.count == n else { throw Refusal.length("phase ids") }
        for (name, values) in properties where values.count != n { throw Refusal.length("property \(name)") }
        self.rows = rows; self.columns = columns; self.dx = dx; self.dy = dy; self.mapDY = mapDY
        self.indexed = indexed; self.euler = euler; self.phaseIDs = phaseIDs; self.properties = properties; self.phases = phases
        let grid = EBSDMapColumns.coordinates(shape: (rows, columns), steps: (dy, dx))
        x = grid.x
        y = grid.y
    }

    /// The first property whose name, lowercased with underscores removed, is one of `candidates` (tried in their order).
    func property(named candidates: [String]) -> String? {
        let names = propertyNames
        for candidate in candidates {
            if let hit = names.first(where: { $0.lowercased().replacingOccurrences(of: "_", with: "") == candidate }) { return hit }
        }
        return nil
    }
}
