import CGtk
import DigUpKit
import Foundation
import Observation

/// The window's query: keyword and meaning results together after a short pause in typing, optionally of one kind.
/// (The Mac's `SearchModel`, the same steps.)
final class SearchModel {
    private(set) var query = ""
    private(set) var filter: ResultGroupKind?
    private(set) var results = ResultSet.empty
    /// Results per kind for the query, whatever the filter (the counts on the kind buttons).
    private(set) var counts: [ResultGroupKind: Int] = [:]
    private(set) var hasResults = false
    /// What the window shows instead of results: "code:" alone (what to type), or code search that's off.
    private(set) var codePhase: SearchPhase?
    var selection: String?
    var showWeaker = false
    var showsPreview = true
    /// You moved the selection with the arrow keys since the last edit: Space and ← → act on results then.
    var navigated = false
    var onChange: () -> Void = {}
    private let engine: Engine
    private var generation = 0
    private var task: Task<Void, Never>?

    init(engine: Engine) {
        self.engine = engine
    }

    /// Every result shown, in order (strong ones, then the weaker ones once they're unfolded).
    var rows: [ResultRow] { results.ranked + (showWeaker ? results.weaker : []) }
    /// A search of code: the Code filter, or "code:" typed.
    var isCode: Bool { filter == .code || CodeQuery.text(of: query) != nil }
    var selectedRow: ResultRow? { rows.first { $0.id == selection } ?? rows.first }

    func set(query: String? = nil, filter: ResultGroupKind?? = nil) {
        let newQuery = query ?? self.query, newFilter = filter ?? self.filter
        guard newQuery != self.query || newFilter != self.filter else { return }
        self.query = newQuery
        self.filter = newFilter
        run()
    }

    func move(by step: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        selection = ids[max(0, min(ids.count - 1, index + step))]
        navigated = true
    }

    private func run() {
        generation += 1
        let current = generation
        task?.cancel()
        navigated = false
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = isCode
        let text = CodeQuery.text(of: typed) ?? typed
        codePhase = nil
        guard !typed.isEmpty else {
            results = .empty
            counts = [:]
            hasResults = false
            return onChange()
        }
        if code, !engine.hasCode || text.isEmpty {
            results = .empty
            counts = [:]
            hasResults = false
            codePhase = engine.hasCode ? .codeHint : .codeOff
            return onChange()
        }
        engine.prewarm()
        engine.embedAhead(text, code: code)
        let filter = self.filter
        let showAt = ContinuousClock.now + SearchPanelController.typingPause
        if code {
            task = Task {
                let vector = await engine.embedQuery(text, code: true)
                guard !Task.isCancelled, current == generation else { return }
                let hits = await engine.search(text, vector: vector, prefixLast: false, limit: 120, code: true)
                try? await Task.sleep(until: showAt, tolerance: .milliseconds(1), clock: .continuous)
                guard !Task.isCancelled, current == generation else { return }
                counts = [.code: Searcher.strongCount(hits)]
                results = ResultSet(hits, query: text)
                showWeaker = false
                if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
                hasResults = true
                log("window: code \"\(text)\": \(results.ranked.count) results + \(results.weaker.count) weaker")
                onChange()
            }
            return onChange()
        }
        task = Task {
            let vector = await engine.embedQuery(text)
            guard !Task.isCancelled, current == generation else { return }
            let all = await engine.search(text, vector: vector, prefixLast: false, limit: 120)
            let shown = filter == nil ? all : await engine.search(text, vector: vector, prefixLast: false,
                                                                    kinds: filter!.kinds, limit: 120)
            try? await Task.sleep(until: showAt, tolerance: .milliseconds(1), clock: .continuous)
            guard !Task.isCancelled, current == generation else { return }
            var counts: [ResultGroupKind: Int] = [:]
            for hit in all.prefix(Searcher.strongCount(all)) { counts[ResultGroupKind(hit.kind), default: 0] += 1 }
            self.counts = counts
            results = ResultSet(shown, query: text)
            showWeaker = false
            if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
            hasResults = true
            log("window: \"\(text)\"\(filter.map { " in \($0.title)" } ?? ""): \(results.ranked.count) results "
                + "+ \(results.weaker.count) weaker")
            onChange()
        }
        onChange()
    }
}

