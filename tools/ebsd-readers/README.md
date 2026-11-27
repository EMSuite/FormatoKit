# ebsd-readers

The fixtures and truth of FormatoEBSD's readers (`Tests/FormatoEBSDTests/Fixtures/`), written by the Python references' own
readers (kikuchipy 0.13.1, orix 0.15.0) so a reader is tested against what the reference returns. The scripts and their fixtures
moved from Electron Microscopy Studio (67d6df4, `tools/parity/sem-readers`, `tools/parity/sem/nordif`) with FormatoKit#147,
unchanged: their comments still name the app's paths, and they wrote into the app's `EMStudioTests/Fixtures/`. Nothing here runs
per session or in CI; the unit tests read the committed fixtures.

| script | writes |
|---|---|
| `make_h5ebsd_fixtures.py <out>` | `ebsd-*.h5` / `.h5oina` (six h5ebsd files: kikuchipy, EDAX, two Bruker, two Oxford) and `ebsd-h5ebsd.truth.json` |
| `make_h5oina_map_fixtures.py <out>` | `ebsd-oxford-map*.h5oina` (planted map-only H5OINA files: no reference reads an H5OINA map, so the test states the map; the same map with processed or only unprocessed patterns) and `ebsd-oxford-eds.h5oina`, an EDS scan alone; h5py and NumPy only |
| `make_h5oina_lzf_fixture.py <ebsd-oxford.h5oina> <out>` | `ebsd-oxford-lzf.h5oina` (every dataset LZF-compressed by h5py, as AZtec writes patterns; read as the uncompressed file) |
| `make_orix_map_fixtures.py <out>` | `ebsd-orix-map*.h5` (orix's own map files, written by `orix.io.save`: a map, one with two rotations a point, one cut from it) and `ebsd-orix-map.truth.json` (`orix.io.load`) |
| `make_h5ebsd_map_fixtures.py <out>` | `ebsd-bruker-map.h5`, `ebsd-edax-map.h5` with `ebsd-edax-map.ang`, `ebsd-emsoft-map.h5` (planted map files without patterns) and `ebsd-h5ebsd-map.truth.json` (`orix.io.load`; for EDAX, of the `.ang` of the same numbers) |
| `make_h5ebsd_without_patterns.py <fixtures>` | `ebsd-bruker-nopatterns-h5ebsd.h5`, `ebsd-edax-nopatterns-h5ebsd.h5`: the committed Bruker and EDAX files without their patterns |
| `make_edax_fixtures.py <out> [sdss_ferrite_austenite.ang]` | `ebsd-edax-binary*.up1/.up2`, `ebsd-sdss-ferrite-austenite.ang`, `ebsd-tsl*.ang` and `ebsd-edax.truth.json` (kikuchipy `edax_binary`, orix `ang`) |
| `make_oxford_fixtures.py` | `sem/oxford/`: the `.ebsp` files with kikuchipy's reading of each, the `.ctf` files of orix's conftest with orix's reading, the Ti orientations head |
| `nordif/reference.py` | `sem/nordif/reference.json`: what `kikuchipy.load` reads from kikuchipy's NORDIF test scan |

`Fixtures/bundles/` holds the app's m1 reader bundles (`tools/parity/sem`, `references/m1/read-*` and their `fixtures/` inputs),
copied with equal sha256; `EBSDReaderBundleParityTests` reads them. A changed fixture or truth is a fixture move: its own commit
with the reason, and its own `fix:` PR.
