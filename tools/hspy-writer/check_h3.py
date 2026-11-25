"""Pin H3 (FormatoKit#151): the same content by two roads. A Mac or nightly step: it needs the kit's files.

    FORMATO_HSPY_OUT=<folder> swift test -c release --filter HSPYTwoRoadsTests    # the kit's files land in <folder>/h3
    References/hspy-venv/bin/python -I -B tools/hspy-writer/check_h3.py <folder>

`<folder>/h3/manifest.json` lists each .hspy file the kit wrote (`HSPYWriter.write`) from a signal `FormatoLoader.load` read
from a fixture: the file, the fixture (repository-relative), the signal's place in the kit's list, its title and shape, and the
signals the writer refused. For each written file, RosettaSciIO 0.14.0 reads the fixture with its format's reader
(`digitalmicrograph`, `emd` with `select_type` single_spectrum, images then spectrum_image as the kit lists them, `msa`) and
the .hspy file with `rsciio.hspy.file_reader`; the fixture's signal is the one with the file's title and shape. Pin H3 says the
two readings are equal:
  - the data `array_equal`, with the same dtype;
  - every axis: name, units, size and navigate equal (an undefined name or units equal to none); scale and offset to the bit,
    the tolerance the formats' own pins (dm-velox-pins, msa-pins) use.
The metadata is not compared: RosettaSciIO maps each format's tags its own way, and the kit writes the signal's own entries
(pin H2). Writes <folder>/h3/check-result.json (the versions, each file's verdict and the writer's refusals) and exits 1 when any
file fails.
"""
import json, pathlib, struct, sys, warnings

warnings.filterwarnings('ignore')

import h5py
import numpy as np
import rsciio
from rsciio.digitalmicrograph import file_reader as dm_reader
from rsciio.emd import file_reader as emd_reader
from rsciio.hspy import file_reader as hspy_reader
from rsciio.msa import file_reader as msa_reader

PINS = {'rosettasciio': (rsciio, '0.14.0'), 'h5py': (h5py, '3.16.0')}
ROOT = pathlib.Path(__file__).resolve().parents[2]


def bits(x):
    return struct.pack('<d', float(x))


def undefined(value):
    return value is None or str(value) in ('', '<undefined>', '_None_') or type(value).__name__ == '_Undefined'


def same_text(a, b):
    return (undefined(a) and undefined(b)) or a == b


def reference_signals(source):
    """RosettaSciIO's reading of a fixture, in the order the kit lists its signals."""
    path = str(ROOT / source)
    suffix = pathlib.Path(source).suffix.lower()
    if suffix in ('.dm3', '.dm4'):
        return dm_reader(path, lazy=False)
    if suffix == '.msa':
        return msa_reader(path)
    if suffix == '.emd':
        out = []
        for kind in ('single_spectrum', 'images', 'spectrum_image'):
            try:
                out += emd_reader(path, lazy=False, select_type=kind)
            except Exception:  # a file with none of this kind, or one RosettaSciIO refuses: the others still count
                pass
        return out
    raise ValueError(f'no RosettaSciIO reader named for {source}')


def axes_problems(got, want):
    problems = []
    if len(got) != len(want):
        return [f'{len(got)} axes in the .hspy, {len(want)} in the fixture']
    for i, (a, w) in enumerate(zip(got, want)):
        if not same_text(a.get('name'), w.get('name')):
            problems.append(f'axis {i} name {a.get("name")!r}, not {w.get("name")!r}')
        if not same_text(a.get('units'), w.get('units')):
            problems.append(f'axis {i} units {a.get("units")!r}, not {w.get("units")!r}')
        if a['size'] != w['size'] or bool(a.get('navigate')) != bool(w.get('navigate')):
            problems.append(f'axis {i} size {a["size"]} navigate {a.get("navigate")}, not {w["size"]} {w.get("navigate")}')
        a_scale, a_offset = a.get('scale', 1.0), a.get('offset', 0.0)
        w_scale, w_offset = w.get('scale', 1.0), w.get('offset', 0.0)
        if bits(a_scale) != bits(w_scale) or bits(a_offset) != bits(w_offset):
            problems.append(f'axis {i} scale {a_scale!r} offset {a_offset!r}, not {w_scale!r} {w_offset!r}')
    return problems


def check(folder, entry, cache):
    source = entry['source']
    if source not in cache:
        cache[source] = reference_signals(source)
    candidates = [d for d in cache[source]
                  if d['metadata'].get('General', {}).get('title', '') == entry['title'] and list(np.shape(d['data'])) == entry['shape']]
    if not candidates:
        return [f'RosettaSciIO gives no signal titled {entry["title"]!r} of shape {entry["shape"]} for {source}']
    written = hspy_reader(str(folder / entry['file']), lazy=False)
    if len(written) != 1:
        return [f'{len(written)} experiments in {entry["file"]}']
    got = written[0]
    best = None
    for want in candidates:   # the first equal one; otherwise the first's differences
        data = np.asarray(want['data'])
        problems = []
        if np.asarray(got['data']).dtype != data.dtype or not np.array_equal(got['data'], data):
            problems.append(f'data {np.asarray(got["data"]).dtype} differs from the fixture\'s {data.dtype}')
        problems += axes_problems(got['axes'], want['axes'])
        if not problems:
            return []
        best = best or problems
    return best


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: check_h3.py <the FORMATO_HSPY_OUT folder>')
    for name, (module, want) in PINS.items():
        if module.__version__ != want:
            sys.exit(f'tools/hspy-writer/check_h3.py: {name} {module.__version__} is not the pinned {want}')
    folder = pathlib.Path(sys.argv[1]) / 'h3'
    manifest = json.loads((folder / 'manifest.json').read_text())
    result = {'versions': {name: module.__version__ for name, (module, _) in PINS.items()}, 'files': {},
              'refused': manifest['refused']}
    cache, failed = {}, 0
    for entry in manifest['written']:
        try:
            problems = check(folder, entry, cache)
        except Exception as error:  # a refusal is a finding, not a crash of the check
            problems = [f'{type(error).__name__}: {error}']
        failed += bool(problems)
        result['files'][entry['file']] = {'source': entry['source'], 'index': entry['index'], 'ok': not problems,
                                          'problems': problems}
        print(('ok    ' if not problems else 'FAIL  ') + entry['file'] + ('' if not problems else f': {problems}'))
    for r in manifest['refused']:
        print(f'refused by the kit  {r["source"]} [{r["index"]}]: {r["reason"]}')
    (folder / 'check-result.json').write_text(json.dumps(result, indent=1, ensure_ascii=False, sort_keys=True) + '\n')
    total = len(manifest['written'])
    print(f'{total - failed} of {total} kit-written files equal RosettaSciIO {rsciio.__version__}\'s reading of their fixture')
    sys.exit(1 if failed or total == 0 else 0)


if __name__ == '__main__':
    main()
