# tools/parity/sem-readers/make_h5ebsd_map_fixtures.py — writes the Bruker, EDAX and EMsoft HDF5 map fixtures of EMStudioTests and what
# the references read from them (#514).
#
#   python -I -B make_h5ebsd_map_fixtures.py <out dir>        (orix 0.15.0, h5py 3.16.0, NumPy 2.5.4, as pinned in tools/parity/sem)
#
# Three EBSD map files without patterns, planted in the layouts their writers use, each a 4 x 3 map (4 columns, 3 rows) with two phases
# and points not indexed, so a swapped axis, a lost phase or a misplaced point shows:
#   ebsd-bruker-map.h5   Bruker Esprit's h5ebsd without RawPatterns, laid out as orix's own test file (orix/tests/conftest.py
#                        `temp_bruker_h5ebsd_file`): the points stored in an order the SEM IY and IX put back (columns shuffled within
#                        each row), X SAMPLE flipped as Esprit writes it, Phase 0 not indexed, phases with IT and lattice constants.
#                        Reference: orix 0.15.0 `io.load` (io/plugins/bruker_h5ebsd.py). Its `str2atom` reads the last field of an
#                        atom as an integer occupancy, so the atoms here end in 0 (Esprit's own end in a Debye-Waller factor, which
#                        orix cannot read; macEM reads no atoms).
#   ebsd-edax-map.h5     EDAX OIM Analysis's h5ebsd without Pattern (field names with the leading space OIM writes), Euler angles in
#                        radians, CI -1 not indexed, phases with Formula, Symmetry and lattice constants. No Python reference reads an
#                        EDAX .h5 map (orix has no plugin; MTEX and DREAM3D's EbsdLib do), so its reference is the `.ang` OIM writes
#                        for the same scan: ebsd-edax-map.ang, the same numbers (float32 values written round-trip exact), read by
#                        orix 0.15.0 `io.load` (io/plugins/ang.py).
#   ebsd-emsoft-map.h5   EMsoft's dictionary indexing file (EMEBSDDI), laid out as orix's test file (`temp_emsoft_h5ebsd_file`): no
#                        Version, the best 2 matches of each point as indices into a 10-orientation dictionary in degrees, one phase,
#                        the Y Position EMsoft writes wrong. Reference: orix 0.15.0 `io.load` (io/plugins/emsoft_h5ebsd.py), the
#                        unrefined orientations (its default).
# Truth: ebsd-h5ebsd-map.truth.json, what orix returns for each, in the shape of ebsd-orix-map.truth.json: phase ids, x, y, the Euler
# angles orix makes its rotations from (the first match of each point), the properties (their first column), the phases, the unit.
# Floats are repr() (round-trip exact).
import json, sys
from pathlib import Path
import h5py
import numpy as np
from orix import __version__ as orix_version
from orix.io import load

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)

NX, NY = 4, 3
N = NX * NY
I = np.arange(N)
ROWS, COLS = np.divmod(I, NX)
# Euler angles in degrees, distinct at every point, float32 as the files store them.
EULER_DEG = np.column_stack([10 + 7.5 * I, 20 + 3.25 * I, 30 + 11.0 * I]).astype(np.float32)
PHASE = np.array([1, 1, 2, 2,
                  1, 0, 2, 2,
                  1, 1, 1, 2])

