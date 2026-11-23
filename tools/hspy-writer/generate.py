"""What HyperSpy writes into a .hspy file, for the kit's writer to match (pin H2, FormatoKit#142).

    References/hspy-venv/bin/python -I -B tools/hspy-writer/generate.py

The environment is tools/hspy-writer/requirements.txt (HyperSpy 2.5.0, RosettaSciIO 0.14.0, exspy 0.3.2, pyxem 0.21.0,
h5py 3.16.0), not the main one: HyperSpy and its signal packages are not in tools/requirements.txt.

For each planted signal below (PLANTED: rank 1 to 4, the seven types uint8, uint16, int16, uint32, int32, float32, float64,
text with Å and µ, lists of elements), HyperSpy builds the signal in the class its kind names and saves it with its own
writer (`s.save`, RosettaSciIO's `file_writer` with its defaults). The file is then read back with h5py and its layout is
recorded in Tests/FormatoHSPYTests/Fixtures/hyperspy-layout.json: every group, every attribute (its HDF5 class, whether text
is variable-length and UTF-8, its value; reals as `float.hex`), the data's type, shape, chunk shape and compression, the
SHA-256 of its bytes (C order, little-endian), and the string datasets' values. The planted signal itself is in the JSON
too, so the Swift test builds the same signal, writes it with `HSPYWriter` and compares the two layouts.

What the class adds by itself when it is made (exspy's EDS defaults: detector angles, energy resolution, stage tilt) is
removed before the save: the kit writes only what the signal states. The class's own axis facts stay (`is_binned` of an
EDS or EELS signal axis). `metadata.General.FileIO` is recorded by its attribute names only (the timestamp changes).

The documented differences the Swift test allows (docs/parity.md, the HSPY row):
  - the data is not compressed (HyperSpy: gzip with shuffle); the chunk shape is HyperSpy's own rule, so it is equal;
  - a list is a `_list_<N>_<key>` group of text attributes "0", "1", ... (zero-padded to one width when N > 10, so
    RosettaSciIO's sorted reading keeps the order); HyperSpy writes a list of text as a `_list_<key>` dataset of
    variable-length strings. Both read back as the same Python list;
  - `metadata.General.FileIO.0` holds the kit's entry (operation, io_plugin, software, timestamp), not HyperSpy's.
"""
import hashlib, json, logging, pathlib, sys, tempfile, warnings

warnings.filterwarnings('ignore')
logging.disable(logging.WARNING)

import h5py
import numpy as np
import hyperspy
import hyperspy.api as hs
import rsciio
import exspy
import pyxem

PINS = {'hyperspy': (hyperspy, '2.5.0'), 'rosettasciio': (rsciio, '0.14.0'), 'exspy': (exspy, '0.3.2'),
        'pyxem': (pyxem, '0.21.0'), 'h5py': (h5py, '3.16.0')}
for name, (module, want) in PINS.items():
    if module.__version__ != want:
        sys.exit(f'tools/hspy-writer/generate.py: {name} {module.__version__} is not the pinned {want} '
                 f'(tools/hspy-writer/requirements.txt)')

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'Tests/FormatoHSPYTests/Fixtures'


def ax(name, size, scale=1.0, offset=0.0, units='', navigate=False):
    return {'name': name, 'size': size, 'scale': scale, 'offset': offset, 'units': units, 'navigate': navigate}


def md(key, value, via='signal'):
    """A metadata entry: `via` says whether the Swift test passes it in the signal's metadata or in the options."""
    kind = 'flag' if isinstance(value, bool) else 'number' if isinstance(value, float) else \
        'texts' if isinstance(value, list) else 'text'
    return {'key': key, 'type': kind, 'value': value, 'via': via}


ELEMENTS_12 = ['Al', 'C', 'Ca', 'Cu', 'Fe', 'K', 'Mg', 'Mn', 'Na', 'O', 'Si', 'Ti']

