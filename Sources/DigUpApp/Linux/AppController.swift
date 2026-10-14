import CGtk
import DigUpKit
import Foundation

/// Owns the app's parts (engine, model download, panel, windows, menu) and carries out what they ask for: new folders,
/// a new hotkey, opening at login, which window to show. The Mac's AppController, with GTK windows and the desktop's
/// ways of doing things.
final class AppController {
    let model: AppModel
    let engine: Engine
    let download: ModelDownload
    let updates: Updates
    private let power: PowerPolicy
    private(set) var panel: SearchPanelController!
    private(set) var searchWindow: SearchWindowController!
    private(set) var settingsWindow: SettingsWindowController!
    private(set) var statusMenu: StatusMenuController!
    private(set) var onboarding: OnboardingController?
    /// Set while onboarding's shortcut step waits for you to try the hotkey: a press goes there, not to the panel.
    var hotkeyTester: (() -> Void)?

    init(settings: AppSettings) {
        let download = ModelDownload(folder: settings.modelsDirectory)
        let model = AppModel(settings: settings, download: download)
        var engineRef: Engine?
        let power = PowerPolicy(indexOnBattery: settings.indexOnBattery) { blocker in
            engineRef?.setBackfillBlocker(blocker)
        }
        log("power: \(PowerPolicy.onACPower() ? "AC" : "battery"), backfill \(power.blocker.map { "waits (\($0))" } ?? "may run")")
        let engine = Engine(settings: settings, backfillBlocker: power.blocker) { status in
            let before = model.statusLine
            model.status = status
            if model.statusLine != before { log("status: \(model.statusLine)") }
        }
        engineRef = engine
        self.download = download
        self.model = model
        self.power = power
        self.engine = engine
        updates = Updates(model: model)
    }

    /// `showWindow`: opened by hand (not at login), so the search window comes up once the app is set up.
    func start(showWindow: Bool) {
        statusMenu = StatusMenuController(model: model)
        panel = SearchPanelController(app: self)
        searchWindow = SearchWindowController(app: self)
        settingsWindow = SettingsWindowController(app: self)
        statusMenu.onSearch = { [weak self] in self?.panel.show() }
        statusMenu.onOpenWindow = { [weak self] in self?.showSearchWindow() }
        statusMenu.onSettings = { [weak self] in self?.showSettings() }
        statusMenu.onChooseFolders = { [weak self] in self?.chooseFolders() }
        statusMenu.onPauseChanged = { [weak self] paused in self?.engine.setPaused(paused) }
        statusMenu.onCheckForUpdates = { [weak self] in self?.updates.checkNow() }
        statusMenu.onQuit = { g_application_quit(cast(DigUpGtk.application!)) }
        updates.onSessionEnded = { [weak self] in self?.windowClosed() }
        updates.start()

        if let combo = KeyCombo(model.settings.hotkey) {
            model.hotkey = combo
            log("hotkey \(combo.display) (the desktop runs \(DesktopShortcut.command))")
        } else {
            log("hotkey: can't read \"\(model.settings.hotkey)\" (try ctrl+alt+space)")
        }

        CodeEditor.current = CodeEditor.chosen(model.settings.codeEditor)
        download.onReady = { [weak self] in self?.engine.modelArrived() }
        engine.start()
        let settings = model.settings
        if !settings.onboarded, settings.roots.isEmpty {
            showOnboarding()
        } else {
            // Set up already (the go-ahead came with onboarding), so a missing model just downloads.
            if !download.isReady { download.start() }
            if showWindow { showSearchWindow() }
        }
    }

    /// The hotkey's command (`digup-app --toggle`): the panel, or onboarding's "try it now".
    func hotkeyPressed() {
        if let hotkeyTester { hotkeyTester() } else { panel.toggle() }
    }

    // MARK: Folders