# ---------------------------------------------------------------------------------------------------- Bruker
DX, DY = 1.5, 1.0
# The file's order: within each row the columns 2, 0, 3, 1 (Esprit stores a region's points as it scanned them).
cols = np.tile([2, 0, 3, 1], NY)
rows = ROWS.copy()
order = np.ravel_multi_index([rows, cols], (NY, NX))   # the map position of each stored point
with h5py.File(out / "ebsd-bruker-map.h5", "w") as f:
    f.create_dataset("Manufacturer", data=np.array([b"Bruker Nano"]))
    f.create_dataset("Version", data=np.array([b"Esprit 2.X"]))
    ebsd = f.create_group("Scan 1/EBSD")
    data, header, sem = ebsd.create_group("Data"), ebsd.create_group("Header"), ebsd.create_group("SEM")
    sem.create_dataset("IY", data=rows.astype(np.int32))
    sem.create_dataset("IX", data=cols.astype(np.int32))
    x = (cols * DX).astype(np.float32)
    y = (rows * DY).astype(np.float32)
    columns = {
        "DD": (0.6 + I / 100)[order].astype(np.float32), "MAD": (0.2 + I / 50)[order].astype(np.float32),
        "MADPhase": PHASE[order].astype(np.int32), "NIndexedBands": (5 + I % 4)[order].astype(np.int32),
        "PCX": (0.5 + I / 1000)[order].astype(np.float32), "PCY": (0.25 + I / 1000)[order].astype(np.float32),
        "RadonBandCount": (8 + I % 3)[order].astype(np.int32), "RadonQuality": (0.5 + I / 64)[order].astype(np.float32),
        "X BEAM": cols.astype(np.int32), "Y BEAM": rows.astype(np.int32),
        "X SAMPLE": x[::-1], "Y SAMPLE": y, "Z SAMPLE": np.zeros(N, dtype=np.float32),
        "Phase": PHASE[order].astype(np.int32),
        "phi1": EULER_DEG[order, 0], "PHI": EULER_DEG[order, 1], "phi2": EULER_DEG[order, 2],
    }
    for name, values in columns.items():
        data.create_dataset(name, data=values)
    header.create_dataset("NROWS", data=np.int32(NY))
    header.create_dataset("NCOLS", data=np.int32(NX))
    header.create_dataset("Grid Type", data=np.array([b"isometric"]))
    header.create_dataset("XSTEP", data=np.float64(DX))
    header.create_dataset("YSTEP", data=np.float64(DY))
    for pid, (name, formula, it, lattice) in {1: ("Aluminium", "Al", 225, [4.05, 4.05, 4.05, 90, 90, 90]),
                                               2: ("Magnesium", "Mg", 194, [3.21, 3.21, 5.21, 90, 90, 120])}.items():
        g = header.create_group(f"Phases/{pid}")
        g.create_dataset("Name", data=np.array([name.encode()]))
        g.create_dataset("Formula", data=np.array([formula.encode()]))
        g.create_dataset("IT", data=np.int32(it))
        g.create_dataset("LatticeConstants", data=np.array(lattice, dtype=np.float32))
        g.create_dataset("Setting", data=np.int32(1))
        g.create_dataset("AtomPositions/1", data=np.array([f"{formula},0,0,0,1,0".encode()]))

# ---------------------------------------------------------------------------------------------------- EDAX
EDX, EDY = 0.5, 0.25
CI = np.where(PHASE == 0, -1.0, 0.1 + I / 20).astype(np.float32)
EDAX_PHASE = np.where(PHASE == 0, 0, PHASE).astype(np.int8)
euler_rad = np.deg2rad(EULER_DEG.astype(np.float64)).astype(np.float32)
ex = (COLS * EDX).astype(np.float32); ey = (ROWS * EDY).astype(np.float32)
iq = (100 + 3.5 * I).astype(np.float32); sem_signal = (1000 + 10 * I).astype(np.int32); fit = (0.5 + I / 8).astype(np.float32)
EDAX_PHASES = {1: ("Nickel", "Ni", 43, [3.524, 3.524, 3.524, 90, 90, 90]), 2: ("Titanium (Alpha)", "Ti", 62, [2.95, 2.95, 4.686, 90, 90, 120])}
with h5py.File(out / "ebsd-edax-map.h5", "w") as f:
    f.create_dataset(" Manufacturer", data=np.array([b"EDAX"]))
    f.create_dataset(" Version", data=np.array([b"OIM Analysis 8.6.0101 x64 [09-01-22]"]))
    ebsd = f.create_group("Scan 1/EBSD")
    data, header = ebsd.create_group("Data"), ebsd.create_group("Header")
    for name, values in {"CI": CI, "Fit": fit, "IQ": iq, "Phase": EDAX_PHASE, "Phi1": euler_rad[:, 0], "Phi": euler_rad[:, 1],
                         "Phi2": euler_rad[:, 2], "SEM Signal": sem_signal, "Valid": np.ones(N, dtype=np.int8),
                         "X Position": ex, "Y Position": ey}.items():
        data.create_dataset(name, data=values)
    header.create_dataset("Grid Type", data=np.array([b"SqrGrid"]))
    header.create_dataset("nColumns", data=np.array([NX], dtype=np.int32))
    header.create_dataset("nRows", data=np.array([NY], dtype=np.int32))
    header.create_dataset("Step X", data=np.array([EDX], dtype=np.float32))
    header.create_dataset("Step Y", data=np.array([EDY], dtype=np.float32))
    header.create_dataset("Sample Tilt", data=np.array([70], dtype=np.float32))
    for pid, (name, formula, symmetry, lattice) in EDAX_PHASES.items():
        g = header.create_group(f"Phase/{pid}")
        g.create_dataset("MaterialName", data=np.array([name.encode()]))
        g.create_dataset("Formula", data=np.array([formula.encode()]))
        g.create_dataset("Info", data=np.array([b""]))
        g.create_dataset("Symmetry", data=np.array([symmetry], dtype=">i4"))
        for k, v in zip(["a", "b", "c", "alpha", "beta", "gamma"], lattice):
            g.create_dataset(f"Lattice Constant {k}", data=np.array([v], dtype=">f4"))
