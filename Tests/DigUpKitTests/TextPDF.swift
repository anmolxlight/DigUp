#if !canImport(AppKit)
import Foundation

/// A plain text PDF, where the tests use Quartz on a Mac: one page a string, 12 pt Helvetica on US Letter, which is
/// what `CGContext(url:mediaBox:)` plus `NSString.draw` produce there. pdftotext reads it in reading order, so the
/// pages come back as the tests expect.
enum TextPDF {
    static func write(_ pages: [String], to url: URL) throws {
        var objects: [Data] = []           // 1-based; objects[i] is object i + 1
        func add(_ body: String) -> Int { objects.append(Data(body.utf8)); return objects.count }
        func add(_ body: Data) -> Int { objects.append(body); return objects.count }

        let catalog = 1, pageList = 2, font = 3
        objects = [Data(), Data(), Data()]
        objects[font - 1] = Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8)

        var pageObjects: [Int] = []
        for text in pages {
            let stream = content(text)
            let contents = add("<< /Length \(stream.count) >>\nstream\n" + stream + "\nendstream")
            let page = add("""
                << /Type /Page /Parent \(pageList) 0 R /MediaBox [0 0 612 792] \
                /Resources << /Font << /F1 \(font) 0 R >> >> /Contents \(contents) 0 R >>
                """)
            pageObjects.append(page)
        }
        objects[pageList - 1] = Data("""
            << /Type /Pages /Count \(pageObjects.count) /Kids [\(pageObjects.map { "\($0) 0 R" }.joined(separator: " "))] >>
            """.utf8)
        objects[catalog - 1] = Data("<< /Type /Catalog /Pages \(pageList) 0 R >>".utf8)

        var file = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(file.count)
            file.append(Data("\(index + 1) 0 obj\n".utf8))
            file.append(body)
            file.append(Data("\nendobj\n".utf8))
        }
        let start = file.count
        file.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { file.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        file.append(Data("""
            trailer
            << /Size \(objects.count + 1) /Root \(catalog) 0 R >>
            startxref
            \(start)
            %%EOF

            """.utf8))
        try file.write(to: url)
    }

    /// The page's content stream: the text wrapped into a 492 pt column, 14 pt apart, starting 720 pt up.
    private static func content(_ text: String) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            // Helvetica at 12 pt averages ~6 pt a character, so 80 characters fill the column.
            if line.count + word.count + 1 > 80 { lines.append(line); line = "" }
            line += line.isEmpty ? String(word) : " " + word
        }
        if !line.isEmpty { lines.append(line) }
        let drawn = lines.prefix(47).map { "(\(escape($0))) Tj T*" }.joined(separator: "\n")
        return "BT\n/F1 12 Tf\n14 TL\n60 720 Td\n\(drawn)\nET"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }
}
#endif
