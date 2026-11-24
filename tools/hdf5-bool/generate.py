"""h5py's boolean attribute: the reference file, its facts, and h5py's reading of the kit-written file (pin H1).

    References/venv/bin/python -I -B tools/hdf5-bool/generate.py

h5py stores a NumPy `bool` as an HDF5 enumeration over an 8-bit signed integer with the members FALSE = 0 and TRUE = 1, and
reads that enumeration back as `numpy.bool_`. `HDF5WriteSession.setBoolAttribute(_:on:_:)` writes the same type.

(a) Writes with h5py Tests/FormatoHDF5Tests/Fixtures/bool/h5py-bool.h5: the attributes `yes` (True) and `no` (False), scalar, on
    the root, on the group /g and on the dataset /g/d. Records in h5py-pins.json, for each attribute, how h5py stores and reads it:
    the HDF5 class, the size, the base type's class, size, sign and byte order, the members by name, the stored value, the NumPy
    type h5py reads it as and the value. The Swift test reads the kit-written attributes' types with the kit's own HDF5 layer and
    compares them with these facts, exactly; it reads h5py-bool.h5 the same way.

(b) When Tests/FormatoHDF5Tests/Fixtures/bool/swift-bool.h5 exists (written by the kit:
    `FORMATO_WRITE_GOLDEN=1 swift test -c release --filter HDF5BoolAttributeTests`, a change on purpose), has h5py read it and
    records the same facts and its SHA-256 in check-result.json, with the verdict that every attribute reads as `numpy.bool_` with
    the value the test wrote (the same names and values as h5py-bool.h5). The Swift test pins that file.
"""
import hashlib, json, pathlib, sys
import h5py
import numpy as np

H5PY = '3.16.0'
if h5py.__version__ != H5PY:
    sys.exit(f'tools/hdf5-bool/generate.py: h5py {h5py.__version__} is not the pinned {H5PY} (tools/requirements.txt)')

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'Tests/FormatoHDF5Tests/Fixtures/bool'
OUT.mkdir(parents=True, exist_ok=True)

# The objects and attributes both files carry: (object path, attribute name, value).
PLANTED = [(path, name, value) for path in ('/', '/g', '/g/d') for name, value in (('yes', True), ('no', False))]
CLASS_NAMES = {h5py.h5t.INTEGER: 'integer', h5py.h5t.ENUM: 'enum'}
ORDER_NAMES = {h5py.h5t.ORDER_LE: 'little', h5py.h5t.ORDER_BE: 'big', h5py.h5t.ORDER_NONE: 'none'}


def facts(f, path, name):
    """How h5py stores and reads the attribute `name` of the object at `path`."""
    obj = f[path]
    a = h5py.h5a.open(obj.id, name.encode())
    t = a.get_type()
    cls = t.get_class()
    pin = {'class': CLASS_NAMES.get(cls, f'class{cls}'), 'size': t.get_size(), 'scalar': a.shape == ()}
    if cls == h5py.h5t.ENUM:
        base = t.get_super()
        pin['base'] = {'class': CLASS_NAMES.get(base.get_class(), f'class{base.get_class()}'), 'size': base.get_size(),
                       'signed': base.get_sign() == h5py.h5t.SGN_2, 'order': ORDER_NAMES[base.get_order()]}
        pin['members'] = {t.get_member_name(i).decode(): int(t.get_member_value(i)) for i in range(t.get_nmembers())}
    raw = np.zeros((), dtype='<i1')
    a.read(raw, mtype=h5py.h5t.NATIVE_INT8)          # the stored integer, whatever the enum names it
    pin['stored'] = int(raw)
    value = obj.attrs[name]                          # what h5py hands a Python caller
    pin['numpy_type'] = type(value).__module__ + '.' + type(value).__name__
    pin['dtype'] = str(np.asarray(value).dtype)
    pin['value'] = bool(value) if isinstance(value, np.bool_) else repr(value)
    return pin


def dump(path):
    with h5py.File(path, 'r') as f:
        return {f'{p}@{n}': facts(f, p, n) for p, n, _ in PLANTED}


# ---------------------------------------------------------------------------------------------------- (a) h5py's own file
with h5py.File(OUT / 'h5py-bool.h5', 'w') as f:
    g = f.create_group('g')
    g.create_dataset('d', data=np.arange(3, dtype='<f4'))
    for path, name, value in PLANTED:
        f[path].attrs[name] = value                  # a Python bool: h5py stores numpy.bool_
written = dump(OUT / 'h5py-bool.h5')
(OUT / 'h5py-pins.json').write_text(json.dumps({'h5py_version': h5py.__version__, 'numpy_version': np.__version__,
                                                'hdf5_version': h5py.version.hdf5_version, 'attributes': written},
                                               indent=1, sort_keys=True) + '\n')

# ---------------------------------------------------------------------------------- (b) h5py reads the kit-written file
swift = OUT / 'swift-bool.h5'
if swift.exists():
    read = dump(swift)
    failures = []
    for path, name, value in PLANTED:
        key = f'{path}@{name}'
        got = read[key]
        if got['numpy_type'] != 'numpy.bool' or got['value'] is not value:
            failures.append(f'{key}: h5py reads {got["numpy_type"]} {got["value"]!r}, not numpy.bool {value}')
        if got != written[key]:
            failures.append(f'{key}: {got} differs from what h5py writes, {written[key]}')
    result = {'h5py_version': h5py.__version__, 'numpy_version': np.__version__,
              'files': {swift.name: {'sha256': hashlib.sha256(swift.read_bytes()).hexdigest(), 'attributes': read,
                                     'reads_as_numpy_bool': not failures}}}
    (OUT / 'check-result.json').write_text(json.dumps(result, indent=1, sort_keys=True) + '\n')
    if failures:
        print('\n'.join(failures)); sys.exit(1)
print('ok', sorted(p.name for p in OUT.iterdir()))
