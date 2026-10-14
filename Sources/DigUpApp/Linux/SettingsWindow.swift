import CGtk
import DigUpKit
import Foundation
import Observation

enum SettingsTab: String, CaseIterable {
    case general, folders, code, storage

    var title: String {
        switch self {
        case .general: "General"
        case .folders: "Folders"
        case .code: "Code"
        case .storage: "Storage"
        }
    }
}

/// What the tabs show that comes from the engine (counts per folder, sizes on disk), refreshed as indexing goes.
@Observable
final class SettingsState {
    private(set) var summaries: [Engine.RootSummary]?
    private(set) var codeSummaries: [Engine.RootSummary] = []
    private(set) var indexSize: Int64 = 0
    private(set) var codeIndexSize: Int64 = 0
    @ObservationIgnored let app: AppController
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var refreshPending = false

    init(app: AppController) {
        self.app = app
    }

    func refresh() async {
        lastRefresh = Date()
        indexSize = app.engine.indexSize
        codeIndexSize = app.engine.codeIndexSize
        codeSummaries = await app.engine.rootSummaries(code: true)
        summaries = await app.engine.rootSummaries()
    }

    /// The index changed: refresh the folder counts, at most every 2 s while files are being indexed.
    func statusChanged() {
        guard !refreshPending else { return }
        refreshPending = true
        let wait = max(0, 2 - Date().timeIntervalSince(lastRefresh))
        Task {
            try? await Task.sleep(for: .seconds(wait))
            refreshPending = false
            await refresh()
        }
    }
}

/// Settings: General (the shortcut, opening at login, updates), Folders (what's searched and skipped, progress,
/// pause), Code (code search's folders and editor), Storage (the model, the index, privacy).
final class SettingsWindowController {
    private unowned let app: AppController
    private let state: SettingsState
    private var window: Widget?
    private var stack: Widget!
    private var tabs: [SettingsTab: Widget] = [:]
    private lazy var adder = AddFoldersController(app: app)
    private lazy var codeAdder = AddFoldersController(app: app, code: true)

    init(app: AppController) {
        self.app = app
        state = SettingsState(app: app)
        adder.onAdded = { [weak self] in self?.refreshSoon() }
        codeAdder.onAdded = { [weak self] in self?.refreshSoon() }
    }

    var isVisible: Bool { window.map { gtk_widget_get_visible($0) != 0 } ?? false }

    func show(_ tab: SettingsTab = .general) {
        let window = self.window ?? makeWindow()
        gtk_stack_set_visible_child_name(cast(stack), tab.rawValue)
        present(window)
        refreshSoon()
    }

    func addFolders() { adder.begin(on: window) }
    func addCodeFolders() { codeAdder.begin(on: window) }

    private func refreshSoon() {
        Task { await state.refresh() }
    }