    /// The folders to index from now on, and those to skip in them (and the file types, when given); the engine
    /// follows without a relaunch. A folder another chosen one already searches is dropped (its files would be found
    /// twice), and so is a skip with nothing around it to skip from (`FolderSelection`).
    func applyFolders(_ roots: [URL], excluded: [URL]? = nil, types: [String]? = nil) {
        let selection = FolderSelection(chosen: roots.map { AppSettings.folderURL($0.path).path },
                                        skipped: (excluded ?? model.settings.excludedFolders).map(\.path))
        let roots = selection.folders.map(AppSettings.folderURL)
        let excluded = selection.effectiveSkips.map(AppSettings.folderURL)
        let types = types ?? model.settings.excludedTypes
        if roots.count < selection.chosen.count {
            log("folders: \(selection.chosen.count - roots.count) inside another chosen folder, already covered")
        }
        let settings = model.settings
        guard roots != settings.roots || excluded != settings.excludedFolders || types != settings.excludedTypes
        else { return }
        AppSettings.save(roots: roots)
        AppSettings.save(excludedFolders: excluded)
        AppSettings.save(excludedTypes: types)
        model.settings.roots = roots
        model.settings.excludedFolders = excluded
        model.settings.excludedTypes = types
        engine.setFolders(roots: roots, excluded: excluded, excludedTypes: types)
    }

    func removeFolder(_ root: URL) {
        applyFolders(model.settings.roots.filter { $0.path != root.path })
    }

    func setExcluded(_ folders: [URL]) {
        AppSettings.save(excludedFolders: folders)
        model.settings.excludedFolders = folders
        engine.setFolders(roots: model.settings.roots, excluded: folders, excludedTypes: model.settings.excludedTypes)
    }

    /// File extensions never to index ("heic, .txt"); files of those types already indexed leave the index.
    func setExcludedTypes(_ text: String) {
        let types = IndexOptions.extensions(text).sorted()
        guard types != model.settings.excludedTypes else { return }
        AppSettings.save(excludedTypes: types)
        model.settings.excludedTypes = types
        engine.setFolders(roots: model.settings.roots, excluded: model.settings.excludedFolders, excludedTypes: types)
    }

    // MARK: Code search

    func applyCodeFolders(_ roots: [URL], excluded: [URL]) {
        let selection = FolderSelection(chosen: roots.map { AppSettings.folderURL($0.path).path },
                                        skipped: excluded.map(\.path))
        let roots = selection.folders.map(AppSettings.folderURL)
        let excluded = selection.effectiveSkips.map(AppSettings.folderURL)
        guard roots != model.settings.codeRoots || excluded != model.settings.codeExcluded else { return }
        AppSettings.save(codeRoots: roots, excluded: excluded)
        model.settings.codeRoots = roots
        model.settings.codeExcluded = excluded
        engine.setCodeFolders(roots: roots, excluded: excluded)
    }

    func removeCodeFolder(_ root: URL) {
        applyCodeFolders(model.settings.codeRoots.filter { $0.path != root.path },
                         excluded: model.settings.codeExcluded.filter { !FolderSelection.isInside($0.path, root.path) })
    }

    /// The editor code results open in (a command; "" for each file's default app).
    func setCodeEditor(_ id: String) {
        AppSettings.save(codeEditor: id)
        model.settings.codeEditor = id
        CodeEditor.current = CodeEditor.chosen(id)
        log("code results open in \(CodeEditor.current.name)")
    }

    func setIndexOnBattery(_ on: Bool) {
        AppSettings.save(indexOnBattery: on)
        model.settings.indexOnBattery = on
        power.setIndexOnBattery(on)
    }

