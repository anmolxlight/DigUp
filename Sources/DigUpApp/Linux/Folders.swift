import CGtk
import DigUpKit
import Foundation

extension FileKind {
    /// "1 screenshot", "25 PDFs", "6 audio files"
    func counted(_ count: Int) -> String {
        let one = count == 1
        let noun = switch self {
        case .screenshot: one ? "screenshot" : "screenshots"
        case .image: one ? "image" : "images"
        case .pdf: one ? "PDF" : "PDFs"
        case .doc: one ? "document" : "documents"
        case .audio: one ? "audio file" : "audio files"
        case .video: one ? "video" : "videos"
        case .code: one ? "code file" : "code files"
        }
        return "\(count.formatted()) \(noun)"
    }
}

/// "136 screenshots · 104 images · 25 PDFs"
func kindCounts(_ counts: [FileKind: Int]) -> String {
    FileKind.allCases.compactMap { kind in counts[kind].flatMap { $0 > 0 ? kind.counted($0) : nil } }
        .joined(separator: " · ")
}

/// The folder list onboarding and Settings share (the Mac's `FolderList`): folders with a checkbox, what's in them and
/// how long their first pass takes, each opening to its subfolders; then a button that adds another folder, and a note
/// when a folder picked didn't change anything. It follows `choices` as estimates arrive and boxes are clicked.
func folderList(_ choices: FolderChoices, addTitle: String, add: @escaping @MainActor () -> Void) -> Widget {
    let list = vbox(spacing: 6)
    watch(list) {
        clear(list)
        for row in choices.rows { append(list, folderRow(choices, row)) }
        let more = button("＋ " + addTitle, "flat", action: add)
        append(list, more)
        if let note = choices.note { append(list, label("ⓘ " + note, "dim", wrap: true)) }
    }
    return list
}

private func folderRow(_ choices: FolderChoices, _ row: URL) -> Widget {
    let estimate = choices.estimates[row.path]
    let mark = choices.mark(row)
    let subfolders = estimate?.subfolders ?? []
    let open = choices.expanded.contains(row.path) && !subfolders.isEmpty
    // Off, a folder shows all it holds (what checking it would take); else what's searched of it.
    let part = mark == .off ? estimate.map { estimate -> FolderChoices.Part in
        var part = FolderChoices.Part()
        part.add(estimate)
        return part
    } : choices.searchedPart(of: row)

    let chevron = gtk_button_new_from_icon_name(open ? "pan-down-symbolic" : "pan-end-symbolic")!
    gtk_widget_add_css_class(chevron, "flat")
    gtk_widget_set_opacity(chevron, subfolders.isEmpty ? 0 : 1)
    gtk_widget_set_sensitive(chevron, subfolders.isEmpty ? 0 : 1)
    setTooltip(chevron, open ? "Hide its subfolders" : "Choose among its subfolders")
    on(chevron, "clicked") { choices.toggleExpanded(row) }
    let check = checkbox(mark) { choices.toggle(row) }
    let detail: String
    if let estimate, estimate.failed {
        detail = "Couldn't look inside it; it can still be searched."
    } else if let estimate, !estimate.readable {
        detail = "DigUp can't read it (check its permissions)."
    } else if let part, !part.files.isEmpty {
        detail = kindCounts(part.files)
    } else {
        detail = estimate == nil ? tildePath(row.path)
            : estimate!.files.isEmpty ? (choices.code ? "No code here" : "Nothing to search here yet")
            : "Nothing to search in the subfolders checked"
    }
    let texts = vbox(spacing: 2, children: [label(row.lastPathComponent, "row-title"), label(detail, "dim", ellipsize: true)])
    gtk_widget_set_hexpand(texts, 1)
    let time = vbox(spacing: 1)
    if let estimate {
        append(time, label(estimate.files.isEmpty ? "—" : approximately(part?.seconds ?? 0), xalign: 1))
        if choices.code, let bytes = part?.bytes, bytes > 0 {
            append(time, label(roughBytes(bytes), "faint", xalign: 1))
        } else if let later = part?.later, later >= 30 {
            append(time, label("+ \(roughDuration(later)) later", "faint", xalign: 1))
        }
        setTooltip(time, choices.code
            ? "How long reading this code takes, once, and about how much room its index needs. After that, only "
                + "what changes is read again."
            : "The first pass takes this long. Long PDFs and documents get their first pages in it, and the rest "
                + "afterwards, once everything else is in.")
        if mark == .off { gtk_widget_set_opacity(time, 0.5) }
    } else {
        let spinner = gtk_spinner_new()!
        gtk_spinner_start(cast(spinner))
        append(time, spinner)
    }
    let header = hbox(spacing: 8, children: [chevron, check, icon("folder", size: 28), texts, time])
    let card = vbox(spacing: 0, "card-row", children: [header])
    if open {
        for subfolder in subfolders.prefix(40) {
            let on = choices.isSearched(subfolder.folder)
            let name = (subfolder.folder as NSString).lastPathComponent
            let line = hbox(spacing: 8, children: [
                checkbox(on ? .on : .off) { choices.toggle(subfolder: subfolder.folder) }, icon("folder", size: 16),
                label(name, ellipsize: true), label(kindCounts(subfolder.files), "faint", ellipsize: true), spacer(),
                label(approximately(subfolder.seconds)
                      + (choices.code ? " · \(roughBytes(subfolder.bytes))"
                         : subfolder.laterSeconds >= 30 ? " + \(roughDuration(subfolder.laterSeconds)) later" : ""),
                      "dim"),
            ])
            gtk_widget_set_margin_start(line, 44)
            if !on { gtk_widget_set_opacity(line, 0.7) }
            append(card, line)
        }
    }
    if mark == .off { gtk_widget_set_opacity(header, 0.8) }
    return card
}