r = lambda v: repr(float(v))
lines = ["# TEM_PIXperUM          1.000000", "# x-star                0.500000", "# y-star                0.500000",
         "# z-star                0.500000", "# WorkingDistance       15.000000", "#"]
for pid, (name, formula, symmetry, lattice) in EDAX_PHASES.items():
    lat = [float(np.float32(v)) for v in lattice]
    lines += [f"# Phase {pid}", f"# MaterialName  \t{name}", f"# Formula     \t{formula}", "# Info \t\t",
              f"# Symmetry              {symmetry}", "# LatticeConstants      " + " ".join(repr(v) for v in lat), "#"]
lines += ["# GRID: SqrGrid", f"# XSTEP: {EDX}", f"# YSTEP: {EDY}", f"# NCOLS_ODD: {NX}", f"# NCOLS_EVEN: {NX}", f"# NROWS: {NY}", "#"]
for k in range(N):
    lines.append(" ".join([r(euler_rad[k, 0]), r(euler_rad[k, 1]), r(euler_rad[k, 2]), r(ex[k]), r(ey[k]), r(iq[k]), r(CI[k]),
                           str(int(EDAX_PHASE[k])), str(int(sem_signal[k])), r(fit[k])]))
(out / "ebsd-edax-map.ang").write_text("\n".join(lines) + "\n")

# ---------------------------------------------------------------------------------------------------- EMsoft
SDX, SDY = 2.0, 1.25
NNK, FZ = 2, 10
dictionary = np.column_stack([150 + 1.5 * np.arange(FZ), 20 + 4.25 * np.arange(FZ), 300 - 6.5 * np.arange(FZ)]).astype(np.float32)
top = np.column_stack([(I * 3) % FZ + 1, (I * 7 + 2) % FZ + 1]).astype(np.int32)   # 1-based, as EMsoft writes them
with h5py.File(out / "ebsd-emsoft-map.h5", "w") as f:
    f.create_dataset("Manufacturer", data="EMEBSDDictionaryIndexing.f90")
    ebsd = f.create_group("Scan 1/EBSD")
    data, header = ebsd.create_group("Data"), ebsd.create_group("Header")
    for name, value, dtype in [("nRows", NY, np.int32), ("nColumns", NX, np.int32), ("Step Y", SDY, np.float32), ("Step X", SDX, np.float32)]:
        header.create_dataset(name, data=np.array([value], dtype=dtype))
    header.create_dataset("Grid Type", data=np.array([b"SqrGrid"]))
    data.create_dataset("X Position", data=(COLS * SDX).astype(np.float32))
    data.create_dataset("Y Position", data=np.tile(np.arange(NX) * SDX, NY).astype(np.float32))   # wrong, as EMsoft writes it
    data.create_dataset("AvDotProductMap", data=(I * 5).reshape(NY, NX).astype(np.int32))
    data.create_dataset("CI", data=(0.8 - I / 100).astype(np.float32))
    data.create_dataset("IQ", data=(0.3 + I / 40).astype(np.float32))
    data.create_dataset("ISM", data=(1.5 + I / 10).astype(np.float32))
    data.create_dataset("KAM", data=(I / 16).reshape(NY, NX).astype(np.float32))
    data.create_dataset("OSM", data=(2 - I / 32).reshape(NY, NX).astype(np.float32))
    data.create_dataset("Phase", data=np.zeros(N, dtype=np.uint8))
    data.create_dataset("FZcnt", data=np.array([FZ], dtype=np.int32))
    data.create_dataset("TopMatchIndices", data=top)
    data.create_dataset("TopDotProductList", data=np.column_stack([0.9 - I / 100, 0.85 - I / 100]).astype(np.float32))
    data.create_dataset("DictionaryEulerAngles", data=dictionary)
    data.create_dataset("Valid", data=np.ones(N, dtype=np.int8))
    f.create_dataset("NMLparameters/EBSDIndexingNameListType/nnk", data=np.array([NNK], dtype=np.int32))
    phase = header.create_group("Phase/1")
    for name, value in [("Point Group", "Cubic (Oh) [m3m]"), ("MaterialName", "Ni/Ni"), ("Lattice Constant a", "3.524"),
                        ("Lattice Constant b", "3.524"), ("Lattice Constant c", "3.524"), ("Lattice Constant alpha", "90.0"),
                        ("Lattice Constant beta", "90.0"), ("Lattice Constant gamma", "90.0")]:
        phase.create_dataset(name, data=np.array([value], dtype=np.dtype("S")))