    /// Asks for folders with the desktop's folder chooser (over `window` when there's one). `-debugPickFolders a:b`
    /// answers instead (test runs have no one to click).
    func pickFolders(for window: Widget?, prompt: String = "Add", then done: @escaping @MainActor ([URL]) -> Void) {
        if let answer = UserDefaults.standard.string(forKey: "debugPickFolders") {
            return done(answer.split(separator: ":").map { AppSettings.folderURL(String($0)) })
        }
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, "Choose folders for DigUp to search")
        gtk_file_dialog_set_accept_label(dialog, prompt)
        let box = Unmanaged.passRetained(FolderPick(done)).toOpaque()
        gtk_file_dialog_select_multiple_folders(dialog, window.map { cast($0) }, nil, { source, result, data in
            let pick = Unmanaged<FolderPick>.fromOpaque(data!).takeRetainedValue()
            var urls: [URL] = []
            if let files = gtk_file_dialog_select_multiple_folders_finish(OpaquePointer(source), result, nil) {
                for index in 0..<g_list_model_get_n_items(files) {
                    guard let file = g_list_model_get_item(files, index) else { continue }
                    if let path = g_file_get_path(OpaquePointer(file)) {
                        urls.append(AppSettings.folderURL(String(cString: path)))
                        g_free(path)
                    }
                    unref(file)
                }
                unref(files)
            }
            MainActor.assumeIsolated { pick.done(urls) }
        }, box)
        unref(dialog)
    }

    /// No folders yet: onboarding if it never ran, else Settings' folder list with Add Folders open.
    func chooseFolders() {
        guard model.settings.onboarded else { return showOnboarding() }
        showSettings(.folders)
        settingsWindow.addFolders()
    }

    /// Settings → Code with its folders' chooser open.
    func chooseCodeFolders() {
        showSettings(.code)
        settingsWindow.addCodeFolders()
    }

    // MARK: Hotkey

    /// Nil when `combo` is now the hotkey, else why it can't be. Where DigUp can set the desktop's shortcut itself
    /// (GNOME) it does; elsewhere Settings shows the command to bind.
    func setHotkey(_ combo: KeyCombo) -> String? {
        AppSettings.save(hotkey: combo.spec)
        model.settings.hotkey = combo.spec
        model.hotkey = combo
        log("hotkey: \(combo.display)")
        DesktopShortcut.install(combo)
        return nil
    }

    // MARK: Opening at login

    var launchesAtLogin: Bool { Desktop.launchesAtLogin }

    /// Dev builds (anything run from a source checkout's build folders) don't suggest it.
    var suggestsLaunchAtLogin: Bool { !Desktop.appBinary.path.contains("/.build/") }

    /// Nil when done, else why it failed.
    func setLaunchAtLogin(_ on: Bool) -> String? {
        guard on != launchesAtLogin else { return nil }
        return Desktop.setLaunchAtLogin(on)
    }

    // MARK: Windows

    func showSearchWindow(query: String? = nil, kind: ResultGroupKind? = nil) {
        searchWindow.show(query: query, kind: kind)
    }

    func showSettings(_ tab: SettingsTab = .general) {
        settingsWindow.show(tab)
    }

    func showOnboarding() {
        let onboarding = self.onboarding ?? OnboardingController(app: self)
        self.onboarding = onboarding
        onboarding.show()
    }

    /// Onboarding closed: by Done, or by its close button. Folders chosen by then count as set up.
    func onboardingClosed() {
        hotkeyTester = nil
        if model.hasFolders {
            AppSettings.saveOnboarded()
            model.settings.onboarded = true
        }
        onboarding = nil
        windowClosed()
    }

    /// A window closed: once none is left, the pictures made for them that are old go.
    func windowClosed() {
        DispatchQueue.main.async { [self] in
            let open = [searchWindow?.isVisible, settingsWindow?.isVisible, onboarding?.isVisible, panel?.isVisible]
                .contains { $0 == true }
            if !open { Pictures.trim() }
        }
    }
}

private final class FolderPick {
    let done: @MainActor ([URL]) -> Void
    init(_ done: @escaping @MainActor ([URL]) -> Void) { self.done = done }
}
