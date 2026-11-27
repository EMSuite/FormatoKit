//
//  EDSReadError.swift
//  Role: what a SEM-EDS reader says when a file is not what it claims: the fact as a typed reason (the format it is not, the
//        part it lacks, the size no reader holds, ...) and one sentence that names the file, for a consumer that shows it as it
//        is. The sentence never names the consumer: one whose words name the app (which room opens the file, that the app was
//        not given access) words them from the reason.
//        Moved from Electron Microscopy Studio's Sources/TEMSEM/EDS/SEMEDSFile.swift (`SEMEDSReadError`, at f1eaafc) by
//        FormatoKit#148, with the reason added; the sentences are the app's, less the app's name.
//

import Foundation

public nonisolated struct EDSReadError: Error, LocalizedError, Equatable, Sendable {
    /// The fact behind a refusal.
    public enum Reason: Equatable, Sendable {
        /// The file is not the format its extension names (not an SFS container, a first word that is not JEOL's, an extension
        /// no reader here reads). RosettaSciIO refuses these files too.
        case notThisFormat
        /// A part the reader needs is absent: a header node, a spectrum, a calibration, a file a JEOL project names.
        case missing
        /// The file ends before its header says it does.
        case truncated
        /// Parts of the file that disagree: a pixel table that does not describe its counts, a chain of chunks that links back,
        /// a pointer outside the file, a damaged compressed block.
        case damaged
        /// A size no reader holds: a product that overflows, more items than the file holds for them, more than
        /// `EDSFile.largestArray` items in one array.
        case size
        /// Data stored in a way the readers do not read: an image of another pixel size, counts of another width, a header
        /// value of an unknown type, a compression other than zlib.
        case unsupportedType
        /// A header number that is not a number in range: a size, a date or a magnification that gives no length.
        case number
        /// A JEOL project names a file outside its own folder.
        case outsideFolder
        /// A JEOL project names itself again, or nests deeper than the reader follows.
        case loop
        /// A count above the largest value of the data type RosettaSciIO names for the spectrum image, met when its dense
        /// counts are read (`EDSSparseSpectrumImage.read`); the sparse counts keep it.
        case countAboveType
        /// The system does not let this process read the file (a sandbox without its grant, a file mode).
        case notPermitted
        /// The file could not be read (missing, or a disk error): the sentence says what.
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

    /// `name` could not be read because of `error`: the sentence the readers give, "<name> could not be read: <why>", with a
    /// system error's domain and code after its own sentence. A permission failure is `.notPermitted`, anything else
    /// `.unreadable`.
    package static func reading(_ name: String, _ error: any Error) -> EDSReadError {
        EDSReadError(isPermission(error) ? .notPermitted : .unreadable, "\(name) could not be read: \(detail(error))")
    }

    /// `error`'s sentence; for a system error followed by its domain and code and the underlying error's, as
    /// "The file “a.spc” couldn’t be opened because you don’t have permission to view it. (NSCocoaErrorDomain 257; underlying
    /// NSPOSIXErrorDomain 1)" (the consumer's `ErrorDetail.text` at f1eaafc, which wrote the readers' sentences).
    package static func detail(_ error: any Error) -> String {
        let sentence = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        guard isSystem(error) else { return sentence }
        let ns = error as NSError
        var code = "\(ns.domain) \(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            code += "; underlying \(underlying.domain) \(underlying.code)"
        }
        return "\(sentence) (\(code))"
    }

    /// An error the system made (an `NSError`, or Foundation's Cocoa, POSIX or URL error), not one of a reader's own.
    private static func isSystem(_ error: any Error) -> Bool {
        type(of: error) is NSError.Type || error is CocoaError || error is POSIXError || error is URLError
    }

    private static func isPermission(_ error: any Error) -> Bool {
        if let cocoa = error as? CocoaError { return cocoa.code == .fileReadNoPermission }
        if let posix = error as? POSIXError { return posix.code == .EACCES || posix.code == .EPERM }
        return false
    }
}
