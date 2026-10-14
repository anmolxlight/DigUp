import CGtk
import DigUpKit
import Foundation

// What the panel, the window and Quick Look share: a result's row, its preview (picture, frame or page, passage,
// lines of code, an audio moment), why it matched, and playing a recording from its moment.

/// A result in a list: thumbnail, name with the page or moment, and the matched words (or the folder).
func resultRow(_ row: ResultRow) -> Widget {
    let thumb = vbox()
    size(thumb, width: 40, height: 40)
    append(thumb, icon(row.kind.iconName, size: 32))
    if row.kind != .code {
        Pictures.thumbnail(row, side: 80) { path in
            guard let path, let image = picture(path) else { return }
            clear(thumb)
            gtk_widget_set_vexpand(image, 1)
            append(thumb, image)
        }
    }
    let name = label(row.name, "row-title", ellipsize: true)
    let top = hbox(spacing: 6, children: [name])
    if let place = row.place { append(top, label(place, "badge")) }
    let second: Widget
    if let excerpt = row.excerpt, row.matchedWords, row.kind != .code {
        second = label("", "dim", ellipsize: true)
        gtk_label_set_ellipsize(cast(second), PANGO_ELLIPSIZE_END)
        setMarkup(second, boldMarked(excerpt))
    } else {
        second = label(row.folder, "dim", ellipsize: true)
        gtk_label_set_ellipsize(cast(second), PANGO_ELLIPSIZE_START)
    }
    let texts = vbox(spacing: 2, children: [top, second])
    gtk_widget_set_hexpand(texts, 1)
    let widget = hbox(spacing: 10, "result-row", children: [thumb, texts])
    setTooltip(widget, "\(row.kind.title), \(row.name): \(row.reason)")
    dragsFile(widget) { row.url.path }
    return widget
}

/// Matched words, which full-text search marks with « », in bold.
func boldMarked(_ text: String) -> String {
    escaped(text).replacingOccurrences(of: "«", with: "<b>").replacingOccurrences(of: "»", with: "</b>")
}

/// `text` with every match of `words` marked as a search marks them.
func highlightedMarkup(_ text: String, words: Set<String>) -> String {
    var ranges: [Range<String.Index>] = []
    for word in words where word.count >= 2 { ranges += SearchText.matches(of: word, in: text) }
    ranges.sort { $0.lowerBound < $1.lowerBound }
    var result = "", at = text.startIndex
    for range in ranges where range.lowerBound >= at {
        result += escaped(String(text[at..<range.lowerBound]))
        result += "<span background=\"#ffdb33\" foreground=\"black\">" + escaped(String(text[range])) + "</span>"
        at = range.upperBound
    }
    return result + escaped(String(text[at...]))
}

/// The selected result, big: its picture (or the frame or page that matched, a passage, lines of code), what it is,
/// why it's here, and Open / Show in Files.
func previewPane(_ row: ResultRow, side: Int, engine: Engine, open: @escaping @MainActor () -> Void,
                 reveal: @escaping @MainActor () -> Void) -> Widget {
    let pane = vbox(spacing: 10)
    let top = previewPicture(row, side: side, engine: engine, open: open)
    size(top, height: Int32(side * 9 / 16))
    gtk_widget_set_vexpand(top, 1)
    append(pane, top)
    let name = label(row.name, "title-3", ellipsize: true)
    gtk_label_set_selectable(cast(name), 1)
    let folder = gtk_button_new_with_label(row.folder)!
    gtk_widget_add_css_class(folder, "flat")
    gtk_widget_set_halign(folder, GTK_ALIGN_START)
    setTooltip(folder, "Show in Files")
    on(folder, "clicked", reveal)
    append(pane, vbox(spacing: 2, children: [name, folder, label(row.details, "dim", wrap: true)]))
    let why = hbox(spacing: 6, children: [icon(row.matchedMeaning ? "system-search-symbolic" : "format-text-bold-symbolic",
                                               size: 14), label(row.reason, "dim")])
    append(pane, why)
    if let excerpt = row.excerpt, row.kind != .code {
        let words = label("", "dim", wrap: true)
        setMarkup(words, boldMarked(excerpt))
        gtk_label_set_selectable(cast(words), 1)
        gtk_label_set_lines(cast(words), 3)
        gtk_label_set_ellipsize(cast(words), PANGO_ELLIPSIZE_END)
        append(pane, words)
    }
    let openButton = button(row.openTitle, "suggested-action", action: open)
    append(pane, hbox(spacing: 8, children: [openButton, button("Show in Files", action: reveal)]))
    return pane
}