# name, kind (HSPYSignalKind), title, dtype, axes (array order), metadata. The data is DATA_RULE.
PLANTED = [
    ('image-u8', 'generic', 'Image µm', 'uint8',
     [ax('y', 5, 0.25, 0.0, 'µm'), ax('x', 6, 0.25, 0.5, 'µm')],
     [md('General.original_filename', 'image Å.dm4')]),
    ('pattern-u16', 'electronDiffraction', 'Pattern', 'uint16',
     [ax('kx', 6, 0.0123, -0.0369, '1/nm'), ax('ky', 7, 0.0123, -0.0369, '1/nm')],
     [md('Acquisition_instrument.TEM.beam_energy', 300.0)]),
    ('image-i16-unnamed', 'generic', 'Unnamed axes', 'int16',
     [ax(None, 4), ax(None, 5)],
     []),
    ('image-f32', 'generic', 'Float image', 'float32',
     [ax('y', 5, 1.5, -3.0, 'nm'), ax('x', 4, 1.5, -3.0, 'nm')],
     [md('Signal.quantity', 'Intensity (counts)')]),
    ('stack-i32', 'generic', 'Stack', 'int32',
     [ax('Time', 3, 0.5, 0.0, 's', True), ax('y', 4, 2.0, 0.0, 'Å'), ax('x', 5, 2.0, 0.0, 'Å')],
     [md('General.date', '2026-11-23'), md('General.time', '14:05:00')]),
    ('spectrum-f64', 'generic', 'Spectrum', 'float64',
     [ax('Energy loss', 16, 0.1, 280.0, 'eV')],
     []),
    ('eds-tem-spectrum-u32', 'edsTEM', 'EDS spectrum', 'uint32',
     [ax('Energy', 32, 0.01, -0.2, 'keV')],
     [md('Sample.elements', ['Fe', 'O']), md('Acquisition_instrument.TEM.beam_energy', 200.0)]),
    ('eds-sem-map-u16', 'edsSEM', 'EDS map', 'uint16',
     [ax('y', 3, 0.1, 0.0, 'µm', True), ax('x', 4, 0.1, 0.0, 'µm', True), ax('Energy', 20, 0.02, 0.0, 'keV')],
     [md('Sample.elements', ['Al', 'Cu', 'Si']), md('Sample.xray_lines', []),
      md('Acquisition_instrument.SEM.beam_energy', 15.0)]),
    ('eels-spectrum-f32', 'eels', 'EELS spectrum', 'float32',
     [ax('Energy loss', 24, 0.125, -2.5, 'eV')],
     [md('Acquisition_instrument.TEM.beam_energy', 200.0)]),
    ('eels-map-f64', 'eels', 'EELS Å map', 'float64',
     [ax('y', 2, 0.5, 0.0, 'nm', True), ax('x', 3, 0.5, 0.0, 'nm', True), ax('Energy loss', 24, 0.25, 100.0, 'eV')],
     [md('General.authors', 'Å. Ångström, µ-lab'), md('Signal.quantity', 'Intensity (counts)'),
      md('Processing.exported_by_kit', True, via='options'), md('Processing.dose_e_per_A2', 1250.5, via='options')]),
    ('patterns-4d-u8', 'electronDiffraction', '4D patterns', 'uint8',
     [ax('y', 2, 1.25, 0.0, 'nm', True), ax('x', 3, 1.25, 0.0, 'nm', True),
      ax('kx', 6, 0.02, -0.06, '1/Å'), ax('ky', 7, 0.02, -0.07, '1/Å')],
     [md('Acquisition_instrument.TEM.beam_energy', 300.0)]),
    ('generic-4d-f32', 'generic', 'Generic 4D', 'float32',
     [ax('a', 2, 1.0, 0.0, '', True), ax('b', 2, 1.0, 0.0, '', True), ax('y', 5, 0.1, 0.0, 'nm'), ax('x', 6, 0.1, 0.0, 'nm')],
     []),
    ('image-u8-twelve-elements', 'generic', 'Twelve elements', 'uint8',
     [ax('y', 3, 1.0, 0.0, 'nm'), ax('x', 4, 1.0, 0.0, 'nm')],
     [md('Sample.elements', ELEMENTS_12, via='options')]),
    ('line-i16-slash-title', 'generic', 'a/b line', 'int16',
     [ax('Position', 2, 1.0, 0.0, 'nm', True), ax('Energy', 10, 0.5, 0.0, 'keV')],
     [md('General.title_note', 'the title holds a slash')]),
    # Large enough for HyperSpy's chunk rule (rsciio._hierarchical.get_signal_chunks, 1e6 bytes a chunk) to cut the data:
    # navigation chunks of floor(sqrt(signals per chunk)); an axis smaller than that kept whole; one signal a chunk.
    ('eds-tem-map-chunked-u16', 'edsTEM', 'Chunked EDS map', 'uint16',
     [ax('y', 64, 1.0, 0.0, 'nm', True), ax('x', 48, 1.0, 0.0, 'nm', True), ax('Energy', 512, 0.01, 0.0, 'keV')],
     []),
    ('patterns-4d-chunked-u16', 'electronDiffraction', 'Chunked patterns', 'uint16',
     [ax('y', 16, 1.0, 0.0, 'nm', True), ax('x', 20, 1.0, 0.0, 'nm', True),
      ax('kx', 64, 0.01, -0.32, '1/nm'), ax('ky', 64, 0.01, -0.32, '1/nm')],
     []),
    ('eels-small-axis-chunked-f32', 'eels', 'Chunked line scans', 'float32',
     [ax('Scan', 4, 1.0, 0.0, '', True), ax('Position', 1000, 0.1, 0.0, 'nm', True), ax('Energy loss', 256, 0.5, 0.0, 'eV')],
     []),
    ('stack-big-frames-u8', 'generic', 'Big frames', 'uint8',
     [ax('Frame', 3, 1.0, 0.0, '', True), ax('y', 1024, 0.5, 0.0, 'nm'), ax('x', 1024, 0.5, 0.0, 'nm')],
     []),
]