/// The search window, for the searches the panel is too small for: a big field, kind filters with counts, the results
/// as a grid of pictures, and the selected one in a preview pane with why it matched.
final class SearchWindowController {
    static let cellWidth: Int32 = 176
    let search: SearchModel
    private unowned let app: AppController
    private var window: Widget?
    private var field: Widget!
    private var filters: Widget!
    private var content: Widget!
    private var preview: Widget!
    private var previewScroll: Widget!
    private var statusButton: Widget!
    private var statusRight: Widget!
    private var progress: Widget!
    private var update: Widget!
    private var cells: [String: Widget] = [:]
    private var grid: Widget?
    private var selecting = false
    private var homeCounts: [FileKind: Int] = [:]

    init(app: AppController) {
        self.app = app
        search = SearchModel(engine: app.engine)
        search.onChange = { [weak self] in self?.render() }
    }

    var isVisible: Bool { window.map { gtk_widget_get_visible($0) != 0 } ?? false }

    func show(query: String? = nil, kind: ResultGroupKind? = nil) {
        let window = self.window ?? makeWindow()
        if let query {
            search.set(query: query, filter: .some(kind))
            if entryText(field) != query { gtk_editable_set_text(cast(field), query) }
        }
        present(window)
        gtk_widget_grab_focus(field)
        refreshHome()
    }

    func close() {
        guard let window else { return }
        gtk_widget_set_visible(window, 0)
        QuickLook.shared.close()
        PreviewPlayback.shared.stop()
        app.windowClosed()
    }

