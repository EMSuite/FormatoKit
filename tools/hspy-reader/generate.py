"""The .hspy files HyperSpy writes, and RosettaSciIO's reading of them, for the kit's reader (pin H4, FormatoKit#98).

    References/hspy-venv/bin/python -I -B tools/hspy-reader/generate.py

The environment is tools/hspy-writer/requirements.txt (HyperSpy 2.5.0, RosettaSciIO 0.14.0, exspy 0.3.2, pyxem 0.21.0,
h5py 3.16.0), the writer pin's own; any other version is refused.

Into Tests/FormatoHSPYTests/Fixtures/reader/ it writes, each with HyperSpy's own writer (`s.save`: RosettaSciIO's
`file_writer` with its defaults, gzip and shuffle, HyperSpy's chunks, lists of text as `_list_<key>` datasets):
  - the planted signals of pin H2 (tools/hspy-writer/generate.py PLANTED) that are small: rank 1 to 4; uint8, uint16, int16,
    uint32, int32, float32, float64; text with Å and µ; lists of elements; EDS, EELS, electron diffraction and generic.
    The four large ones (written there to pin HyperSpy's chunk rule, megabytes each) are left out; `chunked-edges.hspy`
    is the H2 EDS map saved with small chunks instead, so a read crosses chunks and partial edge chunks;
  - `more-types.hspy`: a small signal of each type the kit stores that pin H2 has not (int8, int64, uint64), each saved by
    HyperSpy and copied into one file as its own experiment (h5py `copy`, bytes and attributes unchanged): one file of
    three experiments, which HyperSpy's own writer never makes but RosettaSciIO reads;
  - `lazy-saved.hspy`: a signal saved from a lazy HyperSpy signal (`attributes._lazy` true): read like any other;
  - `layout-2.0.hspy`: a HyperSpy save with its layout version set to 2.0: RosettaSciIO's metadata moves for layouts before 3.0;
  - `EDS_SEM_TM002.hspy`: exspy 0.3.2's public example file (in its wheel, `exspy/data`; GPL-3.0 as exspy), copied
    unchanged: layout 3.0, no `_type` on its axis, an empty axis name, a `_list_elements` dataset;
  - `refusals.hspy`: what the kit refuses, five experiments merged the same way: complex data, a non-uniform axis
    (DataAxis), a functional axis (FunctionalDataAxis), a ragged signal, five dimensions; and three files h5py writes that
    are refused whole: a layout older than 1.2, a HyperSpy file without an experiment, an HDF5 file that is not HyperSpy's.

`reader-truth.json` holds each file's SHA-256 and, for each readable file, RosettaSciIO 0.14.0's `rsciio.hspy.file_reader`
reading of every experiment: its group name, title, signal type, the data's type, shape and SHA-256 (C order,
little-endian), every axis (name, size, scale and offset as `float.hex`, units, navigate) and the metadata tree flattened
to dotted keys the way the kit holds it (`flatten` below). For the refusals it names the kit's `HSPYError` case of each experiment.
"""
import hashlib, importlib.util, json, logging, pathlib, shutil, tempfile, warnings

warnings.filterwarnings('ignore')
logging.disable(logging.WARNING)

import h5py
import numpy as np
import hyperspy.api as hs
import exspy
from rsciio.hspy import file_reader

ROOT = pathlib.Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location('hspy_writer_generate', ROOT / 'tools/hspy-writer/generate.py')
writer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(writer)          # checks the pinned versions (HyperSpy, RosettaSciIO, exspy, pyxem, h5py)

OUT = ROOT / 'Tests/FormatoHSPYTests/Fixtures/reader'
LARGE = {'eds-tem-map-chunked-u16', 'patterns-4d-chunked-u16', 'eels-small-axis-chunked-f32', 'stack-big-frames-u8'}
MORE_TYPES = ['int8', 'int64', 'uint64']


