import CGtk
import Foundation

/// The Mac's menubar menu: what's going on (with a progress bar), Search…, the window, Pause, Settings, Quit. GTK 4
/// has no tray, and desktops differ on whether they show one, so it's in the search window's ☰ button and in a small
/// window of its own (`digup-app --status`, the launcher's "Status" action), which a desktop shortcut or a panel
/// launcher can open.
final class StatusMenuController {
    private let model: AppModel
    var onSearch: () -> Void = {}
    var onOpenWindow: () -> Void = {}
    var onSettings: () -> Void = {}
    var onChooseFolders: () -> Void = {}
    var onPauseChanged: (Bool) -> Void = { _ in }
    var onCheckForUpdates: () -> Void = {}
    var onQuit: () -> Void = {}
    private var window: Widget?

    init(model: AppModel) {
        self.model = model
    }

    /// The menu, kept current: `done` runs after an item is chosen (a popover closes).
    func makeMenu(done: @escaping @MainActor () -> Void) -> Widget {
        let menu = vbox(spacing: 2)
        size(menu, width: 280)
        let title = label("", "row-title", ellipsize: true)
        let detail = label("", "dim", wrap: true)
        let bar = gtk_progress_bar_new()!
        let header = vbox(spacing: 4, children: [title, detail, bar])
        margins(header, 8)
        let items = vbox(spacing: 0)
        append(menu, header, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), items)
        watch { [weak self] in
            guard let self else { return }
            setText(title, model.statusLine)
            setText(detail, self.detail ?? "")
            setVisible(detail, self.detail != nil)
            setVisible(bar, model.progress != nil)
            gtk_progress_bar_set_fraction(cast(bar), model.progress ?? 0)
            clear(items)
            for item in self.items {
                guard let (name, action) = item else {
                    append(items, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
                    continue
                }
                let row = button(name, "flat") {
                    done()
                    action()
                }
                gtk_widget_set_halign(gtk_button_get_child(cast(row))!, GTK_ALIGN_START)
                append(items, row)
            }
        }
        return menu
    }

    /// The menu's items in order; nil is a separator.
    private var items: [(String, () -> Void)?] {
        var items: [(String, () -> Void)?] = []
        if let version = model.updateAvailable {
            items += [("Update to DigUp \(version)…", onCheckForUpdates), nil]
        }
        if !model.hasFolders { items.append(("Choose Folders to Search…", onChooseFolders)) }
        items.append(("Search…" + (model.hotkey.map { "    \($0.display)" } ?? ""), onSearch))
        items.append(("Open DigUp", onOpenWindow))
        if model.hasFolders {
            let paused = model.status.paused
            items += [nil, (paused ? "Resume Indexing" : "Pause Indexing", { [weak self] in self?.onPauseChanged(!paused) })]
        }
        switch model.download.phase {
        case .failed, .needed: items.append(("Download the Model", { [weak self] in self?.model.download.start() }))
        default: break
        }
        items += [nil, ("Settings…", onSettings)]
        if model.updateAvailable == nil { items.append(("Check for Updates…", onCheckForUpdates)) }
        items.append(("Quit DigUp", onQuit))
        return items
    }

    /// The top of the menu's second line: where, or how long.
    private var detail: String? {
        if model.download.isActive { return model.download.progressText }
        if case .failed(let message) = model.download.phase { return message }
        guard model.hasFolders else { return "Pick the folders it should search." }
        let missing = Set(model.status.missingRoots), unreadable = Set(model.status.unreadableRoots)
        let names = model.settings.roots.map { root in
            root.lastPathComponent + (missing.contains(root.path) ? " (not connected)"
                                      : unreadable.contains(root.path) ? " (no access)" : "")
        }
        return "In " + names.joined(separator: ", ")
    }

    /// The menu in a window of its own.
    func show() {
        if let window { return present(window) }
        let window = DigUpLinux.window("DigUp", width: 300, height: -1)
        gtk_window_set_resizable(cast(window), 0)
        onClose(window) {
            gtk_widget_set_visible(window, 0)
            return true
        }
        let menu = makeMenu { gtk_widget_set_visible(window, 0) }
        margins(menu, 6)
        gtk_window_set_child(cast(window), menu)
        onKey(window) { key, _ in
            guard Int32(key) == GDK_KEY_Escape else { return false }
            gtk_widget_set_visible(window, 0)
            return true
        }
        self.window = window
        present(window)
    }

    var isVisible: Bool { window.map { gtk_widget_get_visible($0) != 0 } ?? false }

    /// The menu as text, for `--debug-menu` (as the Mac's -debugMenu).
    func describeMenu() -> String {
        (["[\(model.statusLine)]"] + items.map { $0?.0 ?? "—" }).joined(separator: " | ")
    }
}
