import CGtk
import DigUpKit
import Foundation

/// `digup-app`: one copy runs (GApplication, over D-Bus), and running it again tells that copy what to do:
///
///     digup-app               the search window (or onboarding the first time)
///     digup-app --toggle      the search panel, shown or hidden: what the desktop's shortcut runs
///     digup-app --window      the search window       digup-app --settings   Settings
///     digup-app --status      the status menu         digup-app --quit       quit
///     digup-app --background  start without a window (at login)
///
/// Launch arguments in the Mac's form (`-roots ~/DigUpTestbed/real -indexDir … -defaultsSuite …`) override settings
/// without saving them, as on a Mac; a run with its own `-defaultsSuite` is a separate copy from the installed one.
@main
enum DigUpMain {
    nonisolated(unsafe) static var controller: AppController?

    static func main() {
        signal(SIGPIPE, SIG_IGN)   // a helper that just exited must surface as a write error, not kill the app
        setlocale(LC_ALL, "")
        let suite = UserDefaults.standard.string(forKey: "defaultsSuite")
        let id = "io.github.arahim3.DigUp" + (suite.map { "." + $0.filter { $0.isLetter || $0.isNumber } } ?? "")
        let application = gtk_application_new(id, G_APPLICATION_HANDLES_COMMAND_LINE)!
        DigUpGtk.application = application
        onCommandLine(application) { arguments in
            handle(arguments)
            return 0
        }
        // GApplication sees only DigUp's own --flags; the Mac-style `-key value` settings are UserDefaults'.
        let flags = [CommandLine.arguments[0]] + CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") }
        var argv = flags.map { strdup($0) }
        let status = g_application_run(cast(application), Int32(argv.count), &argv)
        argv.forEach { free($0) }
        exit(status)
    }

    /// The first run starts the app; later ones (from the shortcut, the launcher) say what to show.
    private static func handle(_ arguments: [String]) {
        let flags = Set(arguments.dropFirst())
        let starting = controller == nil
        if starting { launch(showWindow: flags.isEmpty) }
        guard let app = controller else { return }
        if flags.contains("--quit") { return g_application_quit(cast(DigUpGtk.application!)) }
        if flags.contains("--toggle") { app.hotkeyPressed() }
        if flags.contains("--window") { app.showSearchWindow() }
        if flags.contains("--settings") { app.showSettings() }
        if flags.contains("--status") { app.statusMenu.show() }
        if flags.contains("--debug-menu") { print(app.statusMenu.describeMenu()) }
        if !starting, flags.isEmpty { app.showSearchWindow() }   // opened again from the launcher
    }

    private static func launch(showWindow: Bool) {
        // The app lives on with no window open, like the Mac's menubar app.
        g_application_hold(cast(DigUpGtk.application!))
        digup_attach_main_queue()
        DigUpGtk.loadStyle()
        let settings = AppSettings.load()
        AppLog.shared.open(in: settings.indexDirectory)
        log("launch pid \(getpid()): roots \(settings.roots.map { tildePath($0.path) }) · "
            + "index \(tildePath(settings.indexDirectory.path)) · models \(tildePath(settings.modelsDirectory.path))")
        Opener.dryRun = UserDefaults.standard.string(forKey: "debugOpen") == "dry"
        PreviewPlayback.shared.muted = UserDefaults.standard.bool(forKey: "debugMute")
        let app = AppController(settings: settings)
        controller = app
        app.start(showWindow: showWindow)
        DebugHooks.run(app)
    }
}
