import DigUpKit
import Foundation

// What the Mac app asks of NSWorkspace, Carbon and ServiceManagement, done the freedesktop way: xdg-open, the
// FileManager1 D-Bus interface, the clipboard tools, ~/.config/autostart, and the desktop's own keyboard shortcuts.

enum Desktop {
    /// The first of `names` on PATH.
    nonisolated static func which(_ names: String...) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for name in names {
            for folder in path.split(separator: ":") where FileManager.default.isExecutableFile(atPath: "\(folder)/\(name)") {
                return "\(folder)/\(name)"
            }
        }
        return nil
    }

    /// Starts a program and leaves it running (an editor, a player, xdg-open). False when it couldn't start.
    @discardableResult
    nonisolated static func launch(_ program: String, _ arguments: [String], input: Data? = nil) -> Bool {
        guard let executable = program.hasPrefix("/") ? program : which(program) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = input.map { _ in Pipe() }
        process.standardInput = pipe ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log("can't start \(program): \(error)")
            return false
        }
        if let pipe, let input {
            try? pipe.fileHandleForWriting.write(contentsOf: input)
            try? pipe.fileHandleForWriting.close()
        }
        return true
    }

    /// A program's output, waited for (short queries only: xdg-mime, gsettings).
    nonisolated static func output(_ program: String, _ arguments: [String]) -> String? {
        guard let executable = which(program) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The file (or a link) in the app the desktop opens it with.
    static func open(_ url: URL) {
        log("open: \(url.isFileURL ? url.lastPathComponent : url.absoluteString)" + (Opener.dryRun ? " (dry run)" : ""))
        guard !Opener.dryRun else { return }
        if !launch("xdg-open", [url.isFileURL ? url.path : url.absoluteString]) {
            launch("gio", ["open", url.isFileURL ? url.path : url.absoluteString])
        }
    }

    /// The file manager, with the file selected (org.freedesktop.FileManager1, which Nautilus, Dolphin, Nemo and
    /// Thunar answer); without one, its folder.
    static func reveal(_ url: URL) {
        log("reveal: \(url.lastPathComponent)" + (Opener.dryRun ? " (dry run)" : ""))
        guard !Opener.dryRun else { return }
        let shown = launch("dbus-send", ["--session", "--dest=org.freedesktop.FileManager1", "--type=method_call",
                                         "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1.ShowItems",
                                         "array:string:\(url.absoluteString)", "string:"])
        if !shown { launch("xdg-open", [url.deletingLastPathComponent().path]) }
    }

    /// The file on the clipboard as a file (text/uri-list), the way a file manager copies it: paste into a folder, a
    /// chat or a mail. wl-copy on Wayland, xclip on X11. False when neither is installed.
    static func copy(_ url: URL) -> Bool {
        let list = Data((url.absoluteString + "\r\n").utf8)
        if ProcessInfo.processInfo.environment["WAYLAND_DISPLAY"] != nil, which("wl-copy") != nil {
            return launch("wl-copy", ["--type", "text/uri-list"], input: list)
        }
        return launch("xclip", ["-selection", "clipboard", "-t", "text/uri-list", "-i"], input: list)
    }

    /// The desktop's default app for a file ("org.gnome.Evince.desktop"), remembered by extension.
    static func defaultApp(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if let known = defaultApps[ext] { return known }
        let type = output("xdg-mime", ["query", "filetype", url.path])
        let app = type.flatMap { output("xdg-mime", ["query", "default", $0]) } ?? ""
        defaultApps[ext] = app
        return app.isEmpty ? nil : app
    }

    private static var defaultApps: [String: String] = [:]

    // MARK: Opening at login (the Mac's login item)

    private static var autostart: URL {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return config.appendingPathComponent("autostart/digup.desktop")
    }

    static var launchesAtLogin: Bool { FileManager.default.fileExists(atPath: autostart.path) }

    /// Nil when done, else why not.
    static func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on {
                try FileManager.default.createDirectory(at: autostart.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let entry = """
                    [Desktop Entry]
                    Type=Application
                    Name=DigUp
                    Comment=Semantic file search
                    Exec="\(appBinary.path)" --background
                    Icon=digup
                    X-GNOME-Autostart-enabled=true
                    """
                try entry.write(to: autostart, atomically: true, encoding: .utf8)
            } else if launchesAtLogin {
                try FileManager.default.removeItem(at: autostart)
            }
            log("login item: \(on ? "on" : "off")")
            return nil
        } catch {
            log("login item: \(error)")
            return "\(error)"
        }
    }

    /// This program (`digup-app`).
    static var appBinary: URL {
        URL(fileURLWithPath: CommandLine.arguments[0].hasPrefix("/") ? CommandLine.arguments[0]
            : Bundle.main.executableURL?.path ?? CommandLine.arguments[0]).standardizedFileURL
    }
}

