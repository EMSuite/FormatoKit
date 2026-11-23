//
//  HSPYTypes.swift
//  Role: what a caller says about a .hspy file it writes: the signal's kind (which names HyperSpy's class and the Python
//        package that owns it), the options (title, software line, extra metadata, chunk shape) and every refusal by name.
//

import Foundation
import FormatoCore

/// The kind of signal a .hspy file holds. It sets `metadata.Signal.signal_type`, HyperSpy's own word for it, and the `package`
/// attribute: the Python package that owns the class HyperSpy builds on load (never the app that wrote the file; HyperSpy warns
/// when the named package is not installed).
public nonisolated enum HSPYSignalKind: String, Sendable, Equatable, CaseIterable {
    /// No signal type: HyperSpy's Signal1D or Signal2D, by the number of signal axes. Package `hyperspy`.
    case generic
    /// `EDS_TEM`: exspy's EDSTEMSpectrum. One signal axis, binned.
    case edsTEM
    /// `EDS_SEM`: exspy's EDSSEMSpectrum. One signal axis, binned.
    case edsSEM
    /// `EELS`: exspy's EELSSpectrum. One signal axis, binned.
    case eels
    /// `electron_diffraction`: pyxem's ElectronDiffraction2D. Two signal axes.
    case electronDiffraction

    /// The kind whose `signalType` is `signalType` (a reader's `FormatoSignal.signalType`), nil for any other word.
    public init?(signalType: String) {
        guard let kind = Self.allCases.first(where: { $0.signalType == signalType }) else { return nil }
        self = kind
    }

    /// `metadata.Signal.signal_type`.
    public var signalType: String {
        switch self {
        case .generic: ""
        case .edsTEM: "EDS_TEM"
        case .edsSEM: "EDS_SEM"
        case .eels: "EELS"
        case .electronDiffraction: "electron_diffraction"
        }
    }

    /// The experiment group's `package` attribute: the Python package that owns the class.
    public var package: String {
        switch self {
        case .generic: "hyperspy"
        case .edsTEM, .edsSEM, .eels: "exspy"
        case .electronDiffraction: "pyxem"
        }
    }

    /// The experiment group's `package_version` attribute: the version of `package` whose layout the writer is pinned to
    /// (HyperSpy 2.5.0, exspy 0.3.2, pyxem 0.21.0; tools/hspy-writer). HyperSpy does not read it.
    public var packageVersion: String {
        switch self {
        case .generic: "2.5.0"
        case .edsTEM, .edsSEM, .eels: "0.3.2"
        case .electronDiffraction: "0.21.0"
        }
    }

    /// The number of signal axes the class needs, nil when any number from one up does.
    public var signalDimension: Int? {
        switch self {
        case .generic: nil
        case .edsTEM, .edsSEM, .eels: 1
        case .electronDiffraction: 2
        }
    }

    /// Whether the class marks its signal axis binned (`is_binned`), as exspy does for EDS and EELS.
    var binsSignalAxis: Bool {
        switch self {
        case .edsTEM, .edsSEM, .eels: true
        case .generic, .electronDiffraction: false
        }
    }
}

/// What a .hspy file says beside the data.
public nonisolated struct HSPYWriteOptions: Sendable, Equatable {
    /// `metadata.General.title` and the experiment's group name (a `/` becomes `-` there, an empty title `__unnamed__`, as
    /// HyperSpy names it). Nil takes the signal's own title (`HSPYWriter.write`) or an empty one (`HSPYWriter.open`).
    public var title: String?
    /// The software that wrote the file, for example "Electron Microscopy Studio 2.4.0 (FormatoKit 0.19.0)": the `software`
    /// of the file's entry in `metadata.General.FileIO`. Nil leaves it out.
    public var software: String?
    /// More metadata, by HyperSpy's dotted key (`Processing.dose`, `Sample.elements`): a number is stored as a float64, text
    /// as UTF-8, a flag as h5py's bool and a list of texts as a `_list_<N>_<key>` group. A key here replaces the signal's own
    /// entry of that key. The keys the writer owns (`General.title`, `Signal.signal_type`, `General.FileIO`, `_HyperSpy`) are
    /// refused (`HSPYError.reservedMetadataKey`).
    public var metadata: [String: FormatoValue]
    /// The data's chunk shape, one extent per dimension. Nil takes HyperSpy's own rule (RosettaSciIO 0.14.0
    /// `get_signal_chunks`: whole signals, about 1 MB a chunk), which is what a file HyperSpy saved has.
    public var chunkShape: [Int]?
    /// The time written to the `metadata.General.FileIO` entry. Nil is the moment the file is started.
    public var timestamp: Date?

    public init(title: String? = nil, software: String? = nil, metadata: [String: FormatoValue] = [:], chunkShape: [Int]? = nil,
                timestamp: Date? = nil) {
        self.title = title
        self.software = software
        self.metadata = metadata
        self.chunkShape = chunkShape
        self.timestamp = timestamp
    }
}