/// The picture part of the preview. Audio has no picture, so it gets its moment and a player instead; a video's
/// frame has ▶, which plays it here from the moment that matched.
private func previewPicture(_ row: ResultRow, side: Int, engine: Engine, open: @escaping @MainActor () -> Void)
    -> Widget {
    if row.kind == .audio { return audioMoment(row) }
    if row.kind == .code || row.segment == .chunk { return passage(row, engine: engine, open: open) }
    let holder = vbox()
    let fallback = icon(row.kind.iconName, size: 96)
    gtk_widget_set_vexpand(fallback, 1)
    append(holder, fallback)
    onClick(holder) { count in if count == 2 { open() } }
    Pictures.preview(row, side: side) { path in
        guard let path, let image = picture(path) else { return }
        clear(holder)
        gtk_widget_set_vexpand(image, 1)
        guard row.moment != nil else { return append(holder, image) }
        // ▶ over the frame: plays it here, from the moment.
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(cast(overlay), image)
        let play = gtk_button_new_from_icon_name("media-playback-start-symbolic")!
        gtk_widget_add_css_class(play, "osd")
        gtk_widget_add_css_class(play, "circular")
        gtk_widget_set_halign(play, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(play, GTK_ALIGN_CENTER)
        setTooltip(play, "Play from \(ResultRow.clock(row.moment ?? 0))")
        gtk_overlay_add_overlay(cast(overlay), play)
        if let place = row.place {
            let badge = label(place, "badge")
            gtk_widget_set_halign(badge, GTK_ALIGN_START)
            gtk_widget_set_valign(badge, GTK_ALIGN_END)
            margins(badge, 8)
            gtk_overlay_add_overlay(cast(overlay), badge)
        }
        on(play, "clicked") {
            clear(holder)
            append(holder, PreviewPlayback.shared.video(row))
        }
        gtk_widget_set_vexpand(overlay, 1)
        append(holder, overlay)
    }
    return holder
}

/// An audio hit: the stretch that matched on the file's timeline, and a player that starts there.
private func audioMoment(_ row: ResultRow) -> Widget {
    let start = row.loc ?? 0
    let end = row.locEnd ?? start + 30
    let total = row.duration.map { " of " + ResultRow.clock($0) } ?? ""
    let widget = vbox(spacing: 10, "card-row", children: [
        icon("audio-x-generic", size: 48),
        label(ResultRow.clock(start) + " – " + ResultRow.clock(end) + total, "dim", xalign: 0.5),
    ])
    if let duration = row.duration, duration > 0 {
        let bar = gtk_level_bar_new_for_interval(0, duration)!
        gtk_level_bar_set_value(cast(bar), end)
        setTooltip(bar, "The stretch that matched")
        append(widget, bar)
    }
    append(widget, PreviewPlayback.shared.controls(row))
    gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
    return widget
}

/// The part of a document that matched (or the lines of code, numbered as in the file, with the line it opens at
/// lit), with the query's words marked.
private func passage(_ row: ResultRow, engine: Engine, open: @escaping @MainActor () -> Void) -> Widget {
    let text = label("", wrap: row.kind != .code)
    gtk_label_set_selectable(cast(text), 1)
    gtk_label_set_yalign(cast(text), 0)
    let card = vbox(row.kind == .code ? "code-card" : "passage", children: [text])
    let words = Set((row.foundWords + row.terms).filter { $0.count >= 2 })
    let fill = { (source: String) in
        setMarkup(text, row.kind == .code ? codeMarkup(source, row: row, words: words)
                                          : passageMarkup(source, words: words))
        if Passage.isRightToLeft(source) { gtk_label_set_xalign(cast(text), 1) }
    }
    fill(row.excerpt?.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "") ?? "")
    Task {
        if let full = await engine.text(ofSegment: row.segmentID, code: row.kind == .code) { fill(full) }
    }
    let place = row.kind == .code ? row.span : row.loc.flatMap { part in
        row.info["chunks"].flatMap(Int.init).flatMap { $0 > 1 ? "Part \(Int(part)) of \($0)" : nil }
    }
    let overlay = gtk_overlay_new()!
    gtk_overlay_set_child(cast(overlay), scrolled(card, horizontal: row.kind == .code))
    if let place {
        let badge = label(place, "badge")
        gtk_widget_set_halign(badge, GTK_ALIGN_END)
        gtk_widget_set_valign(badge, GTK_ALIGN_END)
        margins(badge, 8)
        gtk_overlay_add_overlay(cast(overlay), badge)
    }
    onClick(overlay) { count in if count == 2 { open() } }
    return overlay
}

