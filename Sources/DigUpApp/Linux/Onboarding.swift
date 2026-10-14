import CGtk
import DigUpKit
import Foundation
import Observation

/// Onboarding's steps and choices (the Mac's `OnboardingState`): welcome (the go-ahead for the model download),
/// folders (with estimates, skips and file types), code search (when there's code to offer), the shortcut, and ready.
@Observable
final class OnboardingState {
    enum Step: Int, CaseIterable {
        case welcome, folders, code, shortcut, ready
    }

    private(set) var step = Step.welcome
    /// The folders to search, with their estimates and subfolders; applied on Continue.
    let folders: FolderChoices
    /// Code search's folders, offered when this computer has folders with code (`CodeFolders`).
    let codeFolders: FolderChoices
    var searchCode = false {
        didSet { if searchCode { codeFolders.startEstimates() } }
    }
    /// You pressed the hotkey on the shortcut step.
    private(set) var hotkeyWorked = false
    var launchAtLogin: Bool
    var indexOnBattery: Bool
    /// File types to skip as typed ("heic, txt"): applied on Return, and on Continue.
    var skippedTypesText: String
    @ObservationIgnored let app: AppController
    @ObservationIgnored var close: () -> Void = {}

    init(app: AppController) {
        self.app = app
        let settings = app.model.settings
        let candidates = Self.candidates()
        let chosen = settings.roots
        let selection = FolderSelection(chosen: (chosen.isEmpty ? candidates : chosen).map(\.path),
                                        skipped: settings.excludedFolders.map(\.path))
        // A chosen subfolder of a folder listed shows in that folder's list, not as a folder of its own.
        let others = chosen.filter { root in
            !candidates.contains { $0.path == root.path || $0.path == FolderSelection.parent(root.path) }
        }
        folders = FolderChoices(rows: candidates + others, selection: selection, types: settings.excludedTypes)
        let codeCandidates = CodeFolders.candidates(searched: [])
        codeFolders = FolderChoices(rows: codeCandidates,
                                    selection: FolderSelection(chosen: settings.codeRoots.isEmpty
                                                                   ? codeCandidates.map(\.path)
                                                                   : settings.codeRoots.map(\.path)),
                                    types: [], code: true)
        searchCode = !settings.codeRoots.isEmpty
        launchAtLogin = app.launchesAtLogin || app.suggestsLaunchAtLogin
        indexOnBattery = settings.indexOnBattery
        skippedTypesText = settings.excludedTypes.joined(separator: ", ")
    }

    var model: AppModel { app.model }
    var download: ModelDownload { app.download }

    /// The steps this computer gets: code search's only when there's code to offer.
    var steps: [Step] {
        Step.allCases.filter { $0 != .code || !codeFolders.rows.isEmpty }
    }

    /// The folders it offers: the usual home folders that exist (the XDG user folders: Desktop, Documents, Downloads,
    /// Pictures, Videos, Music, as `xdg-user-dir` names them), or `-onboardingLocations a:b:c` (tests point it at the
    /// testbed, never at real folders).
    static func candidates() -> [URL] {
        if let list = UserDefaults.standard.string(forKey: "onboardingLocations") {
            return list.split(separator: ":").map { AppSettings.folderURL(String($0)) }
        }
        // A dev or test run (its own defaults suite) never offers, and so never estimates, the real home folders.
        if UserDefaults.standard.string(forKey: "defaultsSuite") != nil {
            log("onboarding: no -onboardingLocations in a dev run, so no folders are offered")
            return []
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let named = ["DESKTOP", "DOCUMENTS", "DOWNLOAD", "PICTURES", "VIDEOS", "MUSIC"].compactMap { name in
            Desktop.output("xdg-user-dir", [name]).flatMap { $0 == home.path ? nil : $0 }
        }
        let folders = named.isEmpty ? ["Desktop", "Documents", "Downloads", "Pictures", "Videos", "Music"]
            .map { home.appendingPathComponent($0).path } : named
        var seen = Set<String>()
        return folders.map(AppSettings.folderURL).filter { AppSettings.isFolder($0) && seen.insert($0.path).inserted }
    }

    // MARK: Steps

    func next() {
        switch step {
        case .welcome:
            download.start()   // the go-ahead for the one download
            go(to: .folders)
        case .folders:
            // Indexing starts now (file names first; meaning once the model is in), while you set up the rest.
            folders.setTypes(skippedTypesText)
            app.applyFolders(folders.roots, excluded: folders.skipped, types: folders.types)
            go(to: steps.contains(.code) ? .code : .shortcut)
        case .code:
            if searchCode, !codeFolders.roots.isEmpty {
                app.applyCodeFolders(codeFolders.roots, excluded: codeFolders.skipped)
            } else if !searchCode, model.hasCode {
                app.applyCodeFolders([], excluded: [])
            }
            go(to: .shortcut)
        case .shortcut:
            go(to: .ready)
        case .ready:
            finish()
        }
    }

    func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        go(to: steps[index - 1])
    }

