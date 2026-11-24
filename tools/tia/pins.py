#!/usr/bin/env python3
"""Pins RosettaSciIO's TIA plugin for FormatoTIA (a .ser read on its own, pin T1 of the suite's files-exports design).

    References/venv/bin/python -I -B tools/tia/pins.py

copies RosettaSciIO's public .ser and .emi test files (`rsciio/tests/data/tia/old` and `new`, GPL-3.0-or-later) into
Tests/FormatoTIATests/Fixtures/public/ (the .emi files are pinned by tools/tia/emi-pins.py) and writes Tests/FormatoTIATests/Fixtures/tia-pins.json: for every file and for
`only_valid_data` True and False, `rsciio.tia._api.ser_reader(path, objects=None, only_valid_data=...)`: its exception, or the
data (dtype, shape, sha256 of the little-endian C-order bytes) and the axes (name, size, units, navigate, and scale and offset
as float64 bit patterns). The header facts (series version, data and tag type, total and valid elements, dimensions) are
read with RosettaSciIO's own `load_ser_file`.
"""
import hashlib
import json
import logging
import os
import shutil
import struct
import sys
import warnings

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
CLONE = os.environ.get("RSCIIO_CLONE", os.path.join(REPO, "References", "rosettasciio-049e7d70"))
SRC = os.path.join(CLONE, "rsciio", "tests", "data", "tia")
FIX = os.path.join(REPO, "Tests", "FormatoTIATests", "Fixtures")


def bits(x):
    return struct.pack("<d", float(x)).hex()


def text(v):
    if v is None:
        return None
    if isinstance(v, bytes):
        return v.decode("utf-8")
    return str(v)


def read(path, only_valid):
    from rsciio.tia import _api as tia
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            out = tia.ser_reader(path, objects=None, only_valid_data=only_valid)
    except Exception as e:  # the refusal is the pin
        return {"error": type(e).__name__}
    assert len(out) == 1
    d = out[0]
    data = np.asarray(d["data"])
    le = data.astype(data.dtype.newbyteorder("<"), copy=False)
    axes = []
    for a in d["axes"]:
        axes.append({"name": text(a.get("name")), "size": int(a["size"]), "units": text(a.get("units")) or "",
                     "navigate": bool(a.get("navigate", False)), "scale": bits(a["scale"]), "offset": bits(a["offset"])})
    return {"dtype": data.dtype.name, "shape": list(data.shape),
            "sha256": hashlib.sha256(np.ascontiguousarray(le).tobytes()).hexdigest(), "axes": axes,
            "original_filename": d["metadata"]["General"]["original_filename"]}


def header(path):
    from rsciio.tia import _api as tia
    with open(path, "rb") as f:
        h = np.fromfile(f, dtype=np.dtype(tia.get_header_dtype_list(f)), count=1)[0]
    ndim = int(h["NumberDimensions"])
    return {"series_version": int(h["SeriesVersion"]), "data_type_id": int(h["DataTypeID"]),
            "tag_type_id": int(h["TagTypeID"]), "total": int(h["TotalNumberElements"]),
            "valid": int(h["ValidNumberElements"]), "offset_array_offset": int(h["OffsetArrayOffset"]),
            "dimensions": [{"size": int(h[f"Dim-{n}_DimensionSize"]), "offset": bits(h[f"Dim-{n}_CalibrationOffset"]),
                            "delta": bits(h[f"Dim-{n}_CalibrationDelta"]),
                            "element": int(h[f"Dim-{n}_CalibrationElement"]),
                            "description": h[f"Dim-{n}_Description"].decode("utf-8"),
                            "units": h[f"Dim-{n}_Units"].decode("utf-8")} for n in range(1, ndim + 1)]}


def main():
    logging.disable(logging.CRITICAL)
    import rsciio
    pins = {"generator": "tools/tia/pins.py", "rosettasciio": rsciio.__version__, "files": {}}
    public = os.path.join(FIX, "public")
    if os.path.isdir(public):
        shutil.rmtree(public)
    for era in ("old", "new"):
        os.makedirs(os.path.join(public, era))
        for name in sorted(os.listdir(os.path.join(SRC, era))):
            if not name.endswith((".ser", ".emi")):
                continue
            src = os.path.join(SRC, era, name)
            dst = os.path.join(public, era, name)
            shutil.copyfile(src, dst)
            if name.endswith(".emi"):  # pinned by tools/tia/emi-pins.py
                continue
            key = f"{era}/{name}"
            pins["files"][key] = {"sha256": hashlib.sha256(open(src, "rb").read()).hexdigest(), "header": header(src),
                                  "valid_only": read(dst, True), "all": read(dst, False)}
    with open(os.path.join(FIX, "tia-pins.json"), "w") as f:
        json.dump(pins, f, indent=1, sort_keys=True)
        f.write("\n")
    for k, v in pins["files"].items():
        r = v["valid_only"]
        print(k, r.get("error") or (r["dtype"], r["shape"]), "| all:", v["all"].get("error") or v["all"]["shape"])


if __name__ == "__main__":
    sys.exit(main())