enum Passage {
    /// Arabic or Hebrew text reads from the right.
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            return (0x0590...0x08FF).contains(scalar.value) || (0xFB1D...0xFEFC).contains(scalar.value)
        }
        return false
    }
}

/// Up to ~900 characters from just before the first marked word, as the Mac's preview shows a passage.
private func passageMarkup(_ source: String, words: Set<String>) -> String {
    let first = words.compactMap { SearchText.matches(of: $0, in: source).first?.lowerBound }.min()
    var start = source.startIndex
    if let first, source.distance(from: source.startIndex, to: first) > 200 {
        start = source.index(first, offsetBy: -160)
        while start < first, !source[start].isWhitespace { start = source.index(after: start) }
    }
    let window = String(source[start...].prefix(900))
    let lead = start > source.startIndex ? "…" : ""
    let tail = source.distance(from: start, to: source.endIndex) > 900 ? "…" : ""
    return highlightedMarkup(lead + window + tail, words: words)
}

/// The stretch's lines, numbered as in the file, from a couple above the line it opens at.
private func codeMarkup(_ source: String, row: ResultRow, words: Set<String>) -> String {
    let lines = source.components(separatedBy: "\n")
    let firstNumber = row.segment == .lines ? Int(row.loc ?? 1) : 1
    let focus = row.segment == .lines ? row.codeLine - firstNumber : -1
    let skip = focus > 3 ? focus - 2 : 0
    let width = String(firstNumber + lines.count).count
    return lines.enumerated().dropFirst(skip).prefix(80).map { offset, line in
        let number = String(firstNumber + offset)
        let padded = String(repeating: " ", count: max(0, width - number.count)) + number
        let body = "<span alpha=\"45%\">\(padded)</span>  " + highlightedMarkup(line, words: words)
        return offset == focus ? "<span background=\"#f2a22a40\">\(body)</span>" : body
    }.joined(separator: "\n")
}

/// "code:" and nothing yet (what to type), or code search that's off (how to turn it on).
func codeHint(off: Bool, choose: @escaping @MainActor () -> Void, example: @escaping @MainActor (String) -> Void)
    -> Widget {
    let widget = vbox(spacing: 10, children: [icon("text-x-script", size: 40)])
    if off {
        append(widget, label("Code search is off", "title-3", xalign: 0.5),
               label("DigUp can find code by what it does, in the folders you pick. Code gets an index of its own and "
                     + "never shows up in other searches.", "dim", wrap: true, xalign: 0.5),
               button("Choose Code Folders…", action: choose))
    } else {
        append(widget, label("Search your code", "title-3", xalign: 0.5),
               label("Say what the code does, or type a name that's in it.", "dim", xalign: 0.5))
        for text in ["code: retry a request with backoff", "code: where the settings are saved",
                     "code: parse the command line options"] {
            let chip = button(text, "chip", "flat") { example(text) }
            gtk_widget_set_halign(chip, GTK_ALIGN_CENTER)
            append(widget, chip)
        }
    }
    gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
    gtk_widget_set_vexpand(widget, 1)
    margins(widget, 24)
    return widget
}