    func go(to step: Step) {
        self.step = step
        app.hotkeyTester = step == .shortcut ? { [weak self] in self?.hotkeyWorked = true } : nil
        if step == .folders { folders.startEstimates() }
    }

    func finish() {
        if indexOnBattery != model.settings.indexOnBattery { app.setIndexOnBattery(indexOnBattery) }
        if launchAtLogin != app.launchesAtLogin { _ = app.setLaunchAtLogin(launchAtLogin) }
        log("onboarding: done (\(model.settings.roots.count) folders, login item \(launchAtLogin ? "on" : "off"))")
        close()
    }

    func addFolders(from window: Widget?) {
        app.pickFolders(for: window) { [weak self] picked in
            guard !picked.isEmpty else { return }
            self?.folders.add(picked)
        }
    }

    func skipFolders(from window: Widget?) {
        app.pickFolders(for: window, prompt: "Skip") { [weak self] picked in
            guard !picked.isEmpty else { return }
            self?.folders.skip(picked)
        }
    }

    func addCodeFolders(from window: Widget?) {
        app.pickFolders(for: window) { [weak self] picked in
            guard !picked.isEmpty else { return }
            self?.codeFolders.add(picked)
        }
    }
}

/// The onboarding window.
final class OnboardingController {
    private unowned let app: AppController
    private let state: OnboardingState
    private var window: Widget?

    init(app: AppController) {
        self.app = app
        state = OnboardingState(app: app)
        state.close = { [weak self] in self?.close() }
    }

    var isVisible: Bool { window.map { gtk_widget_get_visible($0) != 0 } ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        present(window)
    }

    func close() {
        guard let window else { return }
        self.window = nil
        gtk_window_destroy(cast(window))
        app.onboardingClosed()
    }

    private func makeWindow() -> Widget {
        let window = DigUpLinux.window("Welcome to DigUp", width: 680, height: 600)
        onClose(window) { [weak self] in
            self?.close()
            return true
        }
        let page = vbox()
        gtk_widget_set_vexpand(page, 1)
        margins(page, 28)
        let dots = label("", "dim")
        let download = label("", "dim", ellipsize: true)
        let downloadAgain = button("Download") { [weak self] in self?.state.download.start() }
        let summary = label("", "dim")
        gtk_widget_set_hexpand(summary, 1)
        gtk_label_set_xalign(cast(summary), 1)
        let back = button("Back") { [weak self] in self?.state.back() }
        let next = button("", "suggested-action") { [weak self] in self?.state.next() }
        let footer = hbox(spacing: 14, children: [dots, download, downloadAgain, summary, back, next])
        margins(footer, 14)
        gtk_window_set_child(cast(window), vbox(children: [page, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), footer]))
        gtk_window_set_default_widget(cast(window), next)