# ---------------------------------------------------------------------------------------------------- truth
flt = lambda a: [repr(float(v)) for v in np.asarray(a, dtype=np.float64).ravel()]
truth = {"orix": orix_version, "files": {}}
euler_by_file = {
    # The radians orix builds its rotations from: np.deg2rad of the float32 degrees (float32 arithmetic) for Bruker and EMsoft, the
    # .ang's numbers for EDAX.
    "ebsd-bruker-map.h5": lambda xmap: np.deg2rad(EULER_DEG),   # put back in map order by orix's final_preparations
    "ebsd-edax-map.h5": lambda xmap: euler_rad,
    "ebsd-emsoft-map.h5": lambda xmap: np.deg2rad(dictionary)[top[:, 0] - 1],
}
for name, source in [("ebsd-bruker-map.h5", "ebsd-bruker-map.h5"), ("ebsd-edax-map.h5", "ebsd-edax-map.ang"),
                     ("ebsd-emsoft-map.h5", "ebsd-emsoft-map.h5")]:
    xmap = load(out / source)
    euler = euler_by_file[name](xmap)
    # orix's own rotations agree with the angles stated here (its Euler round trip, to float64 rounding).
    first = xmap.rotations if xmap.rotations_per_point == 1 else xmap.rotations[:, 0]
    from orix.quaternion import Rotation
    assert np.allclose((Rotation.from_euler(np.asarray(euler, dtype=np.float64)) * ~first.flatten()).angle, 0, atol=1e-6), name
    props = {k: flt(np.asarray(xmap.prop[k]).reshape(xmap.size, -1)[:, 0]) for k in xmap.prop.keys()}
    truth["files"][name] = {
        "reference": source, "size": int(xmap.size), "pointCount": int(xmap.size), "shape": list(xmap.shape),
        "rotationsPerPoint": int(xmap.rotations_per_point),
        "phaseIDs": [int(v) for v in xmap.phase_id], "x": flt(xmap.x), "y": flt(xmap.y), "euler": flt(euler),
        "properties": props, "scanUnit": xmap.scan_unit, "dx": repr(float(xmap.dx)), "dy": repr(float(xmap.dy)),
        "phases": [{"id": int(i), "name": p.name, "spaceGroup": None if p.space_group is None else int(p.space_group.number),
                    "pointGroup": None if p.point_group is None else p.point_group.name, "color": p.color,
                    "lattice": flt(p.structure.lattice.cell_parms())} for i, p in xmap.phases],
    }
(out / "ebsd-h5ebsd-map.truth.json").write_text(json.dumps(truth, indent=1, sort_keys=True) + "\n")
