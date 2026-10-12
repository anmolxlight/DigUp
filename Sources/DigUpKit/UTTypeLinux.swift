#if !canImport(UniformTypeIdentifiers)
import Foundation

/// Linux has no Uniform Type Identifiers database. The crawler only ever asks whether a file is a PDF, a picture, a
/// movie, a sound or source code (`Rules.classify`), so this answers exactly that, from the file's extension.
/// The tables are the ones the system's shared-mime-info ships, cut down to the types DigUp reads; `Rules` already
/// carries its own lists for documents and code, and they are checked first.
public struct UTType: Equatable, Sendable {
    public enum Class: Sendable { case pdf, image, movie, audio, sourceCode, script, other }
    public let kind: Class

    public static let pdf = UTType(kind: .pdf)
    public static let image = UTType(kind: .image)
    public static let movie = UTType(kind: .movie)
    public static let audio = UTType(kind: .audio)
    public static let sourceCode = UTType(kind: .sourceCode)
    public static let script = UTType(kind: .script)

    /// Source code and scripts are two types on a Mac; here they're told apart the same way (a script is run, a
    /// source file is compiled), so that `Rules.classify` behaves identically.
    public func conforms(to other: UTType) -> Bool { kind == other.kind }

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "avif", "ico",
        "icns", "svg", "psd", "tga", "pbm", "pgm", "ppm", "pnm", "xbm", "xpm", "jp2", "j2k", "jpf", "jpx",
        // RAW, as the Mac's RawCamera types list them.
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "ptx", "3fr",
        "fff", "iiq", "mos", "mrw", "srw", "x3f", "erf", "kdc", "dcr", "mef",
    ]
    static let movieExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "avi", "mkv", "webm", "wmv", "flv", "f4v", "mpg", "mpeg", "mpe", "m1v", "m2v",
        "3gp", "3g2", "ogv", "mxf", "asf", "rm", "rmvb", "vob", "divx", "dv", "mts", "m2ts", "ts",
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "wave", "aif", "aiff", "aifc", "flac", "ogg", "oga", "opus", "wma",
        "amr", "ape", "mka", "mp2", "au", "snd", "caf", "ra", "mid", "midi", "dsf", "wv",
    ]
    /// Run, not compiled: the Mac types these as `public.script`.
    static let scriptExtensions: Set<String> = [
        "sh", "bash", "zsh", "fish", "csh", "ksh", "ps1", "command", "applescript", "scpt", "pl", "py", "rb", "lua",
        "tcl", "awk", "sed", "js", "mjs", "cjs", "php", "r", "jl",
    ]

    /// The type of a file with this extension, or nil for one DigUp doesn't handle (the Mac's `nil` content type).
    public init?(filenameExtension ext: String) {
        let ext = ext.lowercased()
        if ext == "pdf" { kind = .pdf }
        else if Self.imageExtensions.contains(ext) { kind = .image }
        else if Self.movieExtensions.contains(ext) { kind = .movie }
        else if Self.audioExtensions.contains(ext) { kind = .audio }
        else if Self.scriptExtensions.contains(ext) { kind = .script }
        else if Rules.sourceExtensions.contains(ext) || Rules.codeExtensions.contains(ext) { kind = .sourceCode }
        else { return nil }
    }

    private init(kind: Class) { self.kind = kind }
}
#endif