/// Plays the selected recording in the preview, from the moment that matched (GTK's media stream, GStreamer under it).
/// One at a time; it stops when the selection moves, or the panel or window closes.
final class PreviewPlayback {
    static let shared = PreviewPlayback()
    private var stream: UnsafeMutablePointer<GtkMediaStream>?
    /// Debug runs keep quiet.
    var muted = false

    /// A media file that seeks to the row's moment once it's ready, and plays.
    private func start(_ row: ResultRow, play: Bool) -> UnsafeMutablePointer<GtkMediaStream> {
        stop()
        let file = gtk_media_file_new_for_filename(row.url.path)!
        let stream: UnsafeMutablePointer<GtkMediaStream> = cast(file)
        gtk_media_stream_set_muted(stream, muted ? 1 : 0)
        let moment = Int64((row.moment ?? 0) * 1_000_000)
        on(stream, "notify::prepared") { _ in
            guard gtk_media_stream_is_prepared(stream) != 0 else { return }
            if moment > 0, gtk_media_stream_is_seekable(stream) != 0 { gtk_media_stream_seek(stream, Int(moment)) }
            if play { gtk_media_stream_play(stream) }
        }
        self.stream = stream
        log("preview: \(play ? "playing" : "ready to play") \(row.name) from \(ResultRow.clock(row.moment ?? 0))")
        return stream
    }

    /// A video, playing in the pane from its moment, with GTK's controls.
    func video(_ row: ResultRow) -> Widget {
        let video = gtk_video_new()!
        gtk_video_set_media_stream(cast(video), start(row, play: true))
        gtk_widget_set_vexpand(video, 1)
        return video
    }

    /// Play/pause and a timeline for an audio file, ready at its moment.
    func controls(_ row: ResultRow) -> Widget {
        gtk_media_controls_new(start(row, play: false))!
    }

    func stop() {
        guard let stream else { return }
        gtk_media_stream_pause(stream)
        g_object_unref(stream)
        self.stream = nil
    }
}

/// Quick Look's stand-in (Space): the selected result's preview, big, in a window of its own. Space or Esc closes it.
final class QuickLook {
    static let shared = QuickLook()
    private var window: Widget?
    private var showing: String?

    var isVisible: Bool { window.map { gtk_widget_get_visible($0) != 0 } ?? false }

    func toggle(_ row: ResultRow?, engine: Engine, open: @escaping @MainActor () -> Void,
                reveal: @escaping @MainActor () -> Void) {
        if isVisible { return close() }
        show(row, engine: engine, open: open, reveal: reveal)
    }

    /// Shows `row` (or follows the selection while it's open).
    func show(_ row: ResultRow?, engine: Engine, open: @escaping @MainActor () -> Void,
              reveal: @escaping @MainActor () -> Void) {
        guard let row else { return close() }
        let window = self.window ?? makeWindow()
        guard showing != row.previewKey || !isVisible else { return }
        showing = row.previewKey
        gtk_window_set_title(cast(window), row.name)
        let pane = previewPane(row, side: 860, engine: engine, open: open, reveal: reveal)
        margins(pane, 16)
        gtk_window_set_child(cast(window), pane)
        present(window)
        log("quick look: \(row.name)\(row.jump.map { " at \($0)" } ?? "")")
    }

    func close() {
        guard let window else { return }
        gtk_widget_set_visible(window, 0)
        showing = nil
        PreviewPlayback.shared.stop()
    }

    private func makeWindow() -> Widget {
        let window = DigUpLinux.window("Quick Look", width: 900, height: 760)
        onClose(window) { [weak self] in
            self?.close()
            return true
        }
        onKey(window) { [weak self] key, _ in
            guard key == UInt32(GDK_KEY_space) || key == UInt32(GDK_KEY_Escape) else { return false }
            self?.close()
            return true
        }
        self.window = window
        return window
    }
}

extension ResultRow {
    /// Where opening or Quick Look goes when it isn't the start: a page after the first, or a moment ("p. 3", "0:06").
    var jump: String? {
        if let page, page > 1 { return place }
        if let moment, moment >= 1 { return place }
        return nil
    }
}
