//
//  EBSDText.swift
//  Role: the lines of a text map (`.ang`, `.ctf`) as Python's universal newlines read them for orix: LF, CRLF and a lone CR end a
//        line. Electron Microscopy Studio's `TextLines` (Sources/TEMBase, at 7b09bf5), moved with the readers by FormatoKit#147.
//

nonisolated enum TextLines {
    /// The lines of `text` without their line ends. A line end at the very end gives a last empty line, as
    /// `split(omittingEmptySubsequences: false)` does; an LF-only text splits exactly as `split(separator: "\n")` splits it.
    static func split(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: isLineEnd)
    }

    /// LF, CRLF (one Character in Swift) or a lone CR: the three line ends Python's universal newlines read as one.
    static func isLineEnd(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }
}
