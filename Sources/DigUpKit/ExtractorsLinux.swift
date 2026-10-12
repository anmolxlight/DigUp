#if !canImport(AppKit)
import Foundation

// The readers that are Apple frameworks on a Mac, as the command-line tools Linux has. The types, the signatures and
// the decisions (when a PDF page is rendered instead of read, which images are too small, what OCR is for) all stay
// as they are in Extractors.swift; only the thing doing the work changes.
//
//   ImageIO  -> ffmpeg / ffprobe, with heif-convert for HEIC and dcraw for camera RAW
//   Vision   -> tesseract (eng+ben+ara here)
//   PDFKit   -> pdfinfo, pdftotext (per page, in reading order) and pdftoppm (pages that must be pictures)
//   Cocoa's attributed-string readers -> pandoc (docx/odt/rtf) and catdoc (the old binary .doc)

extension ImageExtractor {
    /// Writes a downscaled copy for the model, the long side at most `maxPixel`, never upscaled, with the picture
    /// turned the way its EXIF says. ffmpeg decodes and resizes in one pass; formats it can't read (HEIC on ffmpeg 6,
    /// camera RAW) go through heif-convert or dcraw first.
    static func prepare(_ url: URL, maxPixel: Int, minSide: Int, to folder: URL, png: Bool) throws -> Prepared {
        let exif = EXIF.read(url)
        var source = url
        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        if let converted = try decodable(url, in: folder) {
            source = converted
            scratch = converted
        }
        guard let (width, height) = size(of: source) else { throw ExtractError.unreadable("not an image") }
        // EXIF orientations 5–8 turn the picture a quarter: the size the Mac reports is the turned one.
        let turned = (exif?.orientation ?? 1) >= 5
        let (shownWidth, shownHeight) = turned ? (height, width) : (width, height)
        guard max(shownWidth, shownHeight) >= minSide else { throw ExtractError.tooSmall(shownWidth, shownHeight) }
        let out = folder.appendingPathComponent(UUID().uuidString + (png ? ".png" : ".jpg"))
        var filters = [rotation(exif?.orientation ?? 1),
                       "scale=w='min(\(maxPixel),iw)':h='min(\(maxPixel),ih)':force_original_aspect_ratio=decrease"]
            .compactMap { $0 }
        if png { filters.append("format=rgb24") }
        var arguments = ["-nostdin", "-loglevel", "error", "-y", "-i", source.path,
                         "-vf", filters.joined(separator: ","), "-frames:v", "1"]
        arguments += png ? [] : ["-qscale:v", "3"]   // ≈ the Mac's 0.9 JPEG quality
        arguments.append(out.path)
        do {
            try Tool.run("ffmpeg", arguments)
        } catch {
            throw ExtractError.unreadable("can't decode image (\(error))")
        }
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw ExtractError.unreadable("can't decode image")
        }
        return Prepared(path: out.path, width: shownWidth, height: shownHeight, taken: exif?.taken)
    }

    /// On Linux an image is its own file: OCR reads the path. Formats tesseract can't open are converted first and
    /// the copy is left in the batch's scratch folder, which the indexer deletes.
    static func fullImage(_ url: URL) -> SourceImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if ["png", "jpg", "jpeg", "tif", "tiff", "bmp", "webp", "pnm", "gif"].contains(url.pathExtension.lowercased()) {
            return url
        }
        let folder = url.deletingLastPathComponent()
        if let converted = ((try? decodable(url, in: folder)) ?? nil) { return converted }
        let out = folder.appendingPathComponent(UUID().uuidString + ".png")
        guard (try? Tool.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-y", "-i", url.path, "-frames:v", "1",
                                        out.path])) != nil else { return nil }
        return out
    }

    /// Copies an already-decoded picture (one DigUp itself wrote) to `url`, converting if the format differs.
    static func write(_ image: SourceImage, to url: URL, png: Bool) throws {
        if image.pathExtension.lowercased() == url.pathExtension.lowercased() {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: image, to: url)
            return
        }
        var arguments = ["-nostdin", "-loglevel", "error", "-y", "-i", image.path, "-frames:v", "1"]
        arguments += png ? [] : ["-qscale:v", "3"]
        arguments.append(url.path)
        do { try Tool.run("ffmpeg", arguments) } catch { throw ExtractError.unreadable("can't encode image") }
    }

    /// A copy ffmpeg can read, for the formats it can't: HEIC/HEIF/AVIF through heif-convert, camera RAW through
    /// dcraw. Nil when ffmpeg handles the file itself.
    static func decodable(_ url: URL, in folder: URL) throws -> URL? {
        let ext = url.pathExtension.lowercased()
        let raw: Set<String> = ["cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef",
                                "ptx", "3fr", "fff", "iiq", "mos", "mrw", "srw", "x3f", "erf", "kdc", "dcr", "mef",
                                "dng"]
        let out = folder.appendingPathComponent(UUID().uuidString + ".ppm")
        if ["heic", "heif", "avif"].contains(ext) {
            let png = folder.appendingPathComponent(UUID().uuidString + ".png")
            guard Tool.find("heif-convert") != nil else {
                throw ExtractError.unreadable("no heif-convert for \(ext) (install libheif-examples)")
            }
            try Tool.run("heif-convert", ["-q", "95", url.path, png.path])
            return png
        }
        if raw.contains(ext) {
            guard Tool.find("dcraw") != nil else {
                throw ExtractError.unreadable("no dcraw for \(ext) (install dcraw)")
            }
            let ppm = try Tool.run("dcraw", ["-c", "-w", "-q", "0", url.path])
            try ppm.write(to: out)
            return out
        }
        return nil
    }

    /// The picture's pixel size, from ffprobe.
    static func size(of url: URL) -> (Int, Int)? {
        guard let line = try? Tool.text("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                    "stream=width,height", "-of", "csv=p=0:s=x", url.path])
        else { return nil }
        let parts = line.split(separator: "\n").first?.split(separator: "x").compactMap { Int($0) } ?? []
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return (parts[0], parts[1])
    }

    /// The ffmpeg filter that puts an EXIF-rotated picture the right way up (what ImageIO's
    /// `kCGImageSourceCreateThumbnailWithTransform` does).
    private static func rotation(_ orientation: Int) -> String? {
        switch orientation {
        case 2: "hflip"
        case 3: "hflip,vflip"
        case 4: "vflip"
        case 5: "transpose=0"
        case 6: "transpose=1"
        case 7: "transpose=3"
        case 8: "transpose=2"
        default: nil
        }
    }
}