    private func makeWindow() -> Widget {
        let window = DigUpLinux.window("DigUp Settings", width: 640, height: 640)
        onClose(window) { [weak self] in
            gtk_widget_set_visible(window, 0)
            self?.app.windowClosed()
            return true
        }
        stack = gtk_stack_new()!
        gtk_stack_set_transition_type(cast(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        for tab in SettingsTab.allCases {
            let page = vbox(spacing: 14)
            margins(page, 20)
            gtk_stack_add_titled(cast(stack), scrolled(page), tab.rawValue, tab.title)
            tabs[tab] = page
        }
        let switcher = gtk_stack_switcher_new()!
        gtk_stack_switcher_set_stack(cast(switcher), cast(stack))
        gtk_widget_set_halign(switcher, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(switcher, 10)
        gtk_window_set_child(cast(window), vbox(spacing: 6, children: [switcher, stack]))
        general(tabs[.general]!)
        folders(tabs[.folders]!)
        code(tabs[.code]!)
        storage(tabs[.storage]!)
        onKey(window) { key, _ in
            guard Int32(key) == GDK_KEY_Escape else { return false }
            gtk_widget_set_visible(window, 0)
            return true
        }
        // Folder counts follow indexing, at most every 2 s.
        watch { [weak self] in
            guard let self else { return }
            _ = app.model.status
            state.statusChanged()
        }
        self.window = window
        return window
    }

    private func section(_ page: Widget, _ title: String?, _ children: [Widget], footer: String? = nil) {
        if let title { append(page, label(title, "row-title")) }
        let card = vbox(spacing: 10, "card-row", children: children)
        append(page, card)
        if let footer { append(page, label(footer, "dim", wrap: true)) }
    }

    // MARK: General

    private func general(_ page: Widget) {
        let model = app.model
        let (recorder, caps) = shortcutRecorder(app)
        let how = label("", "dim", wrap: true)
        gtk_label_set_selectable(cast(how), 1)
        _ = caps
        watch(page) {
            let command = DesktopShortcut.command
            setText(how, DesktopShortcut.canInstall
                ? "Set in GNOME's keyboard shortcuts as “DigUp”, which runs \(command)."
                : "Your desktop sets global shortcuts itself: in its keyboard settings, add a custom shortcut "
                    + "for \(model.hotkey?.display ?? "the keys you like") that runs\n\(command)")
        }
        let shortcut = hbox(spacing: 12, children: [vbox(spacing: 2, children: [
            label("Search shortcut", "row-title"), label("Opens the search panel from any app.", "dim")]), spacer(),
            recorder])
        section(page, nil, [shortcut, how])

        let loginProblem = label("", "dim")
        let login = switchRow("Open DigUp when you log in", detail: "So the shortcut always works.",
                              on: app.launchesAtLogin) { [weak self] on in
            setText(loginProblem, self?.app.setLaunchAtLogin(on) ?? "")
        }
        section(page, nil, [login, loginProblem])

        let updates = switchRow("Check for updates automatically",
                                detail: "Once a day DigUp asks GitHub for its newest version; nothing about your files "
                                    + "is sent.", on: app.updates.automaticallyChecks) { [weak self] on in
            self?.app.updates.automaticallyChecks = on
        }
        let version = label("", "dim")
        watch(page) {
            setText(version, model.updateAvailable.map { "DigUp \($0) is available" } ?? "DigUp \(Updates.version)")
        }
        section(page, nil, [updates, hbox(spacing: 8, children: [version, spacer(), button("Check Now") { [weak self] in
            self?.app.updates.checkNow()
        }])])
    }

    // MARK: Folders

    private func folders(_ page: Widget) {
        let model = app.model
        // What the index is doing, with Pause/Resume.
        let status = label("", "row-title", ellipsize: true)
        let bar = gtk_progress_bar_new()!
        let detail = label("", "dim", wrap: true)
        let pause = button("Pause") { [weak self] in
            guard let self else { return }
            app.engine.setPaused(!model.status.paused)
        }
        watch(page) {
            setText(status, model.statusLine)
            setVisible(bar, model.progress != nil)
            gtk_progress_bar_set_fraction(cast(bar), model.progress ?? 0)
            let counts = model.status
            var text = "\(counts.searchable.formatted()) of \(counts.files.formatted()) files searchable"
            if counts.pending > 0 { text += " · \(counts.pending.formatted()) waiting" }
            if counts.unfinished > 0 {
                text += " · \(counts.unfinished.formatted()) long \(counts.unfinished == 1 ? "file" : "files") to finish"
            }
            if model.download.isActive { text += " · model \(model.download.progressText)" }
            setText(detail, text)
            gtk_button_set_label(cast(pause), counts.paused ? "Resume" : "Pause")
            setVisible(pause, model.hasFolders)
        }
        let progress = vbox(spacing: 5, children: [status, bar, detail])
        gtk_widget_set_hexpand(progress, 1)
        section(page, nil, [hbox(spacing: 12, children: [progress, pause])])

        let roots = vbox(spacing: 8)
        watch(roots) { [weak self] in
            guard let self else { return }
            clear(roots)
            guard let summaries = state.summaries else {
                let spinner = gtk_spinner_new()!
                gtk_spinner_start(cast(spinner))
                return append(roots, spinner)
            }
            if summaries.isEmpty { append(roots, label("No folders yet. Add the ones DigUp should search.", "dim")) }
            for summary in summaries {
                append(roots, folderStatusRow(summary) { [weak self] in
                    guard let self, let window else { return }
                    let name = (summary.path as NSString).lastPathComponent
                    confirm(window, title: "Stop searching “\(name)”?",
                            detail: "Its \(summary.files.formatted()) files leave the index. Adding it back later "
                                + "indexes them again.", action: "Remove") { [weak self] in
                        self?.app.removeFolder(URL(fileURLWithPath: summary.path))
                        self?.refreshSoon()
                    }
                })
            }
        }
        section(page, "Folders to search", [roots, hbox(children: [button("＋ Add Folders…") { [weak self] in
            self?.addFolders()
        }])])

        let skipped = vbox(spacing: 6)
        watch(skipped) { [weak self] in
            clear(skipped)
            let excluded = model.settings.excludedFolders
            if excluded.isEmpty {
                append(skipped, label("None. Code projects and caches are skipped anyway (code has its own tab).",
                                      "dim", wrap: true))
            }
            for folder in excluded {
                append(skipped, hbox(spacing: 8, children: [icon("folder", size: 18), label(tildePath(folder.path),
                                                                                           ellipsize: true), spacer(),
                    iconButton("list-remove-symbolic", tooltip: "Search it again") {
                        self?.app.setExcluded(excluded.filter { $0 != folder })
                    }]))
            }
        }
        section(page, "Skip these folders", [skipped, hbox(children: [button("＋ Skip a Folder…") { [weak self] in
            guard let self else { return }
            app.pickFolders(for: window, prompt: "Skip") { folders in
                guard !folders.isEmpty else { return }
                let excluded = model.settings.excludedFolders
                self.app.setExcluded(excluded + folders.filter { !excluded.contains($0) })
            }
        }])])

        let types = entry(placeholder: "e.g. heic, txt", text: model.settings.excludedTypes.joined(separator: ", "))
        on(types, "activate") { [weak self] in self?.app.setExcludedTypes(entryText(types)) }
        let focus = gtk_event_controller_focus_new()!
        on(focus, "leave") { [weak self] in self?.app.setExcludedTypes(entryText(types)) }
        gtk_widget_add_controller(types, focus)
        section(page, "Skip these file types", [types],
                footer: "DigUp only reads pictures, PDFs, documents (txt, md, rtf, docx, odt, html), audio and video "
                    + "here; code is read only in the code folders (the Code tab). Keys, certificates and password "
                    + "files are never read, nor are hidden folders like ~/.ssh.")

        section(page, nil, [switchRow(AppSettings.batteryTitle, detail: AppSettings.batteryDetail,
                                      on: model.settings.indexOnBattery) { [weak self] on in
            self?.app.setIndexOnBattery(on)
        }])
    }

    private func folderStatusRow(_ summary: Engine.RootSummary, remove: @escaping @MainActor () -> Void) -> Widget {
        let name = (summary.path as NSString).lastPathComponent
        let title = hbox(spacing: 6, children: [label(name, "row-title")])
        if summary.missing || summary.unreadable { append(title, label(summary.missing ? "Not connected" : "No access", "badge")) }
        let texts = vbox(spacing: 2, children: [title, label(tildePath(summary.path), "faint", ellipsize: true)])
        if !summary.kinds.isEmpty { append(texts, label(kindCounts(summary.kinds), "dim", wrap: true)) }
        gtk_widget_set_hexpand(texts, 1)
        let states = [summary.pending > 0 ? "\(summary.pending.formatted()) waiting" : nil,
                      summary.unfinished > 0
                        ? "\(summary.unfinished.formatted()) long \(summary.unfinished == 1 ? "file" : "files") to finish"
                        : nil,
                      summary.skipped > 0 ? "\(summary.skipped.formatted()) skipped" : nil,
                      summary.failed > 0 ? "\(summary.failed.formatted()) couldn't be read" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let counts = vbox(spacing: 2, children: [label(summary.missing || summary.unreadable ? "Kept for when it's back"
                                                       : "\(summary.indexed.formatted()) of \(summary.files.formatted()) indexed",
                                                       xalign: 1)])
        if !states.isEmpty { append(counts, label(states, "dim", xalign: 1)) }
        let folderIcon = icon(summary.missing ? "drive-harddisk" : "folder", size: 30)
        if summary.missing { gtk_widget_set_opacity(folderIcon, 0.5) }
        return hbox(spacing: 12, children: [folderIcon, texts, counts,
                                            iconButton("list-remove-symbolic", tooltip: "Stop searching \(name)", action: remove)])
    }

    // MARK: Code

    private func code(_ page: Widget) {
        let model = app.model
        let line = label("", "row-title")
        let bar = gtk_progress_bar_new()!
        let size = label("", "dim")
        watch(page) { [weak self] in
            guard let self else { return }
            setText(line, model.codeStatusLine)
            setVisible(line, model.hasCode)
            let indexing = model.status.code.indexing
            setVisible(bar, model.hasCode && (indexing?.total ?? 0) > 0)
            if let indexing, indexing.total > 0 { gtk_progress_bar_set_fraction(cast(bar), Double(indexing.done) / Double(indexing.total)) }
            setText(size, model.hasCode ? bytes(state.codeIndexSize) : "")
        }
        section(page, nil, [label("Search your code", "row-title"),
                            label("Find code by what it does, or by a name in it: type code: in the search panel, as in "
                                  + "“code: retry with backoff”. Code has an index of its own, and it never shows up in "
                                  + "other searches.", "dim", wrap: true),
                            hbox(spacing: 8, children: [vbox(spacing: 4, children: [line, bar]), spacer(), size])])

        let roots = vbox(spacing: 8)
        let add = button("＋ Add Folders…") { [weak self] in self?.addCodeFolders() }
        watch(roots) { [weak self] in
            guard let self else { return }
            clear(roots)
            gtk_button_set_label(cast(add), model.hasCode ? "＋ Add Folders…" : "＋ Choose Code Folders…")
            if state.codeSummaries.isEmpty {
                append(roots, label("No code folders yet. Add the folders that hold your projects.", "dim", wrap: true))
            }
            for summary in state.codeSummaries {
                append(roots, folderStatusRow(summary) { [weak self] in
                    guard let self, let window else { return }
                    confirm(window, title: "Stop searching the code in “\((summary.path as NSString).lastPathComponent)”?",
                            detail: "Its \(summary.files.formatted()) code files leave the code index.",
                            action: "Remove") { [weak self] in
                        self?.app.removeCodeFolder(URL(fileURLWithPath: summary.path))
                        self?.refreshSoon()
                    }
                })
            }
        }
        section(page, "Code folders", [roots, hbox(children: [add])])

        let editors = CodeEditor.installed + [CodeEditor.defaultApp]
        let names = editors.map { strdup($0.name) } + [nil]
        let picker = gtk_drop_down_new_from_strings(names.map { UnsafePointer($0) })!
        names.forEach { free($0) }
        gtk_drop_down_set_selected(cast(picker), UInt32(editors.firstIndex { $0.id == CodeEditor.current.id } ?? editors.count - 1))
        on(picker, "notify::selected") { [weak self] _ in
            let index = Int(gtk_drop_down_get_selected(cast(picker)))
            guard index < editors.count else { return }
            self?.app.setCodeEditor(editors[index].id)
        }
        section(page, nil, [hbox(spacing: 12, children: [label("Open code in", "row-title"), spacer(), picker])],
                footer: "A result opens there at the line that matched. Space shows the whole file in Quick Look.")

        let off = button("Turn Off Code Search…", "destructive-action") { [weak self] in
            guard let self, let window else { return }
            confirm(window, title: "Turn off code search?",
                    detail: "The code index (\(bytes(state.codeIndexSize))) is deleted. Turning it on again reads the "
                        + "code again.", action: "Turn Off") { [weak self] in
                self?.app.applyCodeFolders([], excluded: [])
                self?.refreshSoon()
            }
        }
        gtk_widget_set_halign(off, GTK_ALIGN_END)
        watch(off) { setVisible(off, model.hasCode) }
        section(page, nil, [label("The code index keeps your code's text on this computer, as the main index keeps your "
                                  + "documents'. It skips what git ignores, vendored and generated code, data files, and "
                                  + "anything that looks like a key or a password.", "dim", wrap: true), off])
    }

    // MARK: Storage

    private func storage(_ page: Widget) {
        let model = app.model
        let status = label("", "dim")
        let download = button("Download") { model.download.start() }
        watch(page) {
            setText(status, model.download.isReady ? "Downloaded" : model.download.progressText)
            switch model.download.phase {
            case .needed, .failed: setVisible(download, true)
            default: setVisible(download, false)
            }
        }
        func row(_ title: String, _ value: Widget) -> Widget {
            hbox(spacing: 12, children: [label(title), spacer(), value])
        }
        func path(_ url: URL) -> Widget {
            let widget = button(tildePath(url.path) + "  →", "flat") { Desktop.open(url) }
            setTooltip(widget, "Show in Files")
            return widget
        }
        section(page, "Model", [row("EmbeddingGemma 2", label("Google · Apache 2.0 · 865 MB", "dim")),
                                row("Status", hbox(spacing: 8, children: [status, download])),
                                row("Location", path(model.settings.modelsDirectory))])
        let size = label("", "dim")
        let codeSize = label("", "dim")
        let codeRow = row("Code index", codeSize)
        watch(page) { [weak self] in
            guard let self else { return }
            setText(size, bytes(state.indexSize))
            setText(codeSize, bytes(state.codeIndexSize))
            setVisible(codeRow, model.hasCode)
        }
        section(page, "Index", [row("Size on disk", size), codeRow, row("Location", path(model.settings.indexDirectory))])
        section(page, "Privacy", [label("DigUp reads the folders you choose and keeps what it learns in its index, on this "
                                        + "computer. It goes online only to download its model, once, and to check for "
                                        + "updates (General), which sends nothing about your files.", wrap: true)])
        section(page, nil, [label("DigUp \(Updates.version) · EmbeddingGemma 2 by Google (Apache 2.0), run by llama.cpp "
                                  + "(MIT).", "dim", wrap: true)])
    }
}

/// The shortcut as keycaps, and Change…: click, then press the new one (Esc cancels). Returns the recorder and its
/// keycaps label.
func shortcutRecorder(_ app: AppController) -> (Widget, Widget) {
    let model = app.model
    let caps = label(model.hotkey?.display ?? "None", "keycap")
    let record = button("Change…") {}
    let problem = label("", "dim", wrap: true)
    var recording = false
    func stop() {
        recording = false
        gtk_button_set_label(cast(record), "Change…")
    }
    on(record, "clicked") {
        recording.toggle()
        gtk_button_set_label(cast(record), recording ? "Press the new shortcut… (Esc cancels)" : "Change…")
    }
    onKey(record) { key, state in
        guard recording else { return false }
        if Int32(key) == GDK_KEY_Escape {
            stop()
            return true
        }
        let name = String(cString: gdk_keyval_name(gdk_keyval_to_lower(key)))
        // A modifier on its own: keep waiting for the key.
        if name.hasPrefix("Control_") || name.hasPrefix("Alt_") || name.hasPrefix("Shift_") || name.hasPrefix("Super_")
            || name.hasPrefix("Meta_") || name == "ISO_Level3_Shift" { return true }
        let held = state.rawValue
        guard let combo = KeyCombo(keyName: name, ctrl: held & GDK_CONTROL_MASK.rawValue != 0,
                                   alt: held & GDK_ALT_MASK.rawValue != 0, shift: held & GDK_SHIFT_MASK.rawValue != 0,
                                   superKey: held & GDK_SUPER_MASK.rawValue != 0) else {
            setText(problem, "Use Ctrl, Alt or Super with a key")
            return true
        }
        setText(problem, app.setHotkey(combo) ?? "")
        stop()
        return true
    }
    watch(caps) { setText(caps, model.hotkey?.display ?? "None") }
    return (vbox(spacing: 4, children: [hbox(spacing: 8, children: [caps, record]), problem]), caps)
}
