import DigUpKit
import Foundation

/// Result thumbnails and the preview pane's big pictures, where a Mac asks Quick Look, AVFoundation and PDFKit: the
/// picture itself scaled down, the video frame at the moment that matched, the PDF page that matched with the query's
/// words marked on it (the band of the page around them, so they can be read). ffmpeg and poppler make them, off the
/// main thread, into `$XDG_CACHE_HOME/DigUp/pictures`, keyed by everything they depend on (the file's change time
/// included), so a picture is made once.
enum Pictures {
    nonisolated static let folder: URL = {
        let cache = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        let folder = cache.appendingPathComponent("DigUp/pictures")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// Two at a time: a page of results asks for many at once, and each is an ffmpeg or pdftoppm run.
    private nonisolated static let queue = DispatchQueue(label: "DigUp.pictures", qos: .userInitiated,
                                                         attributes: .concurrent)
    private nonisolated static let slots = DispatchSemaphore(value: 2)

    /// A small picture for a result row or a grid cell, or nil (the row shows the kind's icon).
    static func thumbnail(_ row: ResultRow, side: Int, _ done: @escaping @MainActor (String?) -> Void) {
        make(row, side: side, words: [], band: false, done)
    }

    /// The preview pane's picture: the frame or page that matched (the page with the words marked).
    static func preview(_ row: ResultRow, side: Int, _ done: @escaping @MainActor (String?) -> Void) {
        make(row, side: side, words: row.page == nil ? [] : row.foundWords + row.terms, band: true, done)
    }

    private static func make(_ row: ResultRow, side: Int, words: [String], band: Bool,
                             _ done: @escaping @MainActor (String?) -> Void) {
        guard [.image, .screenshot, .video, .pdf].contains(row.kind) else { return done(nil) }
        let (url, kind, page, at) = (row.url, row.kind, row.page ?? 1, row.kind == .video ? row.loc ?? 1 : 0)
        let changed = Int((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0)
        let key = "\(url.path)|\(changed)|\(side)|\(page)|\(at)|\(words.joined(separator: " "))|\(band)"
        let out = folder.appendingPathComponent(String(fnv(key), radix: 16) + ".jpg")
        if FileManager.default.fileExists(atPath: out.path) { return done(out.path) }
        queue.async {
            slots.wait()
            defer { slots.signal() }
            let made: Bool
            switch kind {
            case .pdf: made = pdfPage(url, page: page, side: side, words: words, to: out)
            case .video: made = frame(url, at: at, side: side, to: out)
            default: made = scaled(url, side: side, to: out)
            }
            let path = made && FileManager.default.fileExists(atPath: out.path) ? out.path : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { done(path) } }
        }
    }

    private nonisolated static func fit(_ side: Int) -> String {
        "scale=w='min(\(side),iw)':h='min(\(side),ih)':force_original_aspect_ratio=decrease"
    }

    private nonisolated static func scaled(_ url: URL, side: Int, to out: URL) -> Bool {
        run("ffmpeg", ["-nostdin", "-loglevel", "error", "-y", "-i", url.path, "-frames:v", "1", "-vf", fit(side),
                       "-qscale:v", "4", out.path])
    }

    /// The frame at `seconds`: a fast seek, except in MPEG transport streams (.ts, .mts, .m2ts), where ffmpeg's seek
    /// can land seconds off, so it decodes up to the moment instead.
    private nonisolated static func frame(_ url: URL, at seconds: Double, side: Int, to out: URL) -> Bool {
        let at = ["-ss", String(format: "%.2f", max(0, seconds))]
        let exact = ["ts", "mts", "m2ts"].contains(url.pathExtension.lowercased())
        return run("ffmpeg", ["-nostdin", "-loglevel", "error", "-y"] + (exact ? [] : at) + ["-i", url.path]
                   + (exact ? at : []) + ["-frames:v", "1", "-vf", fit(side), "-qscale:v", "4", out.path])
    }

    /// Page `number`, fitted into `side` pixels; with `words`, the band around the first of them (as wide as the
    /// page, 2:3 as high) with each one marked, the way the Mac's preview marks them.
    private nonisolated static func pdfPage(_ url: URL, page: Int, side: Int, words: [String], to out: URL) -> Bool {
        let (size, marks) = wordBoxes(url, page: page, words: words)
        guard let size, !marks.isEmpty else {
            let stem = out.deletingPathExtension().path
            return run("pdftoppm", ["-f", "\(page)", "-l", "\(page)", "-jpeg", "-scale-to", "\(side)", "-singlefile",
                                    url.path, stem])
        }
        let height = min(size.height, size.width / 1.5)
        let top = min(max(0, marks[0].y - height * 0.55), size.height - height)
        let scale = Double(side) / max(size.width, height)
        let render = out.deletingPathExtension().appendingPathExtension("band")
        guard run("pdftoppm", ["-f", "\(page)", "-l", "\(page)", "-png", "-singlefile", "-r", String(format: "%.2f", 72 * scale),
                               "-x", "0", "-y", "\(Int(top * scale))", "-W", "\(Int(size.width * scale))",
                               "-H", "\(Int(height * scale))", url.path, render.path]) else { return false }
        defer { try? FileManager.default.removeItem(atPath: render.path + ".png") }
        let boxes = marks.prefix(60).map { mark in
            "drawbox=x=\(Int(mark.x * scale) - 1):y=\(Int((mark.y - top) * scale) - 1):"
                + "w=\(Int(mark.width * scale) + 2):h=\(Int(mark.height * scale) + 2):color=0xFFD91A@0.45:t=fill"
        }
        return run("ffmpeg", ["-nostdin", "-loglevel", "error", "-y", "-i", render.path + ".png",
                              "-vf", boxes.joined(separator: ","), "-qscale:v", "3", out.path])
    }

    struct Box { var x, y, width, height: Double }

    /// The page's size and where `words` are on it, in points, from `pdftotext -bbox` (each word with its box).
    nonisolated static func wordBoxes(_ url: URL, page: Int, words: [String]) -> (CGSizeLike?, [Box]) {
        let wanted = Set(words.filter { $0.count >= 2 })
        guard !wanted.isEmpty, let html = output("pdftotext", ["-f", "\(page)", "-l", "\(page)", "-bbox", url.path, "-"])
        else { return (nil, []) }
        func number(_ name: String, in tag: Substring) -> Double? {
            guard let range = tag.range(of: name + "=\"") else { return nil }
            return Double(tag[range.upperBound...].prefix { $0 != "\"" })
        }
        var size: CGSizeLike?
        var boxes: [Box] = []
        for line in html.split(separator: "\n") {
            if line.contains("<page "), let width = number("width", in: line), let height = number("height", in: line) {
                size = CGSizeLike(width: width, height: height)
            }
            guard line.contains("<word "), let close = line.firstIndex(of: ">"),
                  let x0 = number("xMin", in: line), let y0 = number("yMin", in: line),
                  let x1 = number("xMax", in: line), let y1 = number("yMax", in: line) else { continue }
            let text = line[line.index(after: close)...].prefix { $0 != "<" }
            if wanted.contains(where: { !SearchText.matches(of: $0, in: String(text)).isEmpty }) {
                boxes.append(Box(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }
        return (size, boxes)
    }

    struct CGSizeLike { var width, height: Double }

    @discardableResult
    private nonisolated static func run(_ program: String, _ arguments: [String]) -> Bool {
        guard let executable = Desktop.which(program) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private nonisolated static func output(_ program: String, _ arguments: [String]) -> String? {
        Desktop.output(program, arguments)
    }

    /// A stable 64-bit hash (Swift's own is seeded per run), for cache file names.
    private nonisolated static func fnv(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    /// The pictures go when the panel and the windows close (the Mac drops its caches then too); a day's worth stays.
    static func trim() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let old = Date().addingTimeInterval(-86_400)
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let path = folder.appendingPathComponent(name).path
                if let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, date < old {
                    try? fm.removeItem(atPath: path)
                }
            }
        }
    }
}

extension FileKind {
    /// The freedesktop icon for the kind, where there's no picture.
    var iconName: String {
        switch self {
        case .screenshot, .image: "image-x-generic"
        case .pdf: "application-pdf"
        case .doc: "x-office-document"
        case .audio: "audio-x-generic"
        case .video: "video-x-generic"
        case .code: "text-x-script"
        }
    }
}
