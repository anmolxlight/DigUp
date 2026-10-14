import CGtk
import DigUpKit
import Foundation

enum SearchPhase: Equatable {
    case empty       // nothing typed
    case words       // keyword results, meaning results on the way
    case meaning     // words + meaning: final
    case wordsOnly   // final, but there's no meaning search (the model is downloading, or the encoder failed)
    case codeHint    // "code:" and nothing yet: what to type
    case codeOff     // "code:" without code folders: how to turn code search on
}

/// The hotkey panel, as on a Mac: type, see results grouped by kind with the selected one previewed big on the right,
/// and open / reveal / Quick Look / copy / drag them out.
///
/// Every keystroke shows keyword results at once (file names, OCR and document text, the last word as a prefix).
/// After a short pause in typing the query is embedded and the full hybrid results replace them. Results far weaker
/// than the best one are folded under "N weaker matches".
final class SearchPanelController {
    static let width: Int32 = 780
    static let listWidth: Int32 = 330
    static let bodyHeight: Int32 = 424
    static let rowsPerGroup = 6
    static let typingPause: Duration = .milliseconds(120)
    /// The selectable row that folds and unfolds the weaker matches.
    static let weakerToggle = "\u{0}weaker"

    private(set) var query = ""
    private(set) var results = ResultSet.empty
    private(set) var showWeaker = false
    private(set) var selection: String?
    private(set) var phase = SearchPhase.empty
    /// The query is a search of code ("code: …"): the code index, and nothing else.
    private(set) var isCode = false
    private(set) var note: String?

    let model: AppModel
    private let engine: Engine
    private unowned let app: AppController
    private var generation = 0
    /// The generation whose final (meaning) results are showing; late keyword results must not replace them.
    private var finalGeneration = -1
    private var meaningTask: Task<Void, Never>?
    /// True once ↑/↓ moved the selection since the last edit: then Space previews instead of typing a space.
    private var navigated = false
    private var typedAt = Date()
    private var noteTask: Task<Void, Never>?
    private var wasActive = false
    /// Called when the final results for the current query are on screen (debug hooks use it).
    var onFinalResults: (() -> Void)?

    // The widgets
    private var window: Widget?
    private var field: Widget!
    private var badge: Widget!
    private var body: Widget!
    private var list: Widget!
    private var listScroll: Widget!
    private var listArea: Widget!
    private var preview: Widget!
    private var status: Widget!
    private var keys: Widget!
    private var rowWidgets: [String: Widget] = [:]
    /// Selecting a row in code moves GTK's selection too; that must not count as a click.
    private var selecting = false

    init(app: AppController) {
        self.app = app
        model = app.model
        engine = app.engine
    }

    var isVisible: Bool { window.map { gtk_widget_get_visible($0) != 0 } ?? false }
    /// The selectable rows in order: strong results group by group, the fold, then the weaker ones if unfolded.
    var rowIDs: [String] {
        results.groups.flatMap { $0.rows.map(\.id) }
            + (results.weaker.isEmpty ? [] : [Self.weakerToggle])
            + (showWeaker ? results.weaker.map(\.id) : [])
    }
    var rows: [ResultRow] { results.groups.flatMap(\.rows) + (showWeaker ? results.weaker : []) }
    var selectedRow: ResultRow? { rows.first { $0.id == selection } }