DTYPES = ['uint8', 'int8', 'uint16', 'int16', 'uint32', 'int32', 'int64', 'uint64', 'float32', 'float64']


def data_rule(dtype, shape):
    """The planted values: v(i) = (i * 2654435761 + 12345) mod 2**32 for the flat index i, mapped into the type exactly
    (HSPYWriterTests.plantedValues does the same)."""
    n = int(np.prod(shape))
    i = np.arange(n, dtype=np.uint64)
    v = (i * np.uint64(2654435761) + np.uint64(12345)) % np.uint64(1 << 32)
    v = v.astype(np.int64)
    if dtype == 'uint8': out = v % 256
    elif dtype == 'int8': out = v % 256 - 128
    elif dtype == 'uint16': out = v % 65536
    elif dtype == 'int16': out = v % 65536 - 32768
    elif dtype == 'uint32': out = v
    elif dtype == 'int32': out = v - (1 << 31)
    elif dtype == 'int64': out = v * 4096 - (1 << 43)
    elif dtype == 'uint64': out = v.astype(np.uint64) * np.uint64(1 << 20)
    elif dtype == 'float32': out = (v % (1 << 20)).astype(np.float64) / 64.0 - 8192.0
    elif dtype == 'float64': out = v.astype(np.float64) / 1024.0 - float(1 << 21)
    else: raise ValueError(dtype)
    return np.asarray(out).astype(dtype).reshape(shape)


def make_signal(kind, dtype, axes, data):
    signal_dims = sum(1 for a in axes if not a['navigate'])
    if kind == 'edsTEM': s = exspy.signals.EDSTEMSpectrum(data)
    elif kind == 'edsSEM': s = exspy.signals.EDSSEMSpectrum(data)
    elif kind == 'eels': s = exspy.signals.EELSSpectrum(data)
    elif kind == 'electronDiffraction': s = pyxem.signals.ElectronDiffraction2D(data)
    elif signal_dims == 1: s = hs.signals.Signal1D(data)
    elif signal_dims == 2: s = hs.signals.Signal2D(data)
    else: raise ValueError(f'{signal_dims} signal axes')
    # What the class put into the metadata by itself (exspy's EDS defaults) goes: the kit writes only what is stated.
    for key in list(s.metadata.as_dictionary()):
        if key not in ('General', 'Signal', '_HyperSpy'):
            s.metadata.__delattr__(key)
    am = s.axes_manager
    for i, spec in enumerate(axes):
        a = am._axes[i]                                      # array order, as the file stores it
        assert a.size == spec['size'] and a.navigate == spec['navigate'], (spec, a.size, a.navigate)
        if spec['name'] is not None: a.name = spec['name']
        if spec['units']: a.units = spec['units']
        a.scale = spec['scale']
        a.offset = spec['offset']
    return s