/// Why a .hspy file was not written. Nothing is left at the destination after any of them.
public nonisolated enum HSPYError: Error, Sendable, Equatable, LocalizedError {
    /// A colour type (RGB, RGBA): HyperSpy stores colour as a structured type the writer does not write.
    case unsupportedDataType(FormatoDataType)
    /// A rank outside 1 to 4.
    case unsupportedRank(Int)
    /// The axes are not one per dimension with the dimension's size (`sizes` against `shape`).
    case axesDoNotMatchShape(sizes: [Int], shape: [Int])
    /// A dimension of extent 0.
    case emptyDimension(index: Int)
    /// An axis whose scale or offset is not finite.
    case nonFiniteAxis(index: Int)
    /// Every axis navigates: a HyperSpy signal has at least one signal axis.
    case noSignalAxis
    /// A navigation axis comes after a signal axis in array order; HyperSpy keeps the signal axes last.
    case signalAxesNotLast
    /// The kind's class needs another number of signal axes (EDS and EELS one, electron diffraction two).
    case signalDimension(kind: HSPYSignalKind, expected: Int, found: Int)
    /// A title that cannot name the experiment's group: `.`, `..`, or one with a NUL.
    case invalidTitle(String)
    /// A metadata key with an empty component, a `/` or a NUL, or a component HyperSpy reads as a structure of its own
    /// (`_list_`, `_tuple_`, `_sig_`, `_bs_`, `_datetime_`, `_hspy_AxesManager_`, `_ragged_shapes_`).
    case invalidMetadataKey(String)
    /// A key the writer owns, in the options' metadata.
    case reservedMetadataKey(String)
    /// Two keys where one is a group of the other (`A.b` and `A.b.c`), or a key that is a group the writer makes.
    case conflictingMetadataKeys(String, String)
    /// A metadata text holding a NUL byte, which a stored string cannot.
    case textWithNUL(key: String)
    /// A chunk shape that is not one extent from 1 to the dimension's size per dimension, or is 4 GiB or more a chunk.
    case invalidChunkShape([Int])
    /// A slab of another element type than the file's data.
    case slabDataType(expected: FormatoDataType, found: FormatoDataType)
    /// A slab outside the data, or of another rank.
    case slabOutsideData(start: [Int], count: [Int], shape: [Int])
    /// Slab bytes that are not `count`'s elements of the data's type.
    case slabByteCount(expected: Int, found: Int)
    /// `publish` before every element was written.
    case incomplete(written: Int, expected: Int)
    /// A call on a stream writer that was already published, cancelled, or ended by a failed write.
    case finished

    public var errorDescription: String? {
        switch self {
        case .unsupportedDataType(let type): "A \(type.rawValue) signal is not written as a HyperSpy file; only integer and float data are."
        case .unsupportedRank(let rank): "A signal of \(rank) dimensions is not written as a HyperSpy file; one to four are."
        case .axesDoNotMatchShape(let sizes, let shape): "The axes \(sizes) do not match the data's shape \(shape)."
        case .emptyDimension(let index): "Dimension \(index) of the data is empty."
        case .nonFiniteAxis(let index): "Axis \(index) has a scale or offset that is not a finite number."
        case .noSignalAxis: "Every axis navigates; a HyperSpy signal needs at least one signal axis."
        case .signalAxesNotLast: "A navigation axis follows a signal axis; HyperSpy keeps the signal axes last."
        case .signalDimension(let kind, let expected, let found):
            "A \(kind.signalType) signal has \(expected) signal axes, not \(found)."
        case .invalidTitle(let title): "\"\(title)\" cannot name a HyperSpy experiment."
        case .invalidMetadataKey(let key): "\"\(key)\" is not a metadata key the HyperSpy file can hold."
        case .reservedMetadataKey(let key): "\"\(key)\" is written by the HyperSpy writer itself."
        case .conflictingMetadataKeys(let a, let b): "The metadata keys \"\(a)\" and \"\(b)\" cannot both be written: one is a group of the other."
        case .textWithNUL(let key): "The metadata text \"\(key)\" holds a NUL character."
        case .invalidChunkShape(let chunk): "\(chunk) is not a chunk shape for this data."
        case .slabDataType(let expected, let found): "A \(found.rawValue) slab does not fit \(expected.rawValue) data."
        case .slabOutsideData(let start, let count, let shape): "The slab at \(start) of \(count) is outside data of shape \(shape)."
        case .slabByteCount(let expected, let found): "The slab holds \(found) bytes where its shape needs \(expected)."
        case .incomplete(let written, let expected): "\(written) of the \(expected) values were written."
        case .finished: "The HyperSpy file was already published or abandoned."
        }
    }
}
