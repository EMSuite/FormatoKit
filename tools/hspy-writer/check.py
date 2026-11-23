"""HyperSpy reads the .hspy files the kit writes (pin H2, FormatoKit#142). A Mac or nightly step: it needs the kit's files.

    swift test -c release --filter HSPYWriterTests          # with FORMATO_HSPY_OUT=<folder> set: the kit's files land there
    References/hspy-venv/bin/python -I -B tools/hspy-writer/check.py <folder>

For every planted signal of Tests/FormatoHSPYTests/Fixtures/hyperspy-layout.json (tools/hspy-writer/generate.py) the folder
holds `<name>.hspy`, written by `HSPYWriter.write`. Each is loaded three ways: RosettaSciIO 0.14.0's `rsciio.hspy.file_reader`,
HyperSpy 2.5.0's `hs.load`, and `hs.load(lazy=True)`. Each load must give, as pin H2 says:
  - the class HyperSpy itself gave the planted signal (Signal2D, EDSTEMSpectrum, EELSSpectrum, ElectronDiffraction2D, ...;
    `Lazy` + that name for the lazy load), and no warning from HyperSpy that the file's package is missing;
  - the data `array_equal` to the planted values, with the planted dtype;
  - every axis: name, units, size and navigate equal; scale and offset equal to the bit;
  - the metadata tree: the title, the signal type and every planted entry equal (a list as the same list, in order);
    `original_metadata` empty.
Writes <folder>/check-result.json (the versions, and each file's verdict with what failed) and exits 1 when any file fails.
"""
import json, logging, pathlib, struct, sys, warnings

warnings.filterwarnings('ignore')


class Caught(logging.Handler):
    """HyperSpy's own warnings (a missing package is a `_logger.warning`), kept for the verdict."""
    def __init__(self):
        super().__init__(logging.WARNING)
        self.messages = []

    def emit(self, record):
        self.messages.append(record.getMessage())


CAUGHT = Caught()

import numpy as np
import hyperspy
import hyperspy.api as hs
import rsciio
import exspy  # noqa: F401  (registers the EDS and EELS classes)
import pyxem  # noqa: F401  (registers electron_diffraction)
from rsciio.hspy import file_reader

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from generate import PINS, data_rule  # noqa: E402
logging.disable(logging.NOTSET)          # generate.py silences HyperSpy's log; the check reads it

logging.getLogger('hyperspy').addHandler(CAUGHT)
logging.getLogger('hyperspy').propagate = False

ROOT = pathlib.Path(__file__).resolve().parents[2]
LAYOUT = ROOT / 'Tests/FormatoHSPYTests/Fixtures/hyperspy-layout.json'


def bits(x):
    return struct.pack('<d', float(x))


def undefined(value):
    return value is None or str(value) in ('', '<undefined>') or type(value).__name__ == '_Undefined'