// MARK: The hotkey

/// The search panel's shortcut. X11 and Wayland differ in whether (and how) an app may grab a key for itself, so the
/// key is the desktop's own custom shortcut running `digup-app --toggle`: set up by DigUp on GNOME, by hand elsewhere.
/// Saved as on a Mac ("ctrl+alt+space"); "cmd" is the Super key here.
nonisolated struct KeyCombo: Equatable, Sendable {
    /// "ctrl+alt+space": how it's saved.
    let spec: String
    /// The keycaps, in order: ["Ctrl", "Alt", "Space"].
    let caps: [String]
    /// GTK's accelerator, what GNOME's settings take: "<Control><Alt>space".
    let accelerator: String
    var display: String { caps.joined(separator: "+") }

    private static let modifiers: [(names: Set<String>, spec: String, cap: String, accelerator: String)] = [
        (["ctrl", "control", "⌃"], "ctrl", "Ctrl", "<Control>"),
        (["opt", "option", "alt", "⌥"], "alt", "Alt", "<Alt>"),
        (["shift", "⇧"], "shift", "Shift", "<Shift>"),
        (["cmd", "command", "super", "meta", "⌘"], "super", "Super", "<Super>"),
    ]

    /// Parses "ctrl+alt+space", "super+shift+d", "f12"…
    init?(_ text: String) {
        var held = Set<String>()
        var key: String?
        for part in text.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " }) {
            if let modifier = Self.modifiers.first(where: { $0.names.contains(String(part)) }) {
                held.insert(modifier.spec)
            } else {
                guard key == nil else { return nil }
                key = String(part)
            }
        }
        guard let key else { return nil }
        self.init(key: key, held: held)
    }

    /// From a key press in the shortcut recorder: GDK's key name ("space", "d", "F5") and which modifiers are held.
    init?(keyName: String, ctrl: Bool, alt: Bool, shift: Bool, superKey: Bool) {
        var held = Set<String>()
        if ctrl { held.insert("ctrl") }
        if alt { held.insert("alt") }
        if shift { held.insert("shift") }
        if superKey { held.insert("super") }
        self.init(key: keyName.lowercased(), held: held)
    }

    private init?(key: String, held: Set<String>) {
        let isFunctionKey = key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil
        let named = ["space", "return", "tab", "escape", "slash", "period", "comma", "semicolon", "grave", "minus",
                     "equal", "backslash", "apostrophe"]
        guard key.count == 1 && (key.first!.isLetter || key.first!.isNumber) || isFunctionKey || named.contains(key)
        else { return nil }
        // ⇧ alone would take a letter away from typing everywhere.
        guard !held.subtracting(["shift"]).isEmpty || isFunctionKey else { return nil }
        let used = Self.modifiers.filter { held.contains($0.spec) }
        spec = (used.map(\.spec) + [key]).joined(separator: "+")
        caps = used.map(\.cap) + [key.count == 1 || isFunctionKey ? key.uppercased() : key.capitalized]
        accelerator = used.map(\.accelerator).joined() + key
    }
}

/// The desktop's custom shortcut that runs `digup-app --toggle`. GNOME's (gsettings) is set up here; on other
/// desktops `install` says no, and Settings shows the command to bind by hand.
enum DesktopShortcut {
    private static let schema = "org.gnome.settings-daemon.plugins.media-keys"
    private static let path = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/digup/"

    static var command: String { "\"\(Desktop.appBinary.path)\" --toggle" }

    /// GNOME's settings are there to write to.
    static var canInstall: Bool {
        Desktop.output("gsettings", ["list-keys", schema])?.contains("custom-keybindings") == true
    }