def sha256_file(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def data_sha256(data):
    a = np.ascontiguousarray(data)
    return hashlib.sha256(a.astype(a.dtype.newbyteorder('<')).tobytes()).hexdigest()


def flatten(tree, prefix=''):
    """RosettaSciIO's metadata dictionary as the kit's metadata entries: dotted keys in the dictionary's order; text, a
    bool (flag), a number (int or float, as a float64 by `float.hex`) and a list of text kept; None, other lists, tuples,
    arrays and bytes left out (FormatoValue has no place for them)."""
    out = []
    for key, value in tree.items():
        path = prefix + key
        if isinstance(value, dict):
            out += flatten(value, path + '.')
        elif isinstance(value, str):
            out.append({'key': path, 'type': 'text', 'value': value})
        elif isinstance(value, (bool, np.bool_)):
            out.append({'key': path, 'type': 'flag', 'value': bool(value)})
        elif isinstance(value, (int, float, np.integer, np.floating)):
            out.append({'key': path, 'type': 'number', 'value': float(value).hex()})
        elif isinstance(value, list) and all(isinstance(v, str) for v in value):
            out.append({'key': path, 'type': 'texts', 'value': list(value)})
    return out


def axis_record(axis):
    name = axis.get('name')
    units = axis.get('units')
    return {'name': name, 'size': int(axis['size']), 'scale': float(axis.get('scale', 1.0)).hex(),
            'offset': float(axis.get('offset', 0.0)).hex(), 'units': units if units is not None else '',
            'navigate': bool(axis['navigate'])}


def reading(path):
    """RosettaSciIO's reading of every experiment of `path`, with the experiments' group names (h5py's order, which is
    the order RosettaSciIO reads them in)."""
    with h5py.File(path, 'r') as f:
        names = [n for n in f['Experiments'] if isinstance(f['Experiments'][n], h5py.Group) and 'data' in f['Experiments'][n]]
    out = []
    for name, exp in zip(names, file_reader(str(path))):
        md = exp['metadata']
        out.append({'name': name, 'title': md.get('General', {}).get('title', ''),
                    'signal_type': md.get('Signal', {}).get('signal_type', ''), 'dtype': exp['data'].dtype.name,
                    'shape': list(exp['data'].shape), 'data_sha256': data_sha256(exp['data']),
                    'axes': [axis_record(a) for a in exp['axes']], 'metadata': flatten(md)})
    return out


def merge(singles, path):
    """One file holding the experiment of each of `singles` (files HyperSpy saved), copied by h5py unchanged."""
    with h5py.File(path, 'w') as merged:
        with h5py.File(singles[0], 'r') as first:
            for key, value in first.attrs.items():
                merged.attrs[key] = value
        experiments = merged.create_group('Experiments')
        for one in singles:
            with h5py.File(one, 'r') as f:
                for name in f['Experiments']:
                    f.copy(f['Experiments'][name], experiments, name=name)


def save(signal, path, **kwds):
    signal.save(path, overwrite=True, **kwds)


def layout2(path):
    s = hs.signals.Signal1D(writer.data_rule('float32', [2, 3]))
    s.metadata.General.title = 'Layout 2.0'
    for key, value in [('Acquisition_instrument.TEM.beam_energy', 200.0), ('Acquisition_instrument.TEM.tilt_stage', 12.5),
                       ('Acquisition_instrument.TEM.exposure_time', 0.5), ('Acquisition_instrument.TEM.Stage.x', 1.0),
                       ('Acquisition_instrument.TEM.Stage.y', 2.0), ('Acquisition_instrument.TEM.camera_length', 80.0),
                       ('Acquisition_instrument.SEM.beam_energy', 15.0), ('Acquisition_instrument.SEM.tilt_stage', 3.0)]:
        s.metadata.set_item(key, value)
    save(s, path)
    with h5py.File(path, 'r+') as f:
        f.attrs['file_format_version'] = '2.0'


def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    files = []

    def record(path, refusals=None):
        entry = {'file': path.name, 'sha256': sha256_file(path)}
        if refusals:
            entry['refusals'] = refusals
        else:
            entry['experiments'] = reading(path)
        files.append(entry)

    # Pin H2's small planted signals, saved by HyperSpy.
    planted = {}
    for name, kind, title, dtype, axes, metadata in writer.PLANTED:
        shape = [a['size'] for a in axes]
        s = writer.make_signal(kind, dtype, axes, writer.data_rule(dtype, shape))
        s.metadata.General.title = title
        for entry in metadata:
            s.metadata.set_item(entry['key'], entry['value'])
        planted[name] = s
        if name in LARGE:
            continue
        path = OUT / f'{name}.hspy'
        save(s, path)
        record(path)

    # Chunks smaller than the data, with partial chunks at the edges.
    path = OUT / 'chunked-edges.hspy'
    save(planted['eds-sem-map-u16'], path, chunks=(2, 3, 7))
    with h5py.File(path, 'r') as f:
        assert f['Experiments/EDS map/data'].chunks == (2, 3, 7)
    record(path)

    # The three types pin H2 has not, as three experiments in one file.
    path = OUT / 'more-types.hspy'
    with tempfile.TemporaryDirectory() as tmp:
        singles = []
        for n, dtype in enumerate(MORE_TYPES):
            s = hs.signals.Signal1D(writer.data_rule(dtype, [2, 5]))
            s.metadata.General.title = f'type {dtype}'
            s.axes_manager[0].name, s.axes_manager[0].scale = 'x', 0.5 + n
            s.axes_manager[1].name, s.axes_manager[1].units, s.axes_manager[1].offset = 'E', 'eV', -1.25 * n
            one = pathlib.Path(tmp) / f'{dtype}.hspy'
            save(s, one)
            singles.append(one)
        merge(singles, path)
    record(path)

    # Saved from a lazy signal.
    path = OUT / 'lazy-saved.hspy'
    lazy = hs.signals.Signal1D(writer.data_rule('uint16', [3, 4])).as_lazy()
    lazy.metadata.General.title = 'Saved lazily'
    save(lazy, path)
    with h5py.File(path, 'r') as f:
        assert bool(f['Experiments/Saved lazily/attributes'].attrs['_lazy'])
    record(path)

    # Layout 2.0: RosettaSciIO moves TEM and SEM `tilt_stage` to `Stage.tilt_alpha` (replacing the old Stage group in its
    # place) and TEM `exposure_time` to `Detector.Camera.exposure` (a new group, last in TEM). HyperSpy saves 3.3; the
    # root's version is then set to 2.0 by h5py.
    path = OUT / 'layout-2.0.hspy'
    layout2(path)
    record(path)

    # exspy's public example, unchanged.
    source = pathlib.Path(exspy.__file__).parent / 'data' / 'EDS_SEM_TM002.hspy'
    path = OUT / 'EDS_SEM_TM002.hspy'
    shutil.copyfile(source, path)
    record(path)

    # The refusals, each signal written by HyperSpy, the five in one file as five experiments.
    with tempfile.TemporaryDirectory() as tmp:
        refused = {}
        s = hs.signals.ComplexSignal2D((np.arange(12) + 1j * np.arange(12)).reshape(3, 4).astype('complex64'))
        refused['complex'] = (s, 'complexData')
        s = hs.signals.Signal1D(np.arange(10.0))
        s.axes_manager[0].convert_to_non_uniform_axis()
        refused['non-uniform'] = (s, 'nonUniformAxis')
        s = hs.signals.Signal1D(np.arange(10.0))
        s.axes_manager[0].convert_to_functional_data_axis(expression='x**2')
        refused['functional'] = (s, 'nonUniformAxis')
        ragged = np.empty((3,), dtype=object)
        for i in range(3):
            ragged[i] = np.arange(i + 1, dtype=float)
        refused['ragged'] = (hs.signals.BaseSignal(ragged, ragged=True), 'raggedSignal')
        refused['rank 5'] = (hs.signals.Signal1D(np.zeros((2, 2, 2, 2, 3), dtype='uint8')), 'unsupportedRank')
        singles = []
        for title, (s, _) in refused.items():
            s.metadata.General.title = title
            one = pathlib.Path(tmp) / f'{title}.hspy'
            save(s, one)
            singles.append(one)
        path = OUT / 'refusals.hspy'
        merge(singles, path)
        record(path, {title: case for title, (_, case) in refused.items()})

    # The file-level refusals, written by h5py: a layout older than 1.2, a HyperSpy file without an experiment, an HDF5 file
    # that is not HyperSpy's.
    path = OUT / 'refused-version-1.1.hspy'
    with h5py.File(path, 'w') as f:
        f.attrs['file_format'] = 'HyperSpy'
        f.attrs['file_format_version'] = '1.1'
    record(path, {'(file)': 'unsupportedVersion'})
    path = OUT / 'refused-no-experiment.hspy'
    with h5py.File(path, 'w') as f:
        f.attrs['file_format'] = 'HyperSpy'
        f.attrs['file_format_version'] = '3.3'
        f.create_group('Experiments')
    record(path, {'(file)': 'noExperiment'})
    path = OUT / 'refused-not-hyperspy.hspy'
    with h5py.File(path, 'w') as f:
        f.create_dataset('data', data=np.arange(4, dtype='uint8'))
    record(path, {'(file)': 'notHyperSpyFile'})

    pins = {name: module.__version__ for name, (module, _) in writer.PINS.items()}
    pins['numpy'] = np.__version__
    pins['libhdf5'] = h5py.version.hdf5_version
    doc = {'versions': pins, 'tm002_source_sha256': sha256_file(source), 'files': files}
    (OUT / 'reader-truth.json').write_text(json.dumps(doc, indent=1, ensure_ascii=False, sort_keys=True) + '\n')
    total = sum(p.stat().st_size for p in OUT.iterdir())
    print(f'wrote {OUT}: {len(files)} files and reader-truth.json, {total / 1024:.0f} KB')


if __name__ == '__main__':
    main()