def check_signal(s, spec, lazy):
    problems = []
    want_class = ('Lazy' if lazy else '') + spec['hyperspy_class']
    if type(s).__name__ != want_class:
        problems.append(f'class {type(s).__name__}, not {want_class}')
    data = np.asarray(s.data.compute() if lazy else s.data)
    want = data_rule(spec['dtype'], spec['shape'])
    if data.dtype != want.dtype or not np.array_equal(data, want):
        problems.append(f'data {data.dtype} {list(data.shape)} differs from the planted {want.dtype} {list(want.shape)}')
    axes = s.axes_manager._axes
    if len(axes) != len(spec['axes']):
        problems.append(f'{len(axes)} axes, not {len(spec["axes"])}')
    for i, (a, w) in enumerate(zip(axes, spec['axes'])):
        if (w['name'] is None and not undefined(a.name)) or (w['name'] is not None and a.name != w['name']):
            problems.append(f'axis {i} name {a.name!r}, not {w["name"]!r}')
        if (not w['units'] and not undefined(a.units)) or (w['units'] and a.units != w['units']):
            problems.append(f'axis {i} units {a.units!r}, not {w["units"]!r}')
        if a.size != w['size'] or bool(a.navigate) != w['navigate']:
            problems.append(f'axis {i} size {a.size} navigate {a.navigate}, not {w["size"]} {w["navigate"]}')
        if bits(a.scale) != bits(w['scale']) or bits(a.offset) != bits(w['offset']):
            problems.append(f'axis {i} scale {a.scale!r} offset {a.offset!r}, not {w["scale"]!r} {w["offset"]!r}')
    if s.metadata.General.title != spec['title']:
        problems.append(f'title {s.metadata.General.title!r}, not {spec["title"]!r}')
    kinds = {'generic': '', 'edsTEM': 'EDS_TEM', 'edsSEM': 'EDS_SEM', 'eels': 'EELS', 'electronDiffraction': 'electron_diffraction'}
    if s.metadata.Signal.signal_type != kinds[spec['kind']]:
        problems.append(f'signal_type {s.metadata.Signal.signal_type!r}, not {kinds[spec["kind"]]!r}')
    for entry in spec['metadata']:
        got = s.metadata.get_item(entry['key'], default='<missing>')
        if isinstance(got, np.ndarray):
            got = got.tolist()
        want = entry['value']
        same = {'number': lambda: isinstance(got, (float, np.floating)) and bits(got) == bits(want),
                'flag': lambda: isinstance(got, (bool, np.bool_)) and bool(got) == want,
                'text': lambda: isinstance(got, str) and got == want,
                'texts': lambda: isinstance(got, list) and got == want}[entry['type']]()
        if not same:
            problems.append(f'metadata {entry["key"]} = {got!r}, not {entry["value"]!r}')
    if s.original_metadata.as_dictionary():
        problems.append('original_metadata is not empty')
    return problems


def check_file(path, spec):
    verdict = {}
    try:
        dicts = file_reader(str(path))
        d = dicts[0]
        problems = []
        if len(dicts) != 1:
            problems.append(f'{len(dicts)} experiments')
        if not np.array_equal(d['data'], data_rule(spec['dtype'], spec['shape'])):
            problems.append('data differs')
        verdict['rsciio'] = problems
    except Exception as error:  # a refusal is a finding, not a crash of the check
        verdict['rsciio'] = [f'{type(error).__name__}: {error}']
    for lazy in (False, True):
        key = 'hs.load(lazy=True)' if lazy else 'hs.load'
        try:
            CAUGHT.messages.clear()
            s = hs.load(str(path), lazy=lazy)
            problems = check_signal(s, spec, lazy)
            problems += [f'HyperSpy warned: {m}' for m in CAUGHT.messages if 'package' in m.lower()]
            verdict[key] = problems
        except Exception as error:
            verdict[key] = [f'{type(error).__name__}: {error}']
    return verdict


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: check.py <folder of the kit-written .hspy files>')
    for name, (module, want) in PINS.items():
        if module.__version__ != want:
            sys.exit(f'tools/hspy-writer/check.py: {name} {module.__version__} is not the pinned {want}')
    folder = pathlib.Path(sys.argv[1])
    signals = json.loads(LAYOUT.read_text())['signals']
    result = {'versions': {name: module.__version__ for name, (module, _) in PINS.items()}, 'files': {}}
    failed = 0
    for spec in signals:
        path = folder / f'{spec["name"]}.hspy'
        if not path.exists():
            verdict = {'missing': [f'{path.name} is not in {folder}']}
        else:
            verdict = check_file(path, spec)
        ok = all(not problems for problems in verdict.values())
        failed += not ok
        result['files'][path.name] = {'ok': ok, **verdict}
        print(('ok    ' if ok else 'FAIL  ') + path.name + ('' if ok else f': {verdict}'))
    (folder / 'check-result.json').write_text(json.dumps(result, indent=1, ensure_ascii=False, sort_keys=True) + '\n')
    print(f'{len(signals) - failed} of {len(signals)} kit-written files load in HyperSpy {hyperspy.__version__} '
          f'and RosettaSciIO {rsciio.__version__} as planted')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