    private func trackHome() {
        _ = app.model.status.files
        if app.model.settings.roots.isEmpty { _ = 0 }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshHome() } }
    }

    private func makeWindow() -> Widget {
        let window = DigUpLinux.window("DigUp", width: 1040, height: 700)
        size(window, width: 820, height: 520)
        onClose(window) { [weak self] in
            self?.close()
            return true
        }
        field = gtk_search_entry_new()!
        gtk_widget_set_hexpand(field, 1)
        gtk_widget_add_css_class(field, "title-3")
        on(field, "search-changed") { [weak self] in
            guard let self else { return }
            search.set(query: entryText(field))
        }
        onClick(field) { [weak self] _ in self?.search.navigated = false }
        let previewToggle = iconButton("view-dual-symbolic", tooltip: "Show or Hide the Preview") { [weak self] in
            guard let self else { return }
            search.showsPreview.toggle()
            render()
        }
        let settings = iconButton("emblem-system-symbolic", tooltip: "Settings (Ctrl+,)") { [weak self] in
            self?.app.showSettings()
        }
        let menu = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(cast(menu), "open-menu-symbolic")
        gtk_widget_set_tooltip_text(menu, "DigUp: indexing, pause, folders")
        let popover = gtk_popover_new()!
        gtk_popover_set_child(cast(popover), app.statusMenu.makeMenu { gtk_popover_popdown(cast(popover)) })
        gtk_menu_button_set_popover(cast(menu), popover)
        let header = hbox(spacing: 8, children: [field, previewToggle, settings, menu])
        filters = hbox(spacing: 6)
        let top = vbox(spacing: 8, children: [header, filters])
        margins(top, 12)

        content = vbox()
        gtk_widget_set_hexpand(content, 1)
        gtk_widget_set_vexpand(content, 1)
        preview = vbox(spacing: 14)
        margins(preview, 16)
        previewScroll = scrolled(preview)
        size(previewScroll, width: 340)

        progress = gtk_progress_bar_new()!
        size(progress, width: 60)
        gtk_widget_set_valign(progress, GTK_ALIGN_CENTER)
        statusButton = gtk_button_new_with_label("")!
        gtk_widget_add_css_class(statusButton, "flat")
        gtk_widget_set_tooltip_text(statusButton, "Folders and indexing")
        on(statusButton, "clicked") { [weak self] in self?.app.showSettings(.folders) }
        statusRight = label("", "dim")
        update = button("") { [weak self] in self?.app.updates.checkNow() }
        gtk_widget_add_css_class(update, "flat")
        gtk_widget_set_tooltip_text(update, "See what's new and update")
        let statusBar = hbox(spacing: 10, children: [progress, statusButton, spacer(), statusRight, update])
        gtk_widget_set_margin_start(statusBar, 10)
        gtk_widget_set_margin_end(statusBar, 10)

        gtk_window_set_child(cast(window), vbox(children: [
            top, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL),
            hbox(children: [content, gtk_separator_new(GTK_ORIENTATION_VERTICAL), previewScroll]),
            gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), statusBar,
        ]))
        onKey(window) { [weak self] key, state in self?.handle(key, state) ?? false }
        watch { [weak self] in
            guard let self else { return }
            let model = app.model
            gtk_button_set_label(cast(statusButton), model.statusLine)
            setVisible(progress, model.progress != nil)
            gtk_progress_bar_set_fraction(cast(progress), model.progress ?? 0)
            setVisible(update, model.updateAvailable != nil)
            gtk_button_set_label(cast(update), "DigUp \(model.updateAvailable ?? "") is available")
            _ = model.hasFolders
            _ = model.hasCode
            renderStatus()
        }
        watch { [weak self] in
            // The home view's counts follow the index.
            guard let self else { return }
            self.trackHome()
        }
        self.window = window
        render()
        return window
    }

    // MARK: Keys

    /// Arrows move through the grid (← → only once you've arrowed, so they still move the cursor while you type),
    /// ↩ opens, Ctrl+↩ reveals, Space previews, Ctrl+C copies, Esc closes the preview or clears the search.
    private func handle(_ key: UInt32, _ state: GdkModifierType) -> Bool {
        let ctrl = state.rawValue & GDK_CONTROL_MASK.rawValue != 0
        let plain = state.rawValue & (GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SHIFT_MASK.rawValue) == 0
        let previewing = QuickLook.shared.isVisible
        switch Int32(key) {
        case GDK_KEY_Down, GDK_KEY_Up:
            guard plain else { return false }
            search.move(by: (Int32(key) == GDK_KEY_Down ? 1 : -1) * columns)
        case GDK_KEY_Left, GDK_KEY_Right:
            guard plain, search.navigated || previewing else { return false }
            search.move(by: Int32(key) == GDK_KEY_Right ? 1 : -1)
        case GDK_KEY_Return, GDK_KEY_KP_Enter:
            guard let row = search.selectedRow else { return false }
            if ctrl { Desktop.reveal(row.url) } else if plain { app.engine.open(row) } else { return false }
        case GDK_KEY_space where plain && (search.navigated || previewing) && search.selectedRow != nil:
            toggleQuickLook()
            return true
        case GDK_KEY_y where ctrl:
            toggleQuickLook()
            return true
        case GDK_KEY_1...GDK_KEY_6 where ctrl:   // Ctrl+1 all, Ctrl+2…6 one kind
            let kinds: [ResultGroupKind?] = [nil] + ResultGroupKind.files
            search.set(filter: .some(kinds[Int(Int32(key) - GDK_KEY_1)]))
        case GDK_KEY_7 where ctrl && app.model.hasCode:
            search.set(filter: .some(.code))
        case GDK_KEY_comma where ctrl:
            app.showSettings()
        case GDK_KEY_c where ctrl && search.navigated:
            guard let row = search.selectedRow else { return false }
            _ = Desktop.copy(row.url)
        case GDK_KEY_Escape:
            if previewing {
                QuickLook.shared.close()
            } else if !search.query.isEmpty {
                gtk_editable_set_text(cast(field), "")
            } else {
                return false
            }
        default:
            return false
        }
        renderSelection()
        return true
    }

    /// The grid's columns right now (↑ ↓ move by a row).
    private var columns: Int {
        guard let grid, !search.isCode else { return 1 }
        return max(1, Int(gtk_widget_get_width(grid) + 14) / Int(Self.cellWidth + 14))
    }

    private func toggleQuickLook() {
        QuickLook.shared.toggle(search.selectedRow, engine: app.engine, open: { [weak self] in
            guard let self, let row = search.selectedRow else { return }
            app.engine.open(row)
        }, reveal: { [weak self] in
            guard let row = self?.search.selectedRow else { return }
            Desktop.reveal(row.url)
        })
    }

    // MARK: Drawing

    private func render() {
        guard window != nil else { return }
        renderFilters()
        clear(content)
        cells = [:]
        grid = nil
        let model = app.model
        if !model.hasFolders {
            append(content, centered([icon("folder-symbolic", size: 64), label("Choose folders to search", "title-2", xalign: 0.5),
                                      label("DigUp only looks where you tell it to.", "dim", xalign: 0.5),
                                      button("Choose Folders…", "suggested-action") { [weak self] in self?.app.chooseFolders() }]))
        } else if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
            append(content, home())
        } else if let phase = search.codePhase {
            append(content, codeHint(off: phase == .codeOff, choose: { [weak self] in self?.app.chooseCodeFolders() },
                                     example: { [weak self] text in
                                         guard let self else { return }
                                         gtk_editable_set_text(cast(field), text)
                                     }))
        } else if !search.hasResults {
            let spinner = gtk_spinner_new()!
            gtk_spinner_start(cast(spinner))
            append(content, centered([spinner]))
        } else if search.results.isEmpty {
            let query = search.query.trimmingCharacters(in: .whitespaces)
            append(content, centered([
                icon(search.isCode ? "text-x-script" : "system-search-symbolic", size: 48),
                label("No good matches for “\(query)”", "title-3", wrap: true, xalign: 0.5),
                label(search.isCode ? "Try saying what the code does, or a name that's in it."
                      : "Try describing what's in it: what you'd see or hear, or words you remember.", "dim", wrap: true,
                      xalign: 0.5),
            ]))
        } else {
            append(content, results())
        }
        renderSelection()
        renderStatus()
    }

    private func centered(_ children: [Widget]) -> Widget {
        let widget = vbox(spacing: 10, children: children)
        for child in children { gtk_widget_set_halign(child, GTK_ALIGN_CENTER) }
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(widget, 1)
        margins(widget, 24)
        return widget
    }

    /// All · Screenshots 4 · Images 9 · …: what the query found of each kind; click to see only that kind. With code
    /// search on, Code after them: a search of code alone (as "code:" is).
    private func renderFilters() {
        clear(filters)
        func chip(_ title: String, count: Int?, selected: Bool, shortcut: Int, _ filter: ResultGroupKind?) {
            let text = title + (count.map { "  \($0)" } ?? "")
            let chip = gtk_toggle_button_new_with_label(text)!
            gtk_widget_add_css_class(chip, "chip")
            gtk_toggle_button_set_active(cast(chip), selected ? 1 : 0)
            setTooltip(chip, "\(title) (Ctrl+\(shortcut))")
            on(chip, "clicked") { [weak self] in
                guard let self else { return }
                search.set(filter: .some(search.filter == filter ? nil : filter))
            }
            append(filters, chip)
        }
        let typed = !search.query.isEmpty
        chip("All", count: nil, selected: search.filter == nil && !search.isCode, shortcut: 1, nil)
        for (index, kind) in ResultGroupKind.files.enumerated() {
            chip(kind.title, count: typed && !search.isCode ? search.counts[kind] : nil,
                 selected: search.filter == kind && !search.isCode, shortcut: index + 2, kind)
        }
        if app.model.hasCode {
            append(filters, gtk_separator_new(GTK_ORIENTATION_VERTICAL))
            chip("Code", count: typed && search.isCode ? search.counts[.code] : nil, selected: search.isCode,
                 shortcut: 7, .code)
        }
    }

    private func results() -> Widget {
        let column = vbox(spacing: 12)
        margins(column, 16)
        let add = { (rows: [ResultRow], dim: Bool) in
            if self.search.isCode {
                let list = vbox(spacing: 2)
                for row in rows { gtk_box_append(cast(list), self.cell(row, code: true, dim: dim)) }
                append(column, list)
            } else {
                let grid = gtk_flow_box_new()!
                gtk_flow_box_set_selection_mode(cast(grid), GTK_SELECTION_NONE)
                gtk_flow_box_set_homogeneous(cast(grid), 1)
                gtk_flow_box_set_column_spacing(cast(grid), 14)
                gtk_flow_box_set_row_spacing(cast(grid), 18)
                gtk_flow_box_set_max_children_per_line(cast(grid), 12)
                gtk_widget_set_valign(grid, GTK_ALIGN_START)
                for row in rows { gtk_flow_box_append(cast(grid), self.cell(row, code: false, dim: dim)) }
                if self.grid == nil { self.grid = grid }
                append(column, grid)
            }
        }
        add(search.results.ranked, false)
        if !search.results.weaker.isEmpty {
            let count = search.results.weaker.count
            let fold = button(search.showWeaker ? "▾ Weaker matches" : "▸ \(count) weaker \(count == 1 ? "match" : "matches")",
                              "flat") { [weak self] in
                guard let self else { return }
                search.showWeaker.toggle()
                render()
            }
            gtk_widget_set_halign(fold, GTK_ALIGN_START)
            append(column, fold)
            if search.showWeaker { add(search.results.weaker, true) }
        }
        return scrolled(column)
    }

    /// A grid cell (the picture that matched, its place, the name and folder), or a row of code.
    private func cell(_ row: ResultRow, code: Bool, dim: Bool) -> Widget {
        let widget: Widget
        if code {
            widget = resultRow(row)
        } else {
            let box = gtk_overlay_new()!
            size(box, width: Self.cellWidth, height: 132)
            let fallback = icon(row.kind.iconName, size: 56)
            gtk_overlay_set_child(cast(box), fallback)
            Pictures.preview(row, side: 352) { path in
                guard let path, let image = picture(path) else { return }
                gtk_picture_set_content_fit(cast(image), GTK_CONTENT_FIT_COVER)
                gtk_overlay_set_child(cast(box), image)
            }
            if let place = row.place {
                let badge = label(place, "badge")
                gtk_widget_set_halign(badge, GTK_ALIGN_START)
                gtk_widget_set_valign(badge, GTK_ALIGN_END)
                margins(badge, 6)
                gtk_overlay_add_overlay(cast(box), badge)
            }
            let name = label(row.name, "row-title", ellipsize: true)
            let folder = label(row.folder, "faint", ellipsize: true)
            gtk_label_set_ellipsize(cast(folder), PANGO_ELLIPSIZE_START)
            widget = vbox(spacing: 6, "grid-cell", children: [box, vbox(spacing: 1, children: [name, folder])])
            size(widget, width: Self.cellWidth)
            setTooltip(widget, "\(row.kind.title), \(row.name): \(row.reason)")
            dragsFile(widget) { row.url.path }
        }
        if dim { gtk_widget_set_opacity(widget, 0.85) }
        onClick(widget) { [weak self] count in
            guard let self else { return }
            search.selection = row.id
            search.navigated = true
            renderSelection()
            if count == 2 { app.engine.open(row) }
        }
        cells[row.id] = widget
        return widget
    }

    private func renderSelection() {
        guard window != nil else { return }
        let selected = search.selectedRow?.id
        for (id, cell) in cells {
            if id == selected { gtk_widget_add_css_class(cell, "card") } else { gtk_widget_remove_css_class(cell, "card") }
        }
        if let selected, let cell = cells[selected] { gtk_widget_grab_focus(cell); gtk_widget_grab_focus(field) }
        clear(preview)
        PreviewPlayback.shared.stop()
        let showing = search.showsPreview && search.hasResults && search.selectedRow != nil
        setVisible(previewScroll, showing)
        if showing, let row = search.selectedRow {
            append(preview, previewPane(row, side: 300, engine: app.engine, open: { [weak self] in
                self?.app.engine.open(row)
            }, reveal: { Desktop.reveal(row.url) }))
            if QuickLook.shared.isVisible {
                QuickLook.shared.show(row, engine: app.engine, open: { [weak self] in self?.app.engine.open(row) },
                                      reveal: { Desktop.reveal(row.url) })
            }
        }
    }

    private func renderStatus() {
        guard window != nil else { return }
        let count = search.results.ranked.count
        let text = search.hasResults && !search.query.isEmpty
            ? app.model.resultsCaveat ?? ((count == 1 ? "1 result" : "\(count) results")
                + (search.results.weaker.isEmpty ? "" : " · \(search.results.weaker.count) weaker"))
            : ""
        setText(statusRight, text)
    }

    // MARK: Home

    /// Nothing typed yet: what to type, examples to click (each with the kind it finds), what's in the index, and
    /// the shortcut.
    private func home() -> Widget {
        let model = app.model
        let widget = vbox(spacing: 8)
        append(widget, icon("system-search", size: 72), label("Describe it. Dig it up.", "hero", xalign: 0.5),
               label("Type what you remember in the search field above: what's in it, what it looks or sounds like, or "
                     + "words from it.", "dim", wrap: true, xalign: 0.5), label("TRY", "faint", xalign: 0.5))
        var list: [(String, ResultGroupKind)] = [
            ("a screenshot of an error message", .screenshots), ("receipt", .documents), ("whiteboard notes", .images),
            ("someone laughing", .audio), ("a dog on the beach", .video), ("slides about the budget", .documents),
        ]
        if model.hasCode { list.append(("code: where the settings are saved", .code)) }
        // Three to a row, centered.
        for start in stride(from: 0, to: list.count, by: 3) {
            let row = hbox(spacing: 8)
            gtk_widget_set_halign(row, GTK_ALIGN_CENTER)
            for (text, kind) in list[start..<min(start + 3, list.count)] {
                let chip = button(text, "chip") { [weak self] in
                    guard let self else { return }
                    gtk_editable_set_text(cast(field), text)
                }
                setTooltip(chip, "Search for “\(text)” (\(kind.title))")
                append(row, chip)
            }
            append(widget, row)
        }
        let names = model.settings.roots.map(\.lastPathComponent)
        let folders = names.count <= 3 ? names.formatted(.list(type: .and)) : "\(names.count) folders"
        let counts = FileKind.allCases.compactMap { kind in homeCounts[kind].map { "\($0) \(kind.title.lowercased())" } }
        if !counts.isEmpty {
            append(widget, label(counts.joined(separator: " · ") + " in \(folders)", "faint", wrap: true, xalign: 0.5))
        } else if model.status.searchable > 0 {
            append(widget, label("\(model.status.searchable.formatted()) files to search in \(folders)", "faint", xalign: 0.5))
        }
        if let hotkey = model.hotkey {
            append(widget, label("\(hotkey.display) opens DigUp from any app", "faint", xalign: 0.5))
        }
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(widget, 1)
        margins(widget, 24)
        return widget
    }

    /// The home view's counts by kind, over every folder.
    private func refreshHome() {
        guard isVisible else { return }
        Task {
            var counts: [FileKind: Int] = [:]
            for summary in await app.engine.rootSummaries() { counts.merge(summary.kinds, uniquingKeysWith: +) }
            guard counts != homeCounts else { return }
            homeCounts = counts
            if search.query.isEmpty { render() }
        }
    }
}