    // MARK: Showing

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let started = Date()
        engine.prewarm()
        let window = self.window ?? makeWindow()
        wasActive = false
        present(window)
        gtk_widget_grab_focus(field)
        gtk_editable_select_region(cast(field), 0, -1)   // like Spotlight: the last query, selected
        DispatchQueue.main.async { log("panel: shown in \(ms(since: started))") }
    }

    func hide() {
        QuickLook.shared.close()
        if let window { gtk_widget_set_visible(window, 0) }
        PreviewPlayback.shared.stop()
        app.windowClosed()
    }

    // MARK: Searching

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        if entryText(field) != text { gtk_editable_set_text(cast(field), text) }
        queryChanged()
    }

    private func queryChanged() {
        generation += 1
        let current = generation
        typedAt = Date()
        navigated = false
        meaningTask?.cancel()
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeText = CodeQuery.text(of: typed)
        isCode = codeText != nil
        let code = isCode
        let text = codeText ?? typed
        guard !typed.isEmpty else {
            results = .empty
            selection = nil
            phase = .empty
            return render()
        }
        // "code:" alone, or without code folders: what to do instead of results.
        if code, !model.hasCode || text.isEmpty {
            results = .empty
            selection = nil
            phase = model.hasCode ? .codeHint : .codeOff
            return render()
        }
        // Words now. The last word is probably half-typed, so it matches as a prefix.
        Task {
            let started = Date()
            let hits = await engine.search(text, vector: nil, prefixLast: true, code: code)
            guard current == generation, finalGeneration != current else { return }
            show(hits, query: text, phase: .words)
            log("search \"\(typed)\": words \(hits.count) hits in \(ms(since: started))")
        }
        // Meaning results show once typing pauses, but they're computed now (embedding, then search), so they're
        // ready by then: the pause is the whole wait.
        engine.embedAhead(text, code: code)
        let showAt = ContinuousClock.now + Self.typingPause
        meaningTask = Task {
            let embedStarted = Date()
            let vector = await engine.embedQuery(text, code: code)
            guard !Task.isCancelled, current == generation else { return }
            let searchStarted = Date()
            let hits = await engine.search(text, vector: vector, prefixLast: false, code: code)
            let searched = Date()
            try? await Task.sleep(until: showAt, tolerance: .milliseconds(1), clock: .continuous)
            guard !Task.isCancelled, current == generation else { return }
            finalGeneration = current
            show(hits, query: text, phase: vector == nil ? .wordsOnly : .meaning)
            log("search \"\(typed)\": \(vector == nil ? "words only" : "meaning") \(hits.count) hits "
                + "(\(results.strongRows.count) strong) · embed \(ms(since: embedStarted, until: searchStarted)) · "
                + "search \(ms(since: searchStarted, until: searched)) · shown \(ms(since: typedAt)) after "
                + "the last keystroke")
            onFinalResults?()
        }
    }

    private func show(_ hits: [SearchHit], query: String, phase: SearchPhase) {
        // Code is one group: it gets the room of all of them.
        results = ResultSet(hits, query: query, rowsPerGroup: isCode ? Self.rowsPerGroup * 3 : Self.rowsPerGroup)
        if !navigated { showWeaker = false }
        // Follow the top hit until you pick something with the arrow keys.
        if !navigated || !rowIDs.contains(where: { $0 == selection }) {
            selection = rowIDs.first
        }
        self.phase = phase
        render()
    }

    func toggleWeaker() {
        showWeaker.toggle()
        selection = Self.weakerToggle
        render()
    }

    // MARK: Keys

    /// True when the key was handled here (it then doesn't reach the search field).
    private func handle(_ key: UInt32, _ state: GdkModifierType) -> Bool {
        let ctrl = state.rawValue & GDK_CONTROL_MASK.rawValue != 0
        let plain = state.rawValue & (GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SHIFT_MASK.rawValue) == 0
        switch Int32(key) {
        case GDK_KEY_Escape:
            if QuickLook.shared.isVisible { QuickLook.shared.close() } else { hide() }
            return true
        case GDK_KEY_Down, GDK_KEY_Up:
            guard plain else { return false }
            moveSelection(by: Int32(key) == GDK_KEY_Down ? 1 : -1)
            navigated = true
            return true
        case GDK_KEY_Return, GDK_KEY_KP_Enter:
            if selection == Self.weakerToggle, plain {
                toggleWeaker()
            } else if ctrl {
                revealSelected()
            } else if plain {
                openSelected()
            } else {
                return false
            }
            return true
        case GDK_KEY_space where plain && (navigated || QuickLook.shared.isVisible) && selection != nil:
            if selection == Self.weakerToggle { toggleWeaker() } else { toggleQuickLook() }
            return true
        case GDK_KEY_y where ctrl:
            toggleQuickLook()
            return true
        case GDK_KEY_o where ctrl:   // the same search in the window, for a bigger look
            openInWindow()
            return true
        case GDK_KEY_c where ctrl:
            // Ctrl+C copies the selected file, except right after you selected some of the query text.
            var start: Int32 = 0, end: Int32 = 0
            let textSelected = gtk_editable_get_selection_bounds(cast(field), &start, &end) != 0 && start != end
            if textSelected, !navigated { return false }
            copySelected()
            return true
        default:
            return false
        }
    }

    func moveSelection(by step: Int) {
        let ids = rowIDs
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        selection = ids[max(0, min(ids.count - 1, index + step))]
        renderSelection()
    }

    func select(_ id: String) {
        selection = id
        navigated = true
        renderSelection()
    }

    // MARK: Actions

    /// ↩: the file in its app, at the page or moment that matched when the app can be told where.
    func openSelected() {
        guard let row = selectedRow else { return }
        engine.open(row)
        hide()
    }

    func revealSelected() {
        guard let row = selectedRow else { return }
        Desktop.reveal(row.url)
        hide()
    }

    func copySelected() {
        guard let row = selectedRow else { return }
        flash(Desktop.copy(row.url) ? "Copied \(row.name)" : "Copying needs xclip (X11) or wl-copy (Wayland)")
    }

    /// The search window, with this query (and only one kind, if given): for a bigger look.
    func openInWindow(_ kind: ResultGroupKind? = nil) {
        let text = query
        hide()
        app.showSearchWindow(query: text, kind: kind)
    }

    private func flash(_ text: String) {
        note = text
        renderFooter()
        noteTask?.cancel()
        noteTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            note = nil
            renderFooter()
        }
    }

    func toggleQuickLook() {
        QuickLook.shared.toggle(selectedRow, engine: engine, open: { [weak self] in self?.openSelected() },
                                reveal: { [weak self] in self?.revealSelected() })
    }

    // MARK: The window

    private func makeWindow() -> Widget {
        let window = DigUpLinux.window("DigUp", width: Self.width, height: -1)
        gtk_window_set_decorated(cast(window), 0)
        gtk_window_set_resizable(cast(window), 0)   // it takes its content's size: the field, or the field and results
        gtk_widget_add_css_class(window, "panel")
        onClose(window) { [weak self] in
            self?.hide()
            return true
        }
        field = gtk_entry_new()!
        gtk_entry_set_placeholder_text(cast(field), "Search your files")
        gtk_widget_add_css_class(field, "search-field")
        gtk_widget_set_hexpand(field, 1)
        on(field, "changed") { [weak self] in
            guard let self else { return }
            let text = entryText(field)
            guard text != query else { return }
            query = text
            queryChanged()
        }
        onClick(field) { [weak self] _ in self?.navigated = false }   // a click back in the field: Space types again
        badge = label("", "badge")
        let header = hbox(spacing: 10, children: [icon("system-search-symbolic", size: 20), field, badge])
        gtk_widget_set_margin_start(header, 16)
        gtk_widget_set_margin_end(header, 16)
        size(header, height: 56)

        list = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(cast(list), GTK_SELECTION_SINGLE)
        gtk_widget_add_css_class(list, "navigation-sidebar")
        on(list, "row-selected") { [weak self] row in
            guard let self, !selecting, let row else { return }
            if let id = rowWidgets.first(where: { UnsafeMutableRawPointer($0.value) == row })?.key { select(id) }
        }
        on(list, "row-activated") { [weak self] _ in
            guard let self else { return }
            selection == Self.weakerToggle ? toggleWeaker() : openSelected()
        }
        listScroll = scrolled(list)
        g_object_ref(listScroll)   // it leaves `listArea` while a hint or an empty state shows, and comes back
        listArea = vbox()
        size(listArea, width: Self.listWidth)
        append(listArea, listScroll)
        preview = vbox()
        gtk_widget_set_hexpand(preview, 1)
        margins(preview, 16)
        status = label("", "footer", ellipsize: true)
        gtk_widget_set_hexpand(status, 1)
        keys = label("", "footer")
        body = vbox(children: [gtk_separator_new(GTK_ORIENTATION_HORIZONTAL),
                               hbox(children: [listArea, gtk_separator_new(GTK_ORIENTATION_VERTICAL), preview]),
                               gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), hbox(children: [status, keys])])
        size(body, width: Self.width, height: Self.bodyHeight)
        setVisible(body, false)
        gtk_window_set_child(cast(window), vbox(children: [header, body]))
        onKey(window) { [weak self] key, state in self?.handle(key, state) ?? false }
        // Like Spotlight: it goes away when you click elsewhere.
        on(window, "notify::is-active") { [weak self] _ in
            guard let self, let window = self.window else { return }
            if gtk_window_is_active(cast(window)) != 0 {
                wasActive = true
            } else if wasActive, !QuickLook.shared.isVisible, isVisible {
                hide()
            }
        }
        watch { [weak self] in
            guard let self else { return }
            let activity = model.activityBadge
            setText(badge, activity ?? "")
            setVisible(badge, activity != nil)
            setTooltip(badge, model.statusLine)
        }
        self.window = window
        return window
    }

    private func render() {
        guard window != nil else { return }
        setVisible(body, phase != .empty)
        selecting = true
        gtk_list_box_remove_all(cast(list))
        rowWidgets = [:]
        selecting = false
        clear(listArea)
        if phase == .codeHint || phase == .codeOff {
            append(listArea, codeHint(off: phase == .codeOff, choose: { [weak self] in
                self?.hide()
                self?.app.chooseCodeFolders()
            }, example: { [weak self] text in self?.setQuery(text) }))
            size(listArea, width: Self.width)
        } else if results.isEmpty {
            size(listArea, width: Self.width)
            append(listArea, emptyState())
        } else {
            size(listArea, width: Self.listWidth)
            append(listArea, listScroll)
            for group in results.groups {
                addHeader(group.kind.title + (group.total > group.rows.count ? "  ·  \(group.total)" : ""))
                for row in group.rows { add(row.id, resultRow(row)) }
            }
            if !results.weaker.isEmpty {
                let count = results.weaker.count
                let fold = label((showWeaker ? "▾ Weaker matches" : "▸ \(count) weaker \(count == 1 ? "match" : "matches")"),
                                 "dim")
                margins(fold, 6)
                add(Self.weakerToggle, fold)
                if showWeaker { for row in results.weaker { add(row.id, resultRow(row)) } }
            }
        }
        setVisible(gtk_widget_get_next_sibling(listArea)!, !results.isEmpty)
        setVisible(preview, !results.isEmpty)
        renderSelection()
    }

    private func addHeader(_ title: String) {
        let header = label(title.uppercased(), "group-header")
        gtk_list_box_append(cast(list), header)
        let row = gtk_widget_get_parent(header)!
        gtk_list_box_row_set_selectable(cast(row), 0)
        gtk_list_box_row_set_activatable(cast(row), 0)
    }

    private func add(_ id: String, _ widget: Widget) {
        gtk_list_box_append(cast(list), widget)
        rowWidgets[id] = gtk_widget_get_parent(widget)
    }

    private func emptyState() -> Widget {
        let widget = vbox(spacing: 8)
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(widget, 1)
        if phase == .words {
            append(widget, label("Searching…", "dim", xalign: 0.5))
        } else if !model.hasFolders {
            append(widget, label("No folders chosen yet", "title-3", xalign: 0.5),
                   label("DigUp only searches the folders you pick.", "dim", xalign: 0.5))
            let choose = button("Choose Folders…") { [weak self] in
                self?.hide()
                self?.app.chooseFolders()
            }
            gtk_widget_set_halign(choose, GTK_ALIGN_CENTER)
            append(widget, choose)
        } else if isCode {
            append(widget, label("No good matches in your code", "title-3", xalign: 0.5),
                   label("Try saying what the code does, or a name that's in it.", "dim", xalign: 0.5))
        } else {
            append(widget, label("No good matches", "title-3", xalign: 0.5),
                   label("Try what you'd see or hear in it, or words you remember from it.", "dim", xalign: 0.5))
        }
        return widget
    }

    /// The selected row, its preview, and the footer.
    private func renderSelection() {
        guard window != nil else { return }
        selecting = true
        if let selection, let row = rowWidgets[selection] {
            gtk_list_box_select_row(cast(list), cast(row))
        } else {
            gtk_list_box_unselect_all(cast(list))
        }
        selecting = false
        clear(preview)
        PreviewPlayback.shared.stop()
        if let row = selectedRow {
            append(preview, previewPane(row, side: 410, engine: engine, open: { [weak self] in self?.openSelected() },
                                        reveal: { [weak self] in self?.revealSelected() }))
            if QuickLook.shared.isVisible { toggleQuickLook(); toggleQuickLook() }
        } else if selection == Self.weakerToggle {
            let count = results.weaker.count
            let explainer = vbox(spacing: 8, children: [
                label(showWeaker ? "Weaker matches" : "\(count) weaker \(count == 1 ? "match" : "matches")", "title-3",
                      xalign: 0.5),
                label("They match much less well than the results above. Press Return to "
                      + (showWeaker ? "fold them away." : "show them."), "dim", wrap: true, xalign: 0.5),
            ])
            gtk_widget_set_valign(explainer, GTK_ALIGN_CENTER)
            gtk_widget_set_vexpand(explainer, 1)
            append(preview, explainer)
        }
        renderFooter()
    }

    private func renderFooter() {
        guard window != nil else { return }
        setText(status, statusText)
        setText(keys, keysText)
    }

    /// The keys, saying where ↩ and Space go for a page or moment: "↩ Open at 0:06   ␣ Quick Look at 0:06".
    private var keysText: String {
        let row = selectedRow
        if let row, row.kind == .code {
            let line = row.segment == .lines ? " at line \(row.codeLine)" : ""
            return "↩ \(row.openTitle)\(line)   Ctrl+↩ Reveal   ␣ Quick Look   Ctrl+C Copy"
        }
        let place = row?.jump.map { " at \($0)" } ?? ""
        return "↩ \(row?.openTitle ?? "Open")   Ctrl+↩ Reveal   ␣ Quick Look\(place)   Ctrl+C Copy"
    }

    private var statusText: String {
        if let note { return note }
        switch phase {
        case .words:
            return model.status.encoder == .starting ? "Matching words; meaning search is warming up…" : "Matching words…"
        case .wordsOnly:
            return model.meaningUnavailable ?? "Words only: meaning search isn't available"
        case .codeHint, .codeOff:
            return phase == .codeOff ? "Code search is off" : "Searching your code"
        case .meaning, .empty:
            if isCode, let indexing = model.status.code.indexing, indexing.total > 0 {
                return "Still reading code (\(Int(Double(indexing.done) / Double(indexing.total) * 100))%): some isn't in yet"
            }
            if !isCode, let caveat = model.resultsCaveat { return caveat }
            let count = results.strongRows.count
            let weaker = results.weaker.count
            return (count == 1 ? "1 result" : "\(count) results") + (isCode ? " in your code" : "")
                + (weaker > 0 ? " · \(weaker) weaker" : "")
        }
    }
}
