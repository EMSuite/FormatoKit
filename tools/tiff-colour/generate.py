"""Colour TIFF fixtures and NumPy pins for TIFFAppImage's brightest-channel reading (FormatoKit#93).

    References/venv/bin/python -I -B tools/tiff-colour/generate.py

tifffile writes Tests/FormatoTIFFTests/Fixtures/colour/*.tif: 8-bit RGB, chunky, as a Gatan DigitalMicrograph display export is
(a colour table with grey pixels and coloured annotations). pins.json records, for each file, how tifffile reads it back
(shape, the SHA-256 of the RGB bytes) and the reference grey: NumPy's `rgb.max(axis=-1)` as a list of uint8 values.
"""
import hashlib
import json
import pathlib

import numpy as np
import tifffile

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'Tests/FormatoTIFFTests/Fixtures/colour'
OUT.mkdir(parents=True, exist_ok=True)

rng = np.random.default_rng(93)


def display_export(height, width):
    """A grey ramp under a colour table (one hue scaled), with a red and a yellow annotation burnt in."""
    ramp = rng.integers(0, 256, size=(height, width), dtype=np.uint8)
    rgb = np.stack([ramp, (ramp.astype(np.uint16) * 3 // 4).astype(np.uint8), ramp // 2], axis=-1)
    rgb[0, :] = (255, 0, 0)          # a red annotation line
    rgb[:, -1] = (255, 255, 0)       # a yellow one
    rgb[height // 2, width // 2] = (7, 7, 7)   # one exact grey pixel
    return np.ascontiguousarray(rgb)


CASES = [
    ('colour-II', display_export(5, 7), '<', None),
    ('colour-MM', display_export(4, 6), '>', None),
    ('colour-lzw', display_export(16, 9), '<', 'lzw'),
]

pins = {'tifffile': tifffile.__version__, 'numpy': np.__version__, 'cases': []}
for name, rgb, order, compression in CASES:
    path = OUT / f'{name}.tif'
    tifffile.imwrite(path, rgb, byteorder=order, photometric='rgb', planarconfig='contig', compression=compression,
                     metadata=None)
    back = tifffile.imread(path)
    assert back.shape == rgb.shape and (back == rgb).all()
    grey = back.max(axis=-1)
    pins['cases'].append({
        'name': name,
        'shape': list(back.shape),
        'rgbSHA256': hashlib.sha256(back.tobytes()).hexdigest(),
        'brightest': [int(v) for v in grey.ravel()],
    })

(OUT / 'pins.json').write_text(json.dumps(pins, indent=1) + '\n')
