//
//  EBSDH5Reader+VendorMaps.swift
//  Moved from Electron Microscopy Studio's Sources/TEMSEM (at 7b09bf5) by FormatoKit#147.
//  Role: the orientation maps of the h5ebsd files that hold no patterns, as plain columns (`EBSDMapColumns`), and of Bruker and EDAX
//        files beside their patterns (kikuchipy 0.13.1 leaves those empty):
//        - Bruker Esprit: orix 0.15.0's io/plugins/bruker_h5ebsd.py (GPL-3.0-or-later). Euler angles in degrees (`np.deg2rad` of the
//          float32 columns, in float32), Phase 0 not indexed (-1), the phases of `Header/Phases` by id (Name, IT, LatticeConstants),
//          the points put in map order by the SEM IY and IX of a region (`final_preparations`), x and y from X SAMPLE and Y SAMPLE less
//          their least (x reversed, as orix reverses it; y not reordered, as orix leaves it), the thirteen columns orix keeps under its
//          names, µm. Departures (docs/parity.md): an IY and IX that do not give every point (kikuchipy's own files write one of each)
//          are passed over for NROWS and NCOLS where orix takes them for a 1 × 1 map; the phases take distinct Tableau colours where
//          orix leaves every Bruker phase blue (the headers name no colour, so each takes the next free one); atoms are not read
//          (orix fails on Esprit's Debye-Waller field). The point group of a phase is the one of its space group (orix's `Phase`
//          derives it so; `pointGroupName(ofSpaceGroup:)`).
//        - EDAX OIM Analysis: no Python reader (orix has no plugin; MTEX and DREAM3D's EbsdLib read it), so the map reads as orix 0.15.0
//          reads the `.ang` OIM writes for the same scan (`ANGReader`): Phi1, Phi, Phi2 in radians as stored, X and Y Position, the
//          columns iq, ci, detector_signal and fit, ci -1 not indexed, the phases of `Header/Phase` with orix's names from the formulas
//          and its EDAX point-group aliases, Å, µm. A hexagonal grid is refused as the `.ang`'s is.
//        - EMsoft dictionary indexing (EMEBSDDI): orix 0.15.0's io/plugins/emsoft_h5ebsd.py, unrefined (its default): each point's best
//          match from `TopMatchIndices` into `DictionaryEulerAngles` (degrees, `np.deg2rad` in float32), the one phase of `Phase/1`
//          (name and point group by orix's regular expressions), x from X Position, y from the header's rows and Step Y (EMsoft
//          writes Y Position wrong), the properties orix keeps (the first column of those with one per match), µm.
//        A map whose positions do not give one point a grid cell is refused, as orix's reshape to the map refuses it.
//        Every refusal names the file in words. Tests: EBSDH5VendorMapTests on Fixtures/ebsd-{bruker,edax,emsoft}-map.h5 against
//        ebsd-h5ebsd-map.truth.json (tools/ebsd-readers/make_h5ebsd_map_fixtures.py).
//

import Foundation
import FormatoCore
import FormatoHDF5