    /// Makes `combo` run the toggle command. False where DigUp can't set shortcuts itself.
    @discardableResult
    static func install(_ combo: KeyCombo) -> Bool {
        guard canInstall else { return false }
        let listed = Desktop.output("gsettings", ["get", schema, "custom-keybindings"]) ?? "@as []"
        var paths = listed.replacingOccurrences(of: "@as", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
            .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '")) }
            .filter { !$0.isEmpty }
        if !paths.contains(path) { paths.append(path) }
        let relocatable = "\(schema).custom-keybinding:\(path)"
        let steps = [["set", schema, "custom-keybindings", "[" + paths.map { "'\($0)'" }.joined(separator: ", ") + "]"],
                     ["set", relocatable, "name", "DigUp"],
                     ["set", relocatable, "command", command],
                     ["set", relocatable, "binding", combo.accelerator]]
        let done = steps.allSatisfy { Desktop.output("gsettings", $0) != nil }
        log("hotkey: \(done ? "GNOME runs \(command) on \(combo.accelerator)" : "couldn't set GNOME's shortcut")")
        return done
    }
}

// MARK: Code editors

/// The editors code results open in, at the line that matched: each one's way of being told the line on its command
/// line. The one in use is a setting ("Open code in"); until it's set, the first one installed.
nonisolated struct CodeEditor: Identifiable, Hashable, Sendable {
    enum Method: Hashable, Sendable {
        /// `code --goto <path>:<line>:1` (VS Code and its relatives).
        case goto
        /// `zed <path>:<line>`, `subl <path>:<line>`.
        case colon
        /// JetBrains launchers: `--line <line> <path>`.
        case jetBrains
        /// `kate --line <line> <path>`.
        case kate
        /// `gedit +<line> <path>`, `gnome-text-editor +<line> <path>`.
        case plus
        /// The desktop's app for the file, at its start.
        case plain
    }

    let id: String       // the command
    let name: String
    let method: Method

    static let known: [CodeEditor] = [
        CodeEditor(id: "zed", name: "Zed", method: .colon),
        CodeEditor(id: "zeditor", name: "Zed", method: .colon),
        CodeEditor(id: "cursor", name: "Cursor", method: .goto),
        CodeEditor(id: "code", name: "Visual Studio Code", method: .goto),
        CodeEditor(id: "code-insiders", name: "VS Code Insiders", method: .goto),
        CodeEditor(id: "windsurf", name: "Windsurf", method: .goto),
        CodeEditor(id: "codium", name: "VSCodium", method: .goto),
        CodeEditor(id: "subl", name: "Sublime Text", method: .colon),
        CodeEditor(id: "pycharm", name: "PyCharm", method: .jetBrains),
        CodeEditor(id: "idea", name: "IntelliJ IDEA", method: .jetBrains),
        CodeEditor(id: "webstorm", name: "WebStorm", method: .jetBrains),
        CodeEditor(id: "clion", name: "CLion", method: .jetBrains),
        CodeEditor(id: "goland", name: "GoLand", method: .jetBrains),
        CodeEditor(id: "rustrover", name: "RustRover", method: .jetBrains),
        CodeEditor(id: "phpstorm", name: "PhpStorm", method: .jetBrains),
        CodeEditor(id: "rubymine", name: "RubyMine", method: .jetBrains),
        CodeEditor(id: "studio", name: "Android Studio", method: .jetBrains),
        CodeEditor(id: "kate", name: "Kate", method: .kate),
        CodeEditor(id: "gnome-text-editor", name: "Text Editor", method: .plus),
        CodeEditor(id: "gedit", name: "gedit", method: .plus),
    ]

    /// Each file opens in the desktop's app for it, at its start.
    static let defaultApp = CodeEditor(id: "", name: "The file's default app", method: .plain)

    /// Where code results open now (`AppController.setCodeEditor`).
    @MainActor static var current = defaultApp

    @MainActor static var installed: [CodeEditor] {
        var names = Set<String>()
        return known.filter { Desktop.which($0.id) != nil && names.insert($0.name).inserted }
    }

    /// The editor chosen in Settings (`id`), or the first installed one.
    @MainActor static func chosen(_ id: String?) -> CodeEditor {
        let installed = Self.installed
        if let id {
            if id.isEmpty { return defaultApp }
            if let editor = installed.first(where: { $0.id == id }) { return editor }
        }
        return installed.first ?? defaultApp
    }

    /// Opens `url` at `line` (from 1). Debug runs (`Opener.dryRun`) only say how.
    @MainActor func open(_ url: URL, line: Int) {
        let arguments: [String]
        switch method {
        case .goto: arguments = ["--goto", "\(url.path):\(line):1"]
        case .colon: arguments = ["\(url.path):\(line)"]
        case .jetBrains: arguments = ["--line", "\(line)", url.path]
        case .kate: arguments = ["--line", "\(line)", url.path]
        case .plus: arguments = ["+\(line)", url.path]
        case .plain: return Desktop.open(url)
        }
        log("open: \(url.lastPathComponent) in \(name), \(id) \(arguments.dropLast().joined(separator: " "))"
            + (Opener.dryRun ? " (dry run)" : ""))
        guard !Opener.dryRun else { return }
        if !Desktop.launch(id, arguments) { Desktop.open(url) }
    }
}

// MARK: The page or moment that matched

extension ResultRow {
    /// The PDF page that matched (1-based).
    var page: Int? {
        guard kind == .pdf, segment == .page || segment == .pageImage, let loc else { return nil }
        return Int(loc)
    }