        var shown: OnboardingState.Step?
        watch(page) { [weak self] in
            guard let self else { return }
            let state = self.state
            if state.step != shown {
                shown = state.step
                clear(page)
                append(page, stepView(state.step, window: window))
            }
            let index = state.steps.firstIndex(of: state.step) ?? 0
            setText(dots, state.steps.indices.map { $0 == index ? "●" : "○" }.joined(separator: " "))
            setVisible(download, state.step != .welcome)
            setText(download, downloadText)
            switch state.download.phase {
            case .needed, .failed: setVisible(downloadAgain, state.step != .welcome)
            default: setVisible(downloadAgain, false)
            }
            setText(summary, state.step == .folders ? foldersSummary
                    : state.step == .code && state.searchCode ? codeSummary : "")
            setVisible(back, state.step != .welcome && state.step != .ready)
            let title = switch state.step {
            case .welcome: "Get Started"
            case .ready: "Done"
            default: "Continue"
            }
            gtk_button_set_label(cast(next), title)
            gtk_widget_set_sensitive(next, state.step == .folders && state.folders.roots.isEmpty ? 0 : 1)
        }
        self.window = window
        return window
    }

    private var downloadText: String {
        let download = state.download
        switch download.phase {
        case .ready: return "✓ Model ready"
        case .failed(let message): return "⚠︎ " + message
        case .needed: return "Model not downloaded"
        default: return "Downloading the model · \(download.progressText)"
        }
    }

    private var codeSummary: String {
        guard !state.codeFolders.roots.isEmpty else { return "Check the folders with your code" }
        guard state.codeFolders.estimatesDone else { return "Looking at your code…" }
        let seconds = state.codeFolders.totalSeconds
        return (seconds < 1 ? "Under a second" : "About \(roughDuration(seconds))")
            + ", \(roughBytes(state.codeFolders.totalBytes))"
    }

    private var foldersSummary: String {
        guard !state.folders.roots.isEmpty else { return "Choose at least one folder" }
        guard state.folders.estimatesDone else { return "Looking at your folders…" }
        return "First pass: about \(roughDuration(state.folders.totalSeconds))"
    }

    private func stepView(_ step: OnboardingState.Step, window: Widget) -> Widget {
        switch step {
        case .welcome: welcome()
        case .folders: folders(window)
        case .code: code(window)
        case .shortcut: shortcut()
        case .ready: ready()
        }
    }

    private func centered(_ widget: Widget) -> Widget {
        gtk_widget_set_halign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(widget, 1)
        size(widget, width: 470)
        return widget
    }

    private func welcome() -> Widget {
        func feature(_ icon: String, _ title: String, _ example: String) -> Widget {
            hbox(spacing: 14, children: [DigUpLinux.icon(icon, size: 32),
                                         vbox(spacing: 2, children: [label(title, "row-title"), label(example, "dim", wrap: true)])])
        }
        return centered(vbox(spacing: 16, children: [
            icon("system-search", size: 88), label("DigUp", "hero", xalign: 0.5),
            label("Describe it. Dig it up.", "title-3", xalign: 0.5),
            feature("image-x-generic", "Screenshots and photos", "“that payment error”, “the zebra”, “whiteboard from Tuesday”"),
            feature("x-office-document", "PDFs and documents", "“the clause about pets in the lease”, “flight receipt”"),
            feature("audio-x-generic", "Moments inside audio and video", "“where they talk about sleep”, “the part with the drums”"),
            label("🔒 Everything is indexed and searched on this computer. DigUp downloads its AI model (865 MB) once; "
                  + "after that it works offline, and nothing you index ever leaves your computer.", "dim", wrap: true),
        ]))
    }

    private func folders(_ window: Widget) -> Widget {
        let list = folderList(state.folders, addTitle: "Add Folder…") { [weak self] in self?.state.addFolders(from: window) }
        // Folders and file types to leave out, before the first pass reads anything. Folded away unless something is set.
        let skips = vbox(spacing: 8)
        watch(skips) { [weak self] in
            guard let self else { return }
            clear(skips)
            for folder in state.folders.selection.effectiveSkips {
                append(skips, hbox(spacing: 8, children: [icon("folder", size: 18), label(tildePath(folder), ellipsize: true),
                                                          spacer(), iconButton("list-remove-symbolic", tooltip: "Search it") {
                                                              self.state.folders.unskip(folder)
                                                          }]))
            }
        }
        let types = entry(placeholder: "e.g. heic, txt", text: state.skippedTypesText)
        on(types, "changed") { [weak self] in self?.state.skippedTypesText = entryText(types) }
        on(types, "activate") { [weak self] in
            guard let self else { return }
            state.folders.setTypes(state.skippedTypesText)
        }
        let skipBody = vbox(spacing: 10, children: [
            skips, hbox(children: [button("＋ Skip a Folder…") { [weak self] in self?.state.skipFolders(from: window) }]),
            hbox(spacing: 8, children: [label("File types"), types]),
            label("Code, keys, certificates, hidden folders and caches are always skipped.", "dim", wrap: true),
        ])
        let expander = gtk_expander_new("Skip some folders or file types")!
        gtk_expander_set_child(cast(expander), skipBody)
        gtk_expander_set_expanded(cast(expander), !state.folders.selection.effectiveSkips.isEmpty
                                  || !state.folders.types.isEmpty ? 1 : 0)
        return vbox(spacing: 18, children: [
            stepTitle("What should DigUp search?", "Pick folders, or open one to pick some of its subfolders. You can "
                      + "change this anytime in Settings."),
            scrolled(vbox(spacing: 6, children: [list, expander])),
            label("ⓘ DigUp only reads files: it never changes, moves or uploads them.", "dim", wrap: true),
        ])
    }

    private func code(_ window: Widget) -> Widget {
        let body = vbox(spacing: 10)
        let list = folderList(state.codeFolders, addTitle: "Add Folder…") { [weak self] in
            self?.state.addCodeFolders(from: window)
        }
        let editors = CodeEditor.installed + [CodeEditor.defaultApp]
        let names = editors.map { strdup($0.name) } + [nil]
        let picker = gtk_drop_down_new_from_strings(names.map { UnsafePointer($0) })!
        names.forEach { free($0) }
        gtk_drop_down_set_selected(cast(picker), UInt32(editors.firstIndex { $0.id == CodeEditor.current.id } ?? editors.count - 1))
        on(picker, "notify::selected") { [weak self] _ in
            let index = Int(gtk_drop_down_get_selected(cast(picker)))
            if index < editors.count { self?.app.setCodeEditor(editors[index].id) }
        }
        append(body, scrolled(vbox(spacing: 6, children: [list, codeFolderNote()])),
               hbox(spacing: 10, children: [label("Open code in"), picker]))
        watch(body) { [weak self] in
            guard let self else { return }
            setVisible(body, state.searchCode)
        }
        return vbox(spacing: 16, children: [
            stepTitle("Search your code too?", "DigUp can find code by what it does: type code: in the search panel, as "
                      + "in “code: retry with backoff”. It gets an index of its own and never shows up in other "
                      + "searches. You can turn it on later in Settings → Code."),
            switchRow("Search my code", detail: "Off unless you turn it on.", on: state.searchCode) { [weak self] on in
                self?.state.searchCode = on
            },
            body,
        ])
    }

    private func shortcut() -> Widget {
        let (recorder, _) = shortcutRecorder(app)
        gtk_widget_set_halign(recorder, GTK_ALIGN_CENTER)
        let tryIt = label("", "dim", wrap: true, xalign: 0.5)
        watch(tryIt) { [weak self] in
            guard let self else { return }
            if state.hotkeyWorked {
                setText(tryIt, "✓ That's it. It works from any app.")
            } else if let hotkey = state.model.hotkey {
                setText(tryIt, DesktopShortcut.canInstall
                    ? "Try it now: press \(hotkey.display)."
                    : "Add \(hotkey.display) as a custom shortcut in your desktop's keyboard settings, running\n"
                        + "\(DesktopShortcut.command)\nthen try it.")
            }
        }
        gtk_label_set_selectable(cast(tryIt), 1)
        let tips = vbox(spacing: 9, children: [label("IN THE SEARCH PANEL", "faint")])
        for (keys, text) in [("↩", "Open the file"), ("Ctrl+↩", "Show it in Files"),
                             ("Space", "Quick Look, after arrowing to a result"), ("Ctrl+C", "Copy the file, to paste anywhere"),
                             ("Esc", "Close")] {
            append(tips, hbox(spacing: 10, children: [label(keys, "keycap"), label(text)]))
        }
        if let combo = app.model.hotkey { DesktopShortcut.install(combo) }
        return centered(vbox(spacing: 18, children: [
            stepTitle("Open DigUp from anywhere", "Press the shortcut in any app, describe what you're looking for, and "
                      + "press Return."), recorder, tryIt, tips,
        ]))
    }

    private func ready() -> Widget {
        let note = label("", "dim", wrap: true, xalign: 0.5)
        watch(note) { [weak self] in
            guard let self else { return }
            let seconds = state.folders.totalSeconds, later = state.folders.totalLaterSeconds
            let time = seconds > 0 ? " (about \(roughDuration(seconds)) on this computer)" : ""
            let rest = later >= 30 ? " Long PDFs and documents get their first pages in that time, and the rest "
                + "afterwards (about \(roughDuration(later)) more)." : ""
            setText(note, state.download.isReady
                ? "DigUp is reading your folders\(time), newest files first. You can search right away; results fill in "
                    + "as it goes." + rest
                : "DigUp starts reading your folders\(time) once the model has downloaded "
                    + "(\(state.download.progressText)). Until then, search finds files by name." + rest)
        }
        let switches = vbox(spacing: 12, children: [
            switchRow("Open DigUp when you log in", detail: "So the shortcut always works.", on: state.launchAtLogin) {
                [weak self] on in self?.state.launchAtLogin = on
            },
            switchRow(AppSettings.batteryTitle, detail: AppSettings.batteryDetail, on: state.indexOnBattery) {
                [weak self] on in self?.state.indexOnBattery = on
            },
        ])
        return centered(vbox(spacing: 14, children: [
            icon("emblem-ok-symbolic", size: 60), label("You're all set", "hero", xalign: 0.5), note, switches,
            label("“DigUp” in your apps opens the search window; its ☰ menu shows how indexing is going.", "dim",
                  wrap: true, xalign: 0.5),
        ]))
    }
}
