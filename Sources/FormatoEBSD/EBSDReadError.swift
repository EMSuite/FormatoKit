//
//  EBSDReadError.swift
//  Role: what an EBSD reader says when a file is not what it claims: the fact as a typed reason (the maker the readers do not
//        read, the dataset or group the file lacks, the grid it was acquired on, ...) and one sentence that names the file, for a
//        consumer that shows it as it is. The sentence never names the consumer: one whose words name the app (where to open the
//        file instead, which room shows it, that the app was not given access) words them from the reason.
//        An HDF5 or Foundation failure is said in plain words (`wrap`): no HDF5 call, no path inside the file, no error domain.
//        Moved from Electron Microscopy Studio's Sources/TEMSEM/EBSDDataset.swift (at 7b09bf5) by FormatoKit#147.
//

import Foundation
import FormatoHDF5

public nonisolated struct EBSDReadError: Error, LocalizedError, Equatable, Sendable {
    /// The fact behind a refusal.
    public enum Reason: Equatable, Sendable {
        /// The file names no software that wrote it, or no format version: no EBSD file.
        case notEBSD
        /// An EBSD file of a maker the readers do not read (the file's `manufacturer`, lowercased).
        case manufacturer(String)
        /// No scan group, or no scan of that name (the scans the file holds).
        case noScan(named: String?, scans: [String])
        /// A dataset or group the reader needs, by its name in the file (`X Cells`, `Phases`, `Euler`).
        case missing(String)
        /// A grid other than the square one: the file's name for it (`HexGrid`, `hexagonal`), nil when it names none.
        case grid(String?)
        /// A region of interest that is not a rectangle.
        case regionNotRectangular
        /// An H5OINA with EDS data and no EBSD data.
        case edsOnly
        /// A file of a known maker with neither patterns nor an orientation map.
        case nothingToRead
        /// A map was asked of a file that holds patterns (its map comes with them, `EBSDH5Reader.read`).
        case holdsPatterns
        /// Patterns were asked of a file that holds an orientation map and no patterns (`EBSDH5Reader.readMap`).
        case holdsMapOnly
        /// No layout of orientation map the readers read.
        case notAMap
        /// The system does not let this process read the file (a sandbox without its grant, a file mode).
        case notPermitted
        /// Data compressed with an HDF5 filter the shipped library does not have.
        case filter
        /// More than is read in one piece.
        case tooLarge
        /// Data stored in a type the readers do not read.
        case unsupportedType
        /// The file went away after it was opened (its volume, or the file cut short).
        case gone
        /// The file ends before its data does.
        case truncated
        /// A scan or pattern size no reader can lay out (no rows, or more bytes than an Int counts).
        case size
        /// A map position outside the scan.
        case position
        /// A header number that is not a whole number in range.
        case number
        /// The file could not be read (damaged, missing, or not laid out as its format says): the sentence says what.
        case unreadable
    }

    public var reason: Reason
    /// One sentence that names the file.
    public var text: String
    public var errorDescription: String? { text }

    public init(_ reason: Reason, _ text: String) {
        self.reason = reason
        self.text = text
    }

    /// `error` as the sentence of `file`: a reader's own words, or an HDF5 or Foundation failure in plain words (`plainWords`), with
    /// the file's name in front where the words do not name it already.
    public static func wrap(_ error: Error, file: URL) -> EBSDReadError {
        let name = file.lastPathComponent
        let reason: Reason
        let words: String
        if let already = error as? EBSDReadError { reason = already.reason; words = already.text }
        else if let hdf5 = error as? HDF5FileError { (reason, words) = plainWords(hdf5) }
        else if let cocoa = error as? CocoaError { (reason, words) = plainWords(cocoa) }
        else { reason = .unreadable; words = (error as? LocalizedError)?.errorDescription ?? String(describing: error) }
        return EBSDReadError(reason, words.contains(name) ? words : "\(name): \(words)")
    }

    /// A Foundation file error in words, without its error domain or code.
    public static func plainWords(_ error: CocoaError) -> (Reason, String) {
        switch error.code {
        case .fileReadNoPermission: return (.notPermitted, "the system does not let this process read it.")
        case .fileReadNoSuchFile, .fileNoSuchFile: return (.gone, "it is no longer there.")
        case .fileReadCorruptFile: return (.unreadable, "it could not be read (the file may be damaged).")
        default: return (.unreadable, "it could not be read.")
        }
    }

    /// An HDF5 failure in words: what is wrong with the file, never the HDF5 call or the path inside it.
    public static func plainWords(_ error: HDF5FileError) -> (Reason, String) {
        switch error {
        case .cannotOpen: return (.unreadable, "it cannot be opened as an HDF5 file (it may be damaged, or still being written).")
        case .notPermitted: return (.notPermitted, "the system does not let this process read it.")
        case .hdf5(_, let detail) where detail.localizedCaseInsensitiveContains("filter"):
            return (.filter, "its data is compressed with a filter the HDF5 library here does not have.")
        case .hdf5: return (.unreadable, "its data could not be read (the file may be damaged).")
        case .library: return (.unreadable, "the HDF5 library could not be loaded.")
        case .limitExceeded: return (.tooLarge, "it holds more than is read in one piece.")
        case .unsupportedType: return (.unsupportedType, "it stores its data in a type that is not read.")
        default: return (.unreadable, "it is not laid out as its format says.")
        }
    }
}