    /// Seconds into a recording where the match starts.
    var moment: Double? {
        guard kind == .video || kind == .audio, segment == .frame || segment == .audio else { return nil }
        return loc
    }

    /// "Open at 0:06" when a player that can be told the moment is there (mpv, VLC), "Open at p. 3" for a PDF viewer
    /// that takes a page (Evince, Okular), else "Open". Code opens in the editor chosen for it: "Open in Zed".
    var openTitle: String {
        if kind == .code, !CodeEditor.current.id.isEmpty { return "Open in \(CodeEditor.current.name)" }
        if let moment, moment >= 1, Opener.player(for: url) != nil { return "Open at \(Self.clock(moment))" }
        if let page, page > 1, Opener.pdfViewer(for: url) != nil { return "Open at p. \(page)" }
        return "Open"
    }

    /// The line a code result opens at: where the name is defined or the query's words are, else where its stretch
    /// starts (a notebook's at its top: editors can't be told a cell).
    var codeLine: Int {
        segment == .lines ? max(1, Int(focus ?? loc ?? 1)) : 1
    }
}

extension Engine {
    /// Opens `row` in its app, at the page or moment that matched when the app can be told it (see `Opener`).
    func open(_ row: ResultRow) {
        if row.kind == .code { return CodeEditor.current.open(row.url, line: row.codeLine) }
        Opener.open(row)
    }
}

/// Opens a result in its app: a PDF at its page in Evince (`--page-index`) or Okular (`-p`), a recording at its
/// moment in mpv (`--start`) or VLC (`--start-time`); anything else, or without those, through xdg-open.
enum Opener {
    /// Debug runs (`-debugOpen dry`): say how it would open, and don't.
    static var dryRun = false

    /// The player a recording opens in at its moment: the default app when it's one that can be told where, else
    /// one that's installed.
    static func player(for url: URL) -> String? {
        pick(["mpv", "vlc"], default: Desktop.defaultApp(for: url))
    }

    static func pdfViewer(for url: URL) -> String? {
        pick(["evince", "okular"], default: Desktop.defaultApp(for: url))
    }

    private static func pick(_ programs: [String], default app: String?) -> String? {
        if let app = app?.lowercased(), let named = programs.first(where: { app.contains($0) }),
           Desktop.which(named) != nil {
            return named
        }
        return programs.first { Desktop.which($0) != nil }
    }

    static func open(_ row: ResultRow) {
        let moment = row.moment.flatMap { $0 >= 1 ? $0 : nil }
        let page = row.page.flatMap { $0 > 1 ? $0 : nil }
        var command: (String, [String])?
        if let moment, let player = player(for: row.url) {
            let seconds = String(format: "%.1f", moment)
            command = (player, player == "mpv" ? ["--start=\(seconds)", row.url.path]
                                               : ["--start-time=\(seconds)", row.url.path])
        } else if let page, let viewer = pdfViewer(for: row.url) {
            command = (viewer, viewer == "evince" ? ["--page-index=\(page)", row.url.path] : ["-p", "\(page)", row.url.path])
        }
        guard let (program, arguments) = command else { return Desktop.open(row.url) }
        log("open: \(row.name) in \(program) at \(row.place ?? "?")" + (dryRun ? " (dry run)" : ""))
        guard !dryRun else { return }
        if !Desktop.launch(program, arguments) { Desktop.open(row.url) }
    }
}