def attr_record(obj, name):
    a = obj.attrs.get_id(name)
    t = a.get_type()
    cls = t.get_class()
    value = obj.attrs[name]
    if cls == h5py.h5t.STRING:
        return {'class': 'string', 'variable': t.is_variable_str(), 'utf8': t.get_cset() == h5py.h5t.CSET_UTF8,
                'scalar': a.shape == (), 'value': value if isinstance(value, str) else value.decode()}
    if cls == h5py.h5t.ENUM and isinstance(value, np.bool_):
        return {'class': 'bool', 'scalar': a.shape == (), 'value': bool(value)}
    if cls == h5py.h5t.FLOAT:
        return {'class': 'float', 'size': t.get_size(), 'scalar': a.shape == (), 'value': float(value).hex()}
    if cls == h5py.h5t.INTEGER:
        return {'class': 'integer', 'size': t.get_size(), 'signed': t.get_sign() == h5py.h5t.SGN_2, 'scalar': a.shape == (),
                'value': int(value)}
    raise ValueError(f'{obj.name}@{name}: HDF5 class {cls}')


def layout(path):
    with h5py.File(path, 'r') as f:
        experiments = list(f['Experiments'])
        assert len(experiments) == 1, experiments
        name = experiments[0]
        exp = f['Experiments'][name]
        out = {'root_attributes': {k: attr_record(f, k) for k in sorted(f.attrs)},
               'experiments_attributes': {k: attr_record(f['Experiments'], k) for k in sorted(f['Experiments'].attrs)},
               'experiment': name, 'groups': [], 'attributes': {}, 'datasets': {}, 'file_io': {}}
        out['attributes'][''] = {k: attr_record(exp, k) for k in sorted(exp.attrs)}

        def visit(rel, obj):
            if rel.startswith('metadata/General/FileIO'):
                if isinstance(obj, h5py.Group) and rel != 'metadata/General/FileIO':
                    out['file_io'][rel] = sorted(obj.attrs)
                return
            if isinstance(obj, h5py.Group):
                out['groups'].append(rel)
                out['attributes'][rel] = {k: attr_record(obj, k) for k in sorted(obj.attrs)}
            else:
                d = {'dtype': obj.dtype.str if obj.dtype.kind != 'O' else 'vlen-str', 'shape': list(obj.shape),
                     'chunks': list(obj.chunks) if obj.chunks else None, 'compression': obj.compression,
                     'attributes': {k: attr_record(obj, k) for k in sorted(obj.attrs)}}
                if obj.dtype.kind == 'O':
                    d['strings'] = [x.decode() if isinstance(x, bytes) else x for x in obj[()].tolist()]
                else:
                    raw = np.ascontiguousarray(obj[()]).astype(obj.dtype.newbyteorder('<')).tobytes()
                    d['sha256'] = hashlib.sha256(raw).hexdigest()
                out['datasets'][rel] = d
        exp.visititems(visit)
        out['groups'].sort()
        return out


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    signals = []
    with tempfile.TemporaryDirectory() as tmp:
        for name, kind, title, dtype, axes, metadata in PLANTED:
            shape = [a['size'] for a in axes]
            data = data_rule(dtype, shape)
            s = make_signal(kind, dtype, axes, data)
            s.metadata.General.title = title
            for entry in metadata:
                s.metadata.set_item(entry['key'], entry['value'])
            path = pathlib.Path(tmp) / f'{name}.hspy'
            s.save(path, overwrite=True)
            raw = np.ascontiguousarray(data).astype(data.dtype.newbyteorder('<')).tobytes()
            signals.append({'name': name, 'kind': kind, 'title': title, 'dtype': dtype, 'shape': shape, 'axes': axes,
                            'metadata': metadata, 'data_sha256': hashlib.sha256(raw).hexdigest(),
                            'hyperspy_class': type(s).__name__, 'layout': layout(path)})
    pins = {name: module.__version__ for name, (module, _) in PINS.items()}
    pins['numpy'] = np.__version__
    pins['libhdf5'] = h5py.version.hdf5_version
    doc = {'versions': pins, 'signals': signals}
    (OUT / 'hyperspy-layout.json').write_text(json.dumps(doc, indent=1, ensure_ascii=False, sort_keys=True) + '\n')
    print(f'wrote {OUT / "hyperspy-layout.json"}: {len(signals)} signals')


if __name__ == '__main__':
    main()