/// Just enough EXIF to match what ImageIO hands back: when the picture was taken, and which way up it is.
/// JPEG (APP1) and TIFF/DNG only; other containers keep EXIF elsewhere and report nothing, as a Mac does for a
/// picture without it.
enum EXIF {
    struct Values { var taken: String?; var orientation = 1 }

    static func read(_ url: URL) -> Values? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256 << 10), head.count > 8 else { return nil }
        let bytes = [UInt8](head)
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return jpeg(bytes) }
        if bytes[0] == 0x49 || bytes[0] == 0x4D { return tiff(bytes, from: 0) }
        return nil
    }

    /// Walks the JPEG markers to APP1 ("Exif\0\0") and reads the TIFF block inside it.
    private static func jpeg(_ bytes: [UInt8]) -> Values? {
        var index = 2
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { index += 2; continue }
            if marker == 0xDA { return nil }   // the picture itself starts here
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let body = index + 4
            if marker == 0xE1, body + 6 <= bytes.count,
               Array(bytes[body..<(body + 6)]) == Array("Exif\0\0".utf8) {
                return tiff(bytes, from: body + 6)
            }
            index += 2 + length
        }
        return nil
    }

    /// The TIFF header and IFD0 (plus the Exif sub-IFD) at `start`.
    private static func tiff(_ bytes: [UInt8], from start: Int) -> Values? {
        guard start + 8 <= bytes.count else { return nil }
        let big = bytes[start] == 0x4D
        func word(_ at: Int) -> Int? {
            guard at + 2 <= bytes.count else { return nil }
            return big ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : Int(bytes[at + 1]) << 8 | Int(bytes[at])
        }
        func long(_ at: Int) -> Int? {
            guard at + 4 <= bytes.count else { return nil }
            let order = big ? [0, 1, 2, 3] : [3, 2, 1, 0]
            return order.reduce(0) { $0 << 8 | Int(bytes[at + $1]) }
        }
        guard word(start + 2) == 42, let first = long(start + 4) else { return nil }
        var values = Values()
        func readIFD(_ offset: Int, depth: Int) {
            guard depth < 3, let count = word(start + offset), count < 1024 else { return }
            for entry in 0..<count {
                let at = start + offset + 2 + entry * 12
                guard let tag = word(at), let value = long(at + 8) else { return }
                switch tag {
                case 0x0112: values.orientation = word(at + 8) ?? 1
                case 0x8769: readIFD(value, depth: depth + 1)                     // the Exif sub-IFD
                case 0x9003, 0x0132:                                              // DateTimeOriginal, DateTime
                    guard let length = long(at + 4), length > 1 else { break }
                    let from = start + value
                    guard from + length <= bytes.count else { break }
                    let text = String(decoding: bytes[from..<(from + length - 1)], as: UTF8.self)
                    if tag == 0x9003 || values.taken == nil { values.taken = text }
                default: break
                }
            }
        }
        readIFD(first, depth: 0)
        return values
    }
}