/// A checkbox that can show "some of it" (a folder with only some of its subfolders searched). A click asks for the
/// change; what it shows always comes from the model.
private func checkbox(_ mark: FolderSelection.Mark, _ toggle: @escaping @MainActor () -> Void) -> Widget {
    let check = gtk_check_button_new()!
    gtk_check_button_set_active(cast(check), mark == .on ? 1 : 0)
    gtk_check_button_set_inconsistent(cast(check), mark == .mixed ? 1 : 0)
    gtk_widget_set_valign(check, GTK_ALIGN_CENTER)
    on(check, "toggled") { DispatchQueue.main.async { toggle() } }   // after GTK's own toggle; the list redraws
    return check
}

/// Settings → Folders → Add Folders… (and Settings → Code's): onboarding's folder step in a dialog. It lists the
/// usual folders that aren't searched yet and any other folder you choose, each with what's in it, how long its first
/// pass takes and its subfolders; nothing changes until Add.
final class AddFoldersController {
    private unowned let app: AppController
    private var dialog: Widget?
    let code: Bool
    /// The folders changed (Settings refreshes its list).
    var onAdded: () -> Void = {}

    init(app: AppController, code: Bool = false) {
        self.app = app
        self.code = code
    }

    func begin(on parent: Widget?) {
        guard dialog == nil else { return }
        let settings = app.model.settings
        let selection = code
            ? FolderSelection(skipped: settings.codeExcluded.map(\.path), kept: settings.codeRoots.map(\.path))
            : FolderSelection(skipped: settings.excludedFolders.map(\.path), kept: settings.roots.map(\.path))
        let suggestions = (code ? CodeFolders.candidates(searched: settings.roots) : OnboardingState.candidates())
            .filter { !selection.isSearched($0.path) }
        let choices = FolderChoices(rows: suggestions, selection: selection, types: code ? [] : settings.excludedTypes,
                                    code: code)
        guard suggestions.isEmpty else { return present(choices, on: parent) }
        app.pickFolders(for: parent) { [weak self] picked in
            guard let self, !picked.isEmpty else { return }
            choices.add(picked)
            present(choices, on: parent)
        }
    }

    private func present(_ choices: FolderChoices, on parent: Widget?) {
        let dialog = DigUpLinux.window(code ? "Code Folders" : "Add Folders", width: 600, height: 560)
        gtk_window_set_modal(cast(dialog), 1)
        if let parent { gtk_window_set_transient_for(cast(dialog), cast(parent)) }
        let title = code
            ? stepTitle("Search your code", "Pick the folders that hold your projects; open one to pick among its repos. "
                + "DigUp reads each once, then what changes. Code is searched on its own: type code: in the search panel.")
            : stepTitle("Add folders to search", "DigUp reads a new folder once, then keeps up with what changes in it. "
                + "Open a folder to pick some of its subfolders.")
        let list = folderList(choices, addTitle: "Choose Another Folder…") { [weak self] in
            self?.app.pickFolders(for: dialog) { picked in if !picked.isEmpty { choices.add(picked) } }
        }
        let scroll = vbox(spacing: 8, children: [list])
        if code { append(scroll, codeFolderNote()) }
        let summary = label("", "dim", wrap: true)
        gtk_widget_set_hexpand(summary, 1)
        let add = button("Add", "suggested-action") { [weak self] in
            guard let self else { return }
            log("add \(code ? "code " : "")folders: \(choices.roots.map { tildePath($0.path) })"
                + (choices.skipped.isEmpty ? "" : " minus \(choices.skipped.map { tildePath($0.path) })"))
            if code {
                app.applyCodeFolders(choices.roots, excluded: choices.skipped)
            } else {
                app.applyFolders(choices.roots, excluded: choices.skipped)
            }
            end()
            onAdded()
        }
        let footer = hbox(spacing: 12, children: [summary, button("Cancel") { [weak self] in self?.end() }, add])
        let content = vbox(spacing: 16, children: [title, scrolled(scroll), footer])
        margins(content, 20)
        gtk_window_set_child(cast(dialog), content)
        onClose(dialog) { [weak self] in
            self?.end()
            return true
        }
        watch(content) { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(add, choices.changesSomething ? 1 : 0)
            setText(summary, summaryText(choices))
        }
        self.dialog = dialog
        choices.startEstimates()
        log("add folders: \(choices.rows.count) to choose from")
        DigUpLinux.present(dialog)
    }

    private func summaryText(_ choices: FolderChoices) -> String {
        guard choices.changesSomething else { return "Check the folders to add" }
        guard choices.estimatesDone else { return "Looking at the folders…" }
        let time = choices.totalSeconds < 1 ? "under a second" : "about \(roughDuration(choices.totalSeconds))"
        if choices.code { return "Adds \(time) of indexing and \(roughBytes(choices.totalBytes))" }
        let later = choices.totalLaterSeconds
        return "Adds \(time) of indexing" + (later >= 30 ? ", and \(roughDuration(later)) more for long files" : "")
    }

    func end() {
        if let dialog { gtk_window_destroy(cast(dialog)) }
        dialog = nil
    }
}

/// A step's or a dialog's big title and the line under it.
func stepTitle(_ title: String, _ subtitle: String) -> Widget {
    vbox(spacing: 6, children: [label(title, "title-2", wrap: true), label(subtitle, "dim", wrap: true)])
}

/// What code search leaves out, under a list of code folders.
func codeFolderNote() -> Widget {
    label("ⓘ Code search reads source files, notebooks and a repo's own docs. It skips what git ignores, vendored and "
          + "generated code, data files, and anything that looks like a key or a password.", "dim", wrap: true)
}
