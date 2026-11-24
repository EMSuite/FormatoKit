# ``FormatoTIA``

FEI / Thermo Fisher TIA series files (`.ser`) and their `.emi`, read as RosettaSciIO reads them.

## Overview

A `.ser` file holds one series: images (a single image, a stack, a STEM line scan or map of camera frames) or spectra
(a point spectrum, a line scan, a spectrum image). ``TIAReader/read(url:onlyValidData:)`` returns it as one lazy signal
with RosettaSciIO 049e7d70's shape, axes, units and values, byte for byte; ``TIAReader/header(url:)`` returns the series
header alone.

Without its `.emi`, an image's units are taken as metres (shown as nm), as RosettaSciIO does; a diffraction pattern's
reciprocal units need the `.emi`. ``TIAReader/readEMI(url:onlyValidData:)`` reads an `.emi` with every `<name>_<digit>.ser`
beside it, one signal each, with the units the `.emi`'s mode implies (a diffraction pattern in `1 / nm`), the acquisition
date and time, and the microscope metadata HyperSpy 2.5.0 maps from it (beam energy, mode, camera length, magnification,
camera, stage, user).

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
