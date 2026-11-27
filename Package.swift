// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only
// FormatoKit: electron-microscopy file formats for the Mac, checked bit for bit against RosettaSciIO at a pinned commit.
// Swift 6 mode, no unsafe flags. What one module needs from another is `package`, never `public`; what a consumer reads
// is `public` and is guarded by tools/consumer-check. libhdf5 ships as three binary XCFramework targets (arm64 macOS,
// built by tools/xcframework/build.sh); with FORMATO_LOCAL_XCFRAMEWORKS set they are the local build in dist/xcframeworks.
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

// The release the three zips are attached to, and their SwiftPM checksums (written by a release run of tools/xcframework/build.sh).
// The asset names carry the rebuild: `-r2` are the zips without AppleDouble `._*` entries (#32). The first build's zips stay on
// the release under their own names, so every tag up to 0.11.0 still resolves with the checksums it pins.
let xcframeworkRelease = "0.4.0"
let xcframeworkRebuild = "-r2"
let xcframeworks: [(name: String, checksum: String)] = [
    ("FormatoLibHDF5", "c16fd49b1935fd3c1be47bc391417894ecd0e1122dfda999f91129060b41925e"),
    ("FormatoLibSZ", "c41dd18fedd12bcbc9dbbb79cc331c7244ac9d3ec3e4f712b20457d3063fdb52"),
    ("FormatoLibAEC", "fd8fed678701cc671ba4a7880f577485b0283634113e39ca05f949cbcee759ad"),
]
let useLocalXCFrameworks = Context.environment["FORMATO_LOCAL_XCFRAMEWORKS"] != nil
let binaryTargets: [Target] = xcframeworks.map { framework in
    useLocalXCFrameworks
        ? .binaryTarget(name: framework.name, path: "dist/xcframeworks/\(framework.name).xcframework")
        : .binaryTarget(
            name: framework.name,
            url: "https://github.com/EMSuite/FormatoKit/releases/download/\(xcframeworkRelease)/\(framework.name)\(xcframeworkRebuild).xcframework.zip",
            checksum: framework.checksum)
}