nonisolated extension EBSDH5Reader {
    /// The map of the first scan of the Bruker, EDAX or EMsoft file at `url`, in `layout`. Reads the whole map; run it off the main
    /// actor, inside the file's security scope.
    public static func readVendorMap(url: URL, layout: MapLayout) throws -> EBSDMapColumns {
        do {
            let reader = try HDF5Reader(url: url)
            let top = try TopGroup(reader)
            guard let scan = top.scanGroups.first else { throw EBSDReadError(.noScan(named: nil, scans: []), "\(url.lastPathComponent) holds no EBSD map.") }
            let file = H5File(reader: reader, url: url)
            switch layout {
            case .bruker: return try readBrukerMap(file, scan: scan)
            case .edax: return try readEDAXMap(file, scan: scan)
            case .emsoft: return try readEMsoftMap(file, scan: scan)
            case .oxford: return try readOxfordMap(file, scan: scan)
            case .orix: return try readOrixMap(url: url)
            }
        } catch { throw EBSDReadError.wrap(error, file: url) }
    }

    // MARK: - Shared pieces

    /// `np.deg2rad` of a column: in float32 where the file stores float32 (numpy keeps the type: `x * float32(pi / 180)`), else in
    /// float64.
    static func radians(_ degrees: [Double], float32: Bool) -> [Double] {
        guard float32 else { return degrees.map { $0 * Double.pi / 180 } }
        let factor = Float(Double.pi / 180)
        return degrees.map { Double(Float($0) * factor) }
    }

    /// Whether `key` in `group` is stored as float32.
    static func isFloat32(_ group: H5Group, _ key: String) throws -> Bool {
        guard let info = try group.info(key), case .numeric(let type) = info.type else { return false }
        return type == .float32
    }

    /// `values` less their least, as numpy subtracts: in float32 for a float32 column.
    static func lessLeast(_ values: [Double], float32: Bool) -> [Double] {
        guard let least = values.min() else { return values }
        guard float32 else { return values.map { $0 - least } }
        return values.map { Double(Float($0) - Float(least)) }
    }

    /// `map` when its points' positions span exactly one grid cell a point, as orix's reshape to the map needs (the cells as
    /// `CrystalMap` derives them from x and y); refused in words otherwise (points that share a position, or a grid with holes).
    static func laidOut(_ map: EBSDMapColumns, file name: String) throws -> EBSDMapColumns {
        let spanned: Int?
        do { spanned = try map.spannedCells() } catch let refusal as EBSDMapColumns.GridRefusal {
            throw EBSDReadError(.unreadable, "\(name): The crystal map's coordinates make no grid: \(refusal.why).")
        }
        guard let cells = spanned, cells == map.pointCount else {
            let count = spanned.map(String.init) ?? "more"
            throw EBSDReadError(.unreadable, "\(name): the positions of its \(map.pointCount) points do not lay them out on a map "
                                + "(they span \(count) grid \(spanned == 1 ? "cell" : "cells")).")
        }
        return map
    }

    /// A number stored as a number or as text (EMsoft writes lattice constants as strings, orix and diffpy take either).
    static func number(_ group: H5Group, _ key: String) throws -> Double? {
        if let value = try group.double(key) { return value }
        return try group.string(key).flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))) }
    }

    // MARK: - Bruker Esprit

    /// The data columns orix keeps as properties, by orix's names.
    static let brukerProperties: [(file: String, name: String)] = [
        ("PCX", "PCX"), ("PCY", "PCY"), ("DD", "DD"), ("MAD", "MAD"), ("MADPhase", "MADPhase"), ("NIndexedBands", "NIndexedBands"),
        ("RadonBandCount", "RadonBandCount"), ("RadonQuality", "RadonQuality"), ("X BEAM", "XBEAM"), ("Y BEAM", "YBEAM"),
        ("X SAMPLE", "XSAMPLE"), ("Y SAMPLE", "YSAMPLE"), ("Z SAMPLE", "ZSAMPLE"),
    ]

    static func readBrukerMap(_ file: H5File, scan: String) throws -> EBSDMapColumns {
        let name = file.url.lastPathComponent
        let header = try H5Group(file, "/\(scan)/EBSD/Header")
        let data = try H5Group(file, "/\(scan)/EBSD/Data")
        let grid = try header.string("Grid Type")
        guard grid == "isometric" else { throw gridRefusal(grid, file: name) }
        guard let phi1 = try data.doubles("phi1"), let Phi = try data.doubles("PHI"), let phi2 = try data.doubles("phi2") else {
            throw EBSDReadError(.missing("phi1"), "\(name) holds neither EBSD patterns nor orientations: its EBSD data has no Euler angles.")
        }
        let n = phi1.count
        guard Phi.count == n, phi2.count == n, n > 0 else {
            throw EBSDReadError(.unreadable, "\(name) does not give three Euler angles for each of its points.")
        }
        guard let phaseColumn = try data.doubles("Phase"), phaseColumn.count == n else {
            throw EBSDReadError(.missing("Phase"), "\(name) has orientations but does not give the phase of each point.")
        }
        guard let xSample = try data.doubles("X SAMPLE"), let ySample = try data.doubles("Y SAMPLE"), xSample.count == n, ySample.count == n else {
            throw EBSDReadError(.missing("X SAMPLE"), "\(name) does not give where each point lies (its X SAMPLE and Y SAMPLE).")
        }

        // The map order: the SEM group's IY and IX where they give every point (orix looks in the scan, then in its EBSD group, the
        // later winning), else the stored order on NROWS x NCOLS.
        var order: [Int]?
        var semPlace: String?
        for place in ["/\(scan)", "/\(scan)/EBSD"] where (try? file.reader.kind(of: place + "/SEM")) == .group { semPlace = place + "/SEM" }
        if let semPlace {
            let sem = try H5Group(file, semPlace)
            let iy = try sem.doubles("IY") ?? sem.doubles("SEM IY")
            let ix = try sem.doubles("IX") ?? sem.doubles("SEM IX")
            if let iy, let ix, iy.count == n, ix.count == n {
                let rows = try iy.map { try wholeNumber($0, "\(name): a row of its region of interest") }
                let columns = try ix.map { try wholeNumber($0, "\(name): a column of its region of interest") }
                guard let roi = rectangularROI(rows: rows, columns: columns) else {
                    throw EBSDReadError(.regionNotRectangular, "\(name): its region of interest is not a rectangle; only rectangular regions are read.")
                }
                order = roi.fileIndexByPosition.compactMap { $0 }
            }
        }
        if order == nil {
            guard let rows = try header.int("NROWS"), let columns = try header.int("NCOLS"), let cells = ReaderNumber.product([rows, columns]),
                  cells == n else {
                throw EBSDReadError(.size, "\(name) has \(n) points, but its header does not give a map of that many (NROWS × NCOLS).")
            }
        }
        func ordered(_ values: [Double]) -> [Double] { order.map { $0.map { values[$0] } } ?? values }

        let degrees32 = try isFloat32(data, "phi1")
        let r1 = ordered(radians(phi1, float32: degrees32)), r2 = ordered(radians(Phi, float32: degrees32)), r3 = ordered(radians(phi2, float32: degrees32))
        let euler = (0..<n).map { SIMD3(r1[$0], r2[$0], r3[$0]) }
        let phaseIDs = try ordered(phaseColumn).enumerated().map { i, value -> Int in
            let id = try wholeNumber(value, "\(name): the phase of point \(i + 1)")
            return id == 0 ? -1 : id
        }
        let x32 = try isFloat32(data, "X SAMPLE"), y32 = try isFloat32(data, "Y SAMPLE")
        let x = Array(ordered(lessLeast(xSample, float32: x32)).reversed())
        let y = lessLeast(ySample, float32: y32)
        var properties: [String: [Double]] = [:]
        for (key, label) in brukerProperties {
            if let values = try data.doubles(key), values.count == n { properties[label] = ordered(values) }
        }
        return try laidOut(EBSDMapColumns(euler: euler, phaseIDs: phaseIDs, x: x, y: y, properties: properties,
                                          phaseHeaders: try brukerPhases(header, file: name), scanUnit: "um"), file: name)
    }

    /// `Header/Phases`: one group a phase, named by its id; its Name, IT (the space group, which gives the point group) and
    /// LatticeConstants (Å and degrees). In id order, with no colour (Tableau colours in id order).
    static func brukerPhases(_ header: H5Group, file name: String) throws -> [EBSDPhaseHeader] {
        guard let list = try header.subgroup("Phases") else { throw EBSDReadError(.missing("Phases"), "\(name) does not list its crystal phases.") }
        var entries: [EBSDPhaseHeader] = []
        for groupName in list.names {
            guard let id = Int(groupName.trimmingCharacters(in: .whitespaces)), let group = try list.subgroup(groupName) else { continue }
            let phaseName = (try group.string("Name") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
            guard let it = try group.double("IT"), let number = ReaderNumber.int(it), let pointGroup = pointGroupName(ofSpaceGroup: number) else {
                throw EBSDReadError(.missing("IT"), "\(name): phase \(id) (\(phaseName.isEmpty ? "unnamed" : phaseName)) gives no space group from 1 to 230, "
                                    + "so its symmetry is unknown.")
            }
            let lattice = try group.doubles("LatticeConstants").flatMap { $0.count >= 6 ? Array($0.prefix(6)) : nil }
            entries.append(EBSDPhaseHeader(id: id, name: phaseName, spaceGroup: number, pointGroup: pointGroup, lattice: lattice,
                                           latticeUnit: EBSDPhaseHeader.angstrom))
        }
        entries.sort { $0.id < $1.id }
        return entries
    }

    /// The point group of each of the 230 space groups, as orix 0.15.0's `get_point_group(number, proper=False)` names it; nil outside
    /// 1 to 230. Electron Microscopy Studio's `SpaceGroupPointGroup` table, which its parity bundle checks against orix.
    package static func pointGroupName(ofSpaceGroup number: Int) -> String? {
        let table: [(last: Int, name: String)] = [
            (1, "1"), (2, "-1"), (5, "2"), (9, "m"), (15, "2/m"), (24, "222"), (46, "mm2"), (74, "mmm"), (80, "4"), (82, "-4"), (88, "4/m"),
            (98, "422"), (110, "4mm"), (122, "-42m"), (142, "4/mmm"), (146, "3"), (148, "-3"), (155, "32"), (161, "3m"), (167, "-3m"),
            (173, "6"), (174, "-6"), (176, "6/m"), (182, "622"), (186, "6mm"), (190, "-6m2"), (194, "6/mmm"), (199, "23"), (206, "m-3"),
            (214, "432"), (220, "-43m"), (230, "m-3m"),
        ]
        guard (1 ... 230).contains(number), let row = table.first(where: { number <= $0.last }) else { return nil }
        return row.name
    }

    // MARK: - EDAX OIM Analysis

    static func readEDAXMap(_ file: H5File, scan: String) throws -> EBSDMapColumns {
        let name = file.url.lastPathComponent
        let header = try H5Group(file, "/\(scan)/EBSD/Header")
        let data = try H5Group(file, "/\(scan)/EBSD/Data")
        let grid = try header.string("Grid Type")
        if let grid, grid.lowercased().hasPrefix("hex") {
            throw EBSDReadError(.grid(grid), "\(name) is a hexagonal grid (\(grid)); only square-grid EBSD maps are read.")
        }
        guard let phi1 = try data.doubles("Phi1"), let Phi = try data.doubles("Phi"), let phi2 = try data.doubles("Phi2") else {
            throw EBSDReadError(.missing("Phi1"), "\(name) holds neither EBSD patterns nor orientations: its EBSD data has no Euler angles.")
        }
        let n = phi1.count
        guard Phi.count == n, phi2.count == n, n > 0 else {
            throw EBSDReadError(.unreadable, "\(name) does not give three Euler angles for each of its points.")
        }
        guard let phaseColumn = try data.doubles("Phase"), phaseColumn.count == n else {
            throw EBSDReadError(.missing("Phase"), "\(name) has orientations but does not give the phase of each point.")
        }
        guard let x = try data.doubles("X Position"), let y = try data.doubles("Y Position"), x.count == n, y.count == n else {
            throw EBSDReadError(.missing("X Position"), "\(name) does not give where each point lies (its X and Y Position).")
        }
        let euler = (0..<n).map { SIMD3(phi1[$0], Phi[$0], phi2[$0]) }
        var phaseIDs = try phaseColumn.enumerated().map { i, value in try wholeNumber(value, "\(name): the phase of point \(i + 1)") }
        var properties: [String: [Double]] = [:]
        for (key, label) in [("IQ", "iq"), ("CI", "ci"), ("SEM Signal", "detector_signal"), ("Fit", "fit")] {
            if let values = try data.doubles(key), values.count == n { properties[label] = values }
        }
        if let ci = properties["ci"] { for k in 0..<n where ci[k] == -1 { phaseIDs[k] = -1 } }
        return try laidOut(EBSDMapColumns(euler: euler, phaseIDs: phaseIDs, x: x, y: y, properties: properties,
                                          phaseHeaders: try edaxPhases(header, file: name), scanUnit: "um"), file: name)
    }

    /// `Header/Phase`: one group a phase, named by its id, read as the `.ang` header's phase lines are (`ANGReader`): MaterialName,
    /// Formula, Symmetry (orix's EDAX aliases), the six lattice constants; names from the formulas where every phase has one.
    static func edaxPhases(_ header: H5Group, file name: String) throws -> [EBSDPhaseHeader] {
        guard let list = try header.subgroup("Phase") else { throw EBSDReadError(.missing("Phase"), "\(name) does not list its crystal phases.") }
        let trim = CharacterSet(charactersIn: "\0").union(.whitespaces)
        var phases: [ANGPhase] = []
        for groupName in list.names {
            guard let id = Int(groupName.trimmingCharacters(in: .whitespaces)), let group = try list.subgroup(groupName) else { continue }
            let material = (try group.string("MaterialName") ?? "").trimmingCharacters(in: trim)
            let formula = try group.string("Formula")?.trimmingCharacters(in: trim)
            guard let symmetry = try group.double("Symmetry").flatMap({ ReaderNumber.int($0) }) else {
                throw EBSDReadError(.missing("Symmetry"), "\(name): phase \(id) (\(material.isEmpty ? "unnamed" : material)) gives no symmetry, so it cannot be shown.")
            }
            let pointGroup: String
            do { pointGroup = try ANGReader.pointGroupName(String(symmetry), file: name) } catch let error as ANGReadError {
                throw EBSDReadError(.unreadable, error.text)
            }
            var lattice: [Double] = []
            for key in ["a", "b", "c", "alpha", "beta", "gamma"] {
                guard let value = try number(group, "Lattice Constant \(key)") else { break }
                lattice.append(value)
            }
            phases.append(ANGPhase(id: id, name: material, formula: formula, pointGroup: pointGroup, lattice: lattice))
        }
        phases.sort { $0.id < $1.id }
        // The formulas in id order, as the sorted phases are, so `autogenerateNames` pairs each phase with its own.
        let formulas = phases.compactMap(\.formula)
        ANGReader.autogenerateNames(&phases, formulas: formulas, ids: phases.map(\.id))
        return phases.map {
            EBSDPhaseHeader(id: $0.id, name: $0.name, formula: $0.formula, pointGroup: $0.pointGroup, lattice: $0.lattice.count == 6 ? $0.lattice : nil,
                            latticeUnit: EBSDPhaseHeader.angstrom)
        }
    }

    // MARK: - EMsoft dictionary indexing

    /// The data columns orix keeps as properties of an EMsoft file.
    static let emsoftProperties = ["AvDotProductMap", "CI", "IQ", "ISM", "KAM", "OSM", "RefinedDotProducts", "TopDotProductList", "TopMatchIndices"]

    static func readEMsoftMap(_ file: H5File, scan: String) throws -> EBSDMapColumns {
        let name = file.url.lastPathComponent
        let header = try H5Group(file, "/\(scan)/EBSD/Header")
        let data = try H5Group(file, "/\(scan)/EBSD/Data")
        guard let rows = try header.int("nRows"), let columns = try header.int("nColumns"), rows >= 1, columns >= 1,
              let n = ReaderNumber.product([rows, columns]) else {
            throw EBSDReadError(.missing("nRows"), "\(name) does not give the map's size: its EBSD header needs nRows and nColumns of at least 1.")
        }
        let phase = try emsoftPhase(header, file: name)

        // The best match of each point: its 1-based index into the dictionary's orientations.
        guard let topInfo = try data.info("TopMatchIndices"), let top = try data.doubles("TopMatchIndices"),
              let dictionary = try data.doubles("DictionaryEulerAngles"), let dictionaryInfo = try data.info("DictionaryEulerAngles"),
              dictionaryInfo.shape.last == 3 else {
            throw EBSDReadError(.missing("TopMatchIndices"), "\(name) holds neither EBSD patterns nor orientations: it has no dictionary matches.")
        }
        let perPoint = topInfo.shape.count >= 2 ? max(1, topInfo.shape[topInfo.shape.count - 1]) : 1
        guard top.count / perPoint >= n else {
            throw EBSDReadError(.size, "\(name) has matches for \(top.count / perPoint) points, but its header gives a map of \(columns) × \(rows).")
        }
        let available = dictionary.count / 3
        let size = try data.double("FZcnt").flatMap { ReaderNumber.int($0) }.map { min($0, available) } ?? available
        let degrees32 = try isFloat32(data, "DictionaryEulerAngles")
        var euler = [SIMD3<Double>](repeating: .zero, count: n)
        for i in 0..<n {
            guard let index = ReaderNumber.int(top[i * perPoint]), index >= 1, index <= size else {
                throw EBSDReadError(.number, "\(name): the best match of point \(i + 1) is not one of the dictionary's \(size) orientations.")
            }
            let k = 3 * (index - 1)
            let angles = radians([dictionary[k], dictionary[k + 1], dictionary[k + 2]], float32: degrees32)
            euler[i] = SIMD3(angles[0], angles[1], angles[2])
        }
        let phaseIDs = try data.doubles("Phase").flatMap { $0.count >= n ? $0 : nil }.map { column in
            try column.prefix(n).enumerated().map { i, value in try wholeNumber(value, "\(name): the phase of point \(i + 1)") }
        } ?? [Int](repeating: 0, count: n)

        guard let xs = try data.doubles("X Position"), xs.count == n else {
            throw EBSDReadError(.missing("X Position"), "\(name) does not give where each point lies (its X Position).")
        }
        // EMsoft writes Y Position wrong; orix builds y from the rows and Step Y (`np.arange(ny) * step_y`, in float64).
        let stepY = try header.double("Step Y") ?? 0
        let y = (0..<n).map { Double($0 / columns) * stepY }

        // orix's `nnk`, the matches kept a point; where the file has none, the columns of TopMatchIndices.
        var matches = perPoint
        if try file.reader.exists("/NMLparameters/EBSDIndexingNameListType/nnk"),
           let nnk = try H5Group(file, "/NMLparameters/EBSDIndexingNameListType").int("nnk") { matches = nnk }
        var properties: [String: [Double]] = [:]
        for key in emsoftProperties {
            guard let values = try data.doubles(key), let shape = try data.info(key)?.shape else { continue }
            if shape.last == matches, values.count > n, matches > 0, values.count / matches >= n {
                properties[key] = (0..<n).map { values[$0 * matches] }
            } else if values.count == n {
                properties[key] = values
            }
        }
        return try laidOut(EBSDMapColumns(euler: euler, phaseIDs: phaseIDs, x: xs, y: y, properties: properties, phaseHeaders: [phase],
                                          scanUnit: "um"), file: name)
    }

    /// `Phase/1`, EMsoft's one phase: the name, the first run of `[A-z0-9]` in MaterialName, and the point group, the `[A-z0-9/-]`
    /// inside the brackets of Point Group (orix's `dict2phase`), with orix's aliases; the six lattice constants (the file states no
    /// unit, so a consumer guesses it).
    static func emsoftPhase(_ header: H5Group, file name: String) throws -> EBSDPhaseHeader {
        guard let group = try header.subgroup("Phase")?.subgroup("1") else {
            throw EBSDReadError(.missing("Phase"), "\(name) does not give its crystal phase.")
        }
        let material = try group.string("MaterialName") ?? ""
        let symbol = try group.string("Point Group") ?? ""
        guard let phaseName = firstRun(in: material, allowed: { ($0 >= 65 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }) else {
            throw EBSDReadError(.missing("MaterialName"), "\(name) does not name its crystal phase.")
        }
        guard let bracketed = bracketedPointGroup(symbol) else {
            throw EBSDReadError(.missing("Point Group"), "\(name): its phase \(phaseName) gives no point group, so its symmetry is unknown.")
        }
        let pointGroup: String
        do { pointGroup = try ANGReader.pointGroupName(bracketed, file: name) } catch let error as ANGReadError {
            throw EBSDReadError(.unreadable, error.text)
        }
        var lattice: [Double] = []
        for key in ["a", "b", "c", "alpha", "beta", "gamma"] {
            guard let value = try number(group, "Lattice Constant \(key)") else { break }
            lattice.append(value)
        }
        return EBSDPhaseHeader(id: 0, name: phaseName, pointGroup: pointGroup, lattice: lattice.count == 6 ? lattice : nil)
    }

    /// The first run of characters `allowed` takes (`re.search(r"([A-z0-9]+)")`); nil when there is none.
    package static func firstRun(in text: String, allowed: (UInt32) -> Bool) -> String? {
        var run = ""
        for scalar in text.unicodeScalars {
            if allowed(scalar.value) { run.unicodeScalars.append(scalar) } else if !run.isEmpty { return run }
        }
        return run.isEmpty ? nil : run
    }

    /// `re.search(r"\[([A-z0-9/-]+)]")`: the first `[` followed by one or more of the class and a `]`, the run as long as it can be
    /// (the class holds `[` and `]` themselves, A to z being ASCII 65 to 122, so the match backs off to the last `]` it can end on).
    package static func bracketedPointGroup(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        func allowed(_ v: UInt32) -> Bool { (v >= 65 && v <= 122) || (v >= 48 && v <= 57) || v == 47 || v == 45 }
        for start in scalars.indices where scalars[start] == "[" {
            var end = start + 1
            while end < scalars.count, allowed(scalars[end].value) { end += 1 }
            // The closing `]` is the last one inside the run that leaves at least one character before it.
            guard let close = (start + 2 ..< max(start + 2, end)).last(where: { scalars[$0] == "]" }) else { continue }
            var inside = ""
            inside.unicodeScalars.append(contentsOf: scalars[(start + 1)..<close])
            return inside
        }
        return nil
    }
}
