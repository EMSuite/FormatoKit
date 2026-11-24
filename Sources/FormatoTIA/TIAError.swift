//
//  TIAError.swift
//  What FormatoTIA refuses, by name. Messages never contain a whole path.
//

import Foundation

public nonisolated enum TIAError: Error, Equatable, LocalizedError {
    /// The bytes are not a TIA series header (byte order "II", series id 0x0197).
    case notTIA(String)
    /// The series holds no valid element (RosettaSciIO's IOError: a single spectrum is kept in its .emi, which is not read).
    case noValidData
    /// A series with no dimension array, whose axes would come from the stage positions alone (RosettaSciIO's path for it fails).
    case noDimensions
    /// A data type code outside TIA's ten.
    case dataType(Int)
    /// A header, an offset array or an element that runs past the end of the file.
    case truncated(String)
    /// Elements and shape that do not fit together (more stored values than the dimensions hold, say).
    case inconsistent(String)
    /// An .emi file whose metadata cannot be read: no `<ObjectInfo>` document, one that is not UTF-8 or breaks a bound of
    /// `GuardedXML`, or no `<name>_<digit>.ser` file beside it.
    case emi(String)

    public var errorDescription: String? {
        switch self {
        case .notTIA(let what): "It is not a TIA .ser file (\(what))."
        case .noValidData:
            "The file holds no valid data. If it is a single spectrum, its values are kept in the .emi file, which this reader does not read."
        case .noDimensions: "The series has no dimension array; its axes would have to be guessed from stage positions, which is not read."
        case .dataType(let code): "Its data type code \(code) is not one of TIA's."
        case .truncated(let what): "The file ends before its \(what) does."
        case .inconsistent(let what): "Its elements do not fit its dimensions (\(what))."
        case .emi(let what): "The .emi file cannot be read (\(what))."
        }
    }
}
