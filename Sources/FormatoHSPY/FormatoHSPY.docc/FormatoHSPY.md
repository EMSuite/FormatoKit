# ``FormatoHSPY``

Writes a signal as a HyperSpy file (`.hspy`, layout 3.3), the way HyperSpy 2.5.0 and RosettaSciIO 0.14.0 write it.

## Overview

``HSPYWriter/write(_:kind:options:to:cancelled:)`` writes a ``FormatoCore/FormatoSignal`` held in memory.
``HSPYWriter/open(shape:dataType:axes:kind:options:to:cancelled:)`` returns an ``HSPYStreamWriter`` for a cube written a slab
at a time: the writer holds no copy of the data, and the file appears at its destination only at
``HSPYStreamWriter/publish()``. A refused, failed or cancelled write leaves nothing there.

The ``HSPYSignalKind`` names the class HyperSpy builds on load (Signal1D or Signal2D, exspy's EDSTEMSpectrum, EDSSEMSpectrum and
EELSSpectrum, pyxem's ElectronDiffraction2D) and the Python package that owns it. ``HSPYWriteOptions`` add the title, the
software line written to `metadata.General.FileIO`, more metadata and the chunk shape.

The data keeps its stored type and is chunked as HyperSpy chunks it, without compression. Text is variable-length UTF-8,
booleans are h5py's, and a list of texts is a `_list_<N>_<key>` group. Every refusal is an ``HSPYError`` case.

## Topics

### Writing

- ``HSPYWriter``
- ``HSPYStreamWriter``
- ``HSPYSignalKind``
- ``HSPYWriteOptions``
- ``HSPYError``