extension OCR {
    /// tesseract, where the Mac uses Vision. The languages are whatever is installed; English, Bengali and Arabic
    /// are what DigUp's evals need. Page segmentation 3 (automatic) matches Vision's behaviour on screenshots best.
    static func text(in image: SourceImage) -> String {
        guard Tool.find("tesseract") != nil else { return "" }
        let text = try? Tool.text("tesseract", [image.path, "stdout", "-l", languages, "--psm", "3"])
        return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The installed languages, best first ("eng+ben+ara"). `osd` is orientation data, not a language.
    static let languages: String = {
        let listed = (try? Tool.text("tesseract", ["--list-langs"])) ?? ""
        let available = Set(listed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let wanted = ["eng", "ben", "ara"].filter(available.contains)
        return wanted.isEmpty ? "eng" : wanted.joined(separator: "+")
    }()

    /// tesseract reads Arabic when its `ara` data is installed.
    static let readsArabic: Bool = languages.contains("ara")
}

extension PDFExtractor {
    /// The same decisions as the PDFKit version: a page with real text becomes text, a scan or a slide is rendered,
    /// and a text layer that came out garbled is replaced (by OCR where letters were lost, by the rendered page where
    /// the words are in glyph order). pdftotext reads in reading order, pdftoppm renders.
    static func pages(of url: URL, range: (Int) -> Range<Int>, minText: Int, renderPixels: Int, to folder: URL)
        throws -> (pages: [Page], total: Int, title: String?) {
        let info = try document(url)
        var pages: [Page] = []
        for index in range(info.pages).clamped(to: 0..<info.pages) {
            var text = (try? pageText(url, page: index + 1))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var garbled: String?
            switch PageTextProblem.check(text) {
            case .lostLetters:
                if OCR.readsArabic, let image = render(url, page: index + 1, pixels: 2000, to: folder) {
                    let read = OCR.text(in: image).trimmingCharacters(in: .whitespacesAndNewlines)
                    try? FileManager.default.removeItem(at: image)
                    if read.count >= minText, PageTextProblem.check(read) == nil,
                       read.unicodeScalars.contains(where: { Script.arabic.contains($0.value) }) {
                        pages.append(Page(number: index + 1, text: read, imagePath: nil, ocr: true))
                        continue
                    }
                }
                if text.count >= minText {
                    pages.append(Page(number: index + 1, text: text, imagePath: nil))
                    continue
                }
            case .glyphOrder:
                (text, garbled) = ("", text)
            case nil:
                if text.count >= minText {
                    pages.append(Page(number: index + 1, text: text, imagePath: nil))
                    continue
                }
            }
            guard let image = render(url, page: index + 1, pixels: renderPixels, to: folder) else { continue }
            pages.append(Page(number: index + 1, text: text, imagePath: image.path, garbled: garbled))
        }
        return (pages, info.pages, info.title)
    }

    /// How many pages, and the title: pdfinfo. A file needing a password is `ExtractError.locked`.
    static func document(_ url: URL) throws -> (pages: Int, title: String?) {
        let text: String
        do {
            text = try Tool.text("pdfinfo", ["-enc", "UTF-8", url.path])
        } catch let failure as Tool.Failure {
            if failure.message.lowercased().contains("password") { throw ExtractError.locked }
            throw ExtractError.unreadable("can't open PDF")
        }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[line.startIndex..<colon])] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let pages = fields["Pages"].flatMap(Int.init), pages > 0 else {
            throw ExtractError.unreadable("can't open PDF")
        }
        let title = fields["Title"]
        return (pages, (title?.isEmpty ?? true) ? nil : title)
    }

    /// One page's text, in reading order (what `PDFPage.string` gives).
    static func pageText(_ url: URL, page: Int) throws -> String {
        String(decoding: try Tool.run("pdftotext", ["-f", "\(page)", "-l", "\(page)", "-enc", "UTF-8", "-nopgbrk",
                                                    url.path, "-"]), as: UTF8.self)
    }

    /// The page as a picture, fitted into a square of `pixels`.
    static func render(_ url: URL, page: Int, pixels: Int, to folder: URL) -> URL? {
        let stem = folder.appendingPathComponent(UUID().uuidString)
        guard (try? Tool.run("pdftoppm", ["-f", "\(page)", "-l", "\(page)", "-png", "-scale-to", "\(pixels)",
                                          url.path, stem.path])) != nil else { return nil }
        // pdftoppm appends the page number, with as many digits as the document has pages.
        let folderName = stem.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              let made = names.first(where: { $0.hasPrefix(folderName + "-") && $0.hasSuffix(".png") })
        else { return nil }
        return folder.appendingPathComponent(made)
    }
}

extension DocExtractor {
    /// rtf/docx/odt through pandoc, and the old binary .doc through catdoc: what the Cocoa text system reads on a Mac.
    static func convert(_ url: URL, _ ext: String) throws -> String {
        if ext == "doc" {
            // pandoc has no reader for Word 97's binary format.
            guard Tool.find("catdoc") != nil else { throw ExtractError.unreadable("no catdoc for .doc") }
            return try Tool.text("catdoc", ["-d", "utf-8", "-a", url.path])
        }
        let from = ext == "rtf" ? "rtf" : ext == "odt" ? "odt" : "docx"
        do {
            return try Tool.text("pandoc", ["--quiet", "-f", from, "-t", "plain", "--wrap=none", url.path])
        } catch let failure as Tool.Failure {
            throw ExtractError.unreadable("\(failure)")
        }
    }
}
#endif
