# ``FormatoTIA``

FEI / Thermo Fisher TIA series files (`.ser`), read as RosettaSciIO reads a `.ser` on its own.

## Overview

A `.ser` file holds one series: images (a single image, a stack, a STEM line scan or map of camera frames) or spectra
(a point spectrum, a line scan, a spectrum image). ``TIAReader/read(url:onlyValidData:)`` returns it as one lazy signal
with RosettaSciIO 049e7d70's shape, axes, units and values, byte for byte; ``TIAReader/header(url:)`` returns the series
header alone.

Without its `.emi`, an image's units are taken as metres (shown as nm), as RosettaSciIO does; a diffraction pattern's
reciprocal units need the `.emi`.

```swift
import FormatoTIA

let signal = try TIAReader.read(url: URL(fileURLWithPath: "/path/scan_1.ser"))
let frame = try signal.array.read(start: [0, 0, 0], count: [1] + Array(signal.array.shape.dropFirst()))
```

## Topics

### Reading

- ``TIAReader``
- ``TIASeriesHeader``
- ``TIADimension``
- ``TIAError``
