# ``FormatoHSPY``

Writes a signal as a HyperSpy file (`.hspy`, layout 3.3), the way HyperSpy 2.5.0 and RosettaSciIO 0.14.0 write it, and reads
HyperSpy's files of one to four dimensions the way RosettaSciIO 0.14.0 reads them.

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

``HSPYReader/experiments(url:)`` lists a file's experiments (title, signal type, shape, stored type, axes, or why one is
refused) without reading data. ``HSPYReader/read(url:experiment:)`` returns one as a lazy signal whose data is read a
hyperslab at a time at its stored type; ``HSPYReader/readStored(url:experiment:)`` reads it whole, the signal the writer
takes back. Gzip-compressed and chunked files, as HyperSpy writes them, read as well as the writer's own. The metadata tree
comes back with dotted keys (`Acquisition_instrument.TEM.beam_energy`, `Sample.elements` as a list of text). Refused by
name: ragged signals, complex data, other non-numeric types, more than four dimensions, non-uniform axes, layouts older
than 1.2.

## Topics

### Writing

- ``HSPYWriter``
- ``HSPYStreamWriter``
- ``HSPYSignalKind``
- ``HSPYWriteOptions``
- ``HSPYError``

### Reading

- ``HSPYReader``
- ``HSPYExperiment``
