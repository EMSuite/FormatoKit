#!/usr/bin/env python3
"""Pins how HyperSpy 2.5.0 loads RosettaSciIO's public .emi files for FormatoTIA (pin T2 of the suite's files-exports design).

    References/hspy-venv/bin/python -I -B tools/tia/emi-pins.py

reads the .emi files tools/tia/pins.py copied into Tests/FormatoTIATests/Fixtures/public/ and writes
Tests/FormatoTIATests/Fixtures/tia-emi-pins.json: for every file, `hyperspy.api.load(path)` (RosettaSciIO 049e7d70
`tia/_api.py` `emi_reader`, `only_valid_data` True): its exception, or per signal (one per `<name>_<digit>.ser`) the .ser it
read, the data (dtype, shape, sha256 of the little-endian C-order bytes), the axes (name, size, units, navigate, and scale
and offset as float64 bit patterns), General.date and General.time, and every entry HyperSpy's metadata gets from
RosettaSciIO's `mapping` (its own loop in `hyperspy/io.py` `dict2signal`, which matches the slugified keys of
`original_metadata`, so "High tension_kV" answers `High_tension_kV`): the dotted key, and the value as a string or as a
float64 bit pattern. HyperSpy is used, not a re-implementation of its loop, so the pin is what a HyperSpy user sees.
"""
import hashlib
import json
import logging
import os
import struct
import sys
import warnings

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
FIX = os.path.join(REPO, "Tests", "FormatoTIATests", "Fixtures")


def bits(x):
    return struct.pack("<d", float(x)).hex()


def flat(tree, prefix=""):
    for k, v in tree.items():
        key = f"{prefix}{k}"
        if isinstance(v, dict):
            yield from flat(v, key + ".")
        else:
            yield key, v


def entry(key, v):
    if isinstance(v, str):
        return {"key": key, "kind": "text", "value": v}
    if isinstance(v, (bool, np.bool_)):
        raise AssertionError(f"{key}: a flag")
    return {"key": key, "kind": "number", "value": float(v), "bits": bits(v)}


def signal(s):
    data = np.asarray(s.data)
    le = data.astype(data.dtype.newbyteorder("<"), copy=False)
    axes = []
    for a in s.axes_manager._axes:
        units = a.units if isinstance(a.units, str) else ""
        name = a.name if isinstance(a.name, str) else None
        axes.append({"name": name, "size": int(a.size), "units": units, "navigate": bool(a.navigate),
                     "scale": bits(a.scale), "offset": bits(a.offset)})
    md = s.metadata.as_dictionary()
    general = md.get("General", {})
    mapped = [entry("Acquisition_instrument." + k, v) for k, v in flat(md.get("Acquisition_instrument", {}))]
    if "authors" in general:
        mapped.append(entry("General.authors", general["authors"]))
    return {"original_filename": general["original_filename"], "dtype": data.dtype.name, "shape": list(data.shape),
            "sha256": hashlib.sha256(np.ascontiguousarray(le).tobytes()).hexdigest(), "axes": axes,
            "date": general.get("date"), "time": general.get("time"), "mapped": mapped}


def main():
    logging.disable(logging.CRITICAL)
    import hyperspy
    import hyperspy.api as hs
    import rsciio
    pins = {"generator": "tools/tia/emi-pins.py", "hyperspy": hyperspy.__version__, "rosettasciio": rsciio.__version__,
            "files": {}}
    public = os.path.join(FIX, "public")
    for era in ("old", "new"):
        for name in sorted(os.listdir(os.path.join(public, era))):
            if not name.endswith(".emi"):
                continue
            path = os.path.join(public, era, name)
            key = f"{era}/{name}"
            record = {"sha256": hashlib.sha256(open(path, "rb").read()).hexdigest()}
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")
                    out = hs.load(path)
            except Exception as e:  # the refusal is the pin
                record["error"] = type(e).__name__
            else:
                record["signals"] = [signal(s) for s in (out if isinstance(out, list) else [out])]
            pins["files"][key] = record
            print(key, record.get("error") or [(r["original_filename"], r["shape"], r["date"]) for r in record["signals"]])
    with open(os.path.join(FIX, "tia-emi-pins.json"), "w") as f:
        json.dump(pins, f, indent=1, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    sys.exit(main())