let package = Package(
    name: "FormatoKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FormatoCore", targets: ["FormatoCore"]),
        .library(name: "FormatoDM", targets: ["FormatoDM"]),
        .library(name: "FormatoEMD", targets: ["FormatoEMD"]),
        .library(name: "FormatoHDF5", targets: ["FormatoHDF5"]),
        .library(name: "FormatoTIFF", targets: ["FormatoTIFF"]),
        .library(name: "FormatoMRC", targets: ["FormatoMRC"]),
        .library(name: "FormatoEMPAD", targets: ["FormatoEMPAD"]),
        .library(name: "FormatoMIB", targets: ["FormatoMIB"]),
        .library(name: "FormatoMSA", targets: ["FormatoMSA"]),
        // FEI / Thermo Fisher TIA series files (.ser), read as RosettaSciIO reads a .ser on its own.
        .library(name: "FormatoTIA", targets: ["FormatoTIA"]),
        // HyperSpy's .hspy files, layout 3.3 (0.19.0): a signal written whole or a slab at a time, and read back.
        .library(name: "FormatoHSPY", targets: ["FormatoHSPY"]),
        // One import and one `FormatoLoader.load(path:)` for every format that reads as signals (0.9.0).
        .library(name: "Formato", targets: ["Formato"]),
        // One decimated frame and the header facts of a file, never more than one frame read (0.10.0): Quick Look and Finder-style consumers.
        .library(name: "FormatoPeek", targets: ["FormatoPeek"]),
        // EBSD patterns and orientation maps (kikuchipy h5ebsd, Bruker, EDAX, Oxford, EMsoft, NORDIF; .ang and .ctf) as plain data,
        // and the .ang and .ctf writers; ported from kikuchipy 0.13.1 and orix 0.15.0 (FormatoKit#147).
        .library(name: "FormatoEBSD", targets: ["FormatoEBSD"]),
        // SEM-EDS maps, spectra and images of Bruker (.bcf, .spx), EDAX (.spd, .lsd, .spc) and JEOL (.pts, .eds, .img, .map, .asw)
        // as FormatoCore signals, ported from RosettaSciIO 0.15.0 (FormatoKit#148).
        .library(name: "FormatoEDS", targets: ["FormatoEDS"]),
    ],
    targets: binaryTargets + [
        // The data model every reader returns: arrays, axes, units, metadata with provenance, lazy signals; cancellation.
        .target(name: "FormatoCore", swiftSettings: settings),
        // HDF5: the process-wide HDF5 lock and quit barrier (HDF5Serial), the shipped libhdf5, the slab writer under the hspy writer.
        .target(name: "FormatoHDF5",
                dependencies: ["FormatoCore"] + xcframeworks.map { .target(name: $0.name, condition: .when(platforms: [.macOS])) },
                swiftSettings: settings),
        // Gatan DigitalMicrograph .dm3 / .dm4: DM4Experiment (inherited reader) and the signal adapter.
        .target(name: "FormatoDM", dependencies: ["FormatoCore"], swiftSettings: settings),
        // EMD: Velox (inherited reader) and its image adapter. Later: NCEM / Berkeley EMD.
        .target(name: "FormatoEMD", dependencies: ["FormatoCore", "FormatoHDF5"], swiftSettings: settings),
        // Additional formats; EMPAD reads XML + memory-mapped raw frames.
        .target(name: "FormatoTIFF", dependencies: ["FormatoCore", "FormatoDM"], swiftSettings: settings),
        .target(name: "FormatoMRC", dependencies: ["FormatoCore"], swiftSettings: settings),
        .target(name: "FormatoEMPAD", dependencies: ["FormatoCore"], swiftSettings: settings),
        .target(name: "FormatoMIB", dependencies: ["FormatoCore"], swiftSettings: settings),
        .target(name: "FormatoMSA", dependencies: ["FormatoCore"], swiftSettings: settings),
        .target(name: "FormatoTIA", dependencies: ["FormatoCore"], swiftSettings: settings),
        // HyperSpy's .hspy layout over FormatoHDF5's slab writer and reader; no numerics.
        .target(name: "FormatoHSPY", dependencies: ["FormatoCore", "FormatoHDF5"], swiftSettings: settings),
        .target(name: "Formato", dependencies: ["FormatoCore", "FormatoDM", "FormatoEDS", "FormatoEMD", "FormatoHSPY", "FormatoMRC", "FormatoMSA",
                                               "FormatoTIA", "FormatoTIFF"],
                swiftSettings: settings),
        .target(name: "FormatoPeek",
                dependencies: ["FormatoCore", "FormatoDM", "FormatoEMD", "FormatoHDF5", "FormatoHSPY", "FormatoMRC", "FormatoMSA", "FormatoTIA",
                               "FormatoTIFF", "Formato"],
                swiftSettings: settings),
        // EBSD: pattern and map readers by record and through FormatoHDF5's lock, the .ang and .ctf writers; no crystallography.
        .target(name: "FormatoEBSD", dependencies: ["FormatoCore", "FormatoHDF5"], swiftSettings: settings),
        // SEM-EDS: the Bruker SFS container and hypermap unpacker, the EDAX and JEOL readers; spectrum images held sparse.
        .target(name: "FormatoEDS", dependencies: ["FormatoCore"], swiftSettings: settings),
        // Examples, not products. `swift run formato-peek <file>`: one decimated frame and the header facts.
        .executableTarget(name: "formato-peek", dependencies: ["FormatoPeek"], path: "Examples/formato-peek", swiftSettings: settings),
        // The first ten minutes: `swift run formato-info <file>` prints every signal of a DM, Velox or TIFF file (public API only).
        .executableTarget(name: "formato-info", dependencies: ["FormatoCore", "Formato"],
                          path: "Examples/formato-info", swiftSettings: settings),

        // The kit's side of the FormatoKit-vs-RosettaSciIO benchmark (tools/benchmarks/bench.py). Not a product.
        .executableTarget(name: "formato-bench",
                          dependencies: ["FormatoCore", "FormatoDM", "FormatoEMD", "FormatoHDF5", "FormatoMIB", "FormatoMRC", "FormatoMSA",
                                         "FormatoEMPAD", "FormatoTIFF"],
                          path: "tools/benchmarks/formato-bench", swiftSettings: settings),

        // FormatoCore's own tests: the data model, units, lazy = eager, and the pins against RosettaSciIO.
        .testTarget(name: "FormatoCoreTests", dependencies: ["FormatoCore", "FormatoDM", "FormatoEMD"],
                    exclude: ["Fixtures"], swiftSettings: settings),
        // Test support, not a product: the fixture folders (FixtureDirs) and the pinned acquisition-metadata comparisons
        // (tools/acq-metadata).
        .target(name: "FormatoKitTestSupport", dependencies: ["FormatoCore"], path: "Tests/FormatoKitTestSupport", swiftSettings: settings),
        .testTarget(name: "FormatoDMTests", dependencies: ["FormatoDM", "FormatoCore", "FormatoKitTestSupport"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoEMDTests", dependencies: ["FormatoEMD", "FormatoCore", "FormatoHDF5", "FormatoKitTestSupport"],
                    exclude: ["Fixtures"], swiftSettings: settings),
        .testTarget(name: "FormatoHDF5Tests", dependencies: ["FormatoHDF5", "FormatoCore", "FormatoEMD", "FormatoHDF5ExitProbe"],
                    exclude: ["Fixtures"],
                    swiftSettings: settings),
        // A child process for the quit-barrier tests (`exit` runs the atexit handlers, which a test cannot watch from inside
        // its own process). Not a product; FormatoHDF5Tests depends on it only so `swift test` builds it.
        .executableTarget(name: "FormatoHDF5ExitProbe", dependencies: ["FormatoEMD", "FormatoHDF5"],
                          path: "Tests/FormatoHDF5ExitProbe", swiftSettings: settings),
        // The TIFF container and TIFF files as signals, against RosettaSciIO and tifffile.
        .testTarget(name: "FormatoTIFFTests", dependencies: ["FormatoTIFF", "FormatoDM", "FormatoCore", "FormatoKitTestSupport"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoMRCTests", dependencies: ["FormatoMRC", "FormatoCore", "FormatoKitTestSupport"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoEMPADTests", dependencies: ["FormatoEMPAD", "FormatoCore", "FormatoKitTestSupport"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoMIBTests", dependencies: ["FormatoMIB", "FormatoCore", "FormatoKitTestSupport"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoMSATests", dependencies: ["FormatoMSA", "FormatoCore"], exclude: ["Fixtures"], swiftSettings: settings),
        // The .ser reader against RosettaSciIO's reading of its public TIA test files (pin T1, tools/tia).
        .testTarget(name: "FormatoTIATests", dependencies: ["FormatoTIA", "FormatoCore"], exclude: ["Fixtures"], swiftSettings: settings),
        // The .hspy writer against the layout HyperSpy 2.5.0 writes (pin H2, tools/hspy-writer), the slab writer's footprint;
        // the reader against RosettaSciIO's reading of HyperSpy's own files (pin H4, tools/hspy-reader).
        .testTarget(name: "FormatoHSPYTests", dependencies: ["FormatoHSPY", "FormatoHDF5", "FormatoCore"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        // The EBSD readers and writers moved from Electron Microscopy Studio with their tests, fixtures and m1 reference bundles.
        .testTarget(name: "FormatoEBSDTests", dependencies: ["FormatoEBSD", "FormatoCore", "FormatoHDF5"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        // The SEM-EDS readers moved from Electron Microscopy Studio with their tests, fixtures and m7 reference bundles.
        .testTarget(name: "FormatoEDSTests", dependencies: ["FormatoEDS", "FormatoCore"], exclude: ["Fixtures"], swiftSettings: settings),
        .testTarget(name: "FormatoPeekTests", dependencies: ["FormatoPeek", "FormatoCore", "FormatoHDF5", "FormatoHSPY", "FormatoTIA", "FormatoKitTestSupport"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoLoaderTests", dependencies: ["Formato", "FormatoCore", "FormatoEDS", "FormatoHSPY", "FormatoTIA"],
                    swiftSettings: settings),
        // The comparisons with the pinned RosettaSciIO, Pint and tifffile values and the inherited golden baseline, byte for byte
        // (`swift test -c release --parallel --skip FormatoKitParityTests` leaves them out). Fixtures stay in the old test folders.
        .testTarget(name: "FormatoKitParityTests",
                    dependencies: ["FormatoCore", "FormatoDM", "FormatoEMD", "FormatoMIB", "FormatoTIFF", "FormatoPeek", "FormatoKitTestSupport"],
                    swiftSettings: settings),
    ],
    swiftLanguageModes: [.v6]
)
