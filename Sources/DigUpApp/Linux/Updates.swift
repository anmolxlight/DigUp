import CGtk
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The update check. On a Mac Sparkle reads the appcast and installs; Linux has no one way to install an app, so
/// here DigUp reads the same appcast once a day (the Mac's `SUFeedURL`) and, when there's a newer version, says so
/// in the menu and the window's status bar, as the Mac does; opening it shows what's new and the release's page.
final class Updates {
    static let feed = URL(string: "https://raw.githubusercontent.com/ARahim3/DigUp/main/appcast.xml")!
    static let releases = URL(string: "https://github.com/ARahim3/DigUp/releases/latest")!
    private let model: AppModel
    private var timer: DispatchSourceTimer?
    private var latest: (version: String, notes: String)?
    var onSessionEnded: () -> Void = {}

    init(model: AppModel) {
        self.model = model
    }

    /// This build's version: the `VERSION` file scripts/build-linux.sh puts next to the binary.
    static let version: String = {
        let file = Bundle.main.bundleURL.appendingPathComponent("VERSION")
        return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev"
    }()

    /// Dev and test runs (their own defaults suite) don't check. `-debugUpdates YES` lets one check anyway.
    func start() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "defaultsSuite") == nil || defaults.bool(forKey: "debugUpdates") else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 86_400, leeway: .seconds(600))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.automaticallyChecks else { return }
                self.check(showing: false)
            }
        }
        timer.resume()
        self.timer = timer
        log("updates: \(automaticallyChecks ? "checking daily" : "automatic checks off") at \(Self.feed.absoluteString)")
    }

    var automaticallyChecks: Bool {
        get { AppSettings.defaults.object(forKey: "checkForUpdates") == nil || AppSettings.defaults.bool(forKey: "checkForUpdates") }
        set { AppSettings.defaults.set(newValue, forKey: "checkForUpdates") }
    }

    /// "Check for Updates…" and the waiting update's menu item: the answer, in a window.
    func checkNow() {
        if let latest, model.updateAvailable != nil { return showWindow(latest) }
        check(showing: true)
    }

    private func check(showing: Bool) {
        URLSession.shared.dataTask(with: Self.feed) { data, _, error in
            let found = data.flatMap { Self.newest(in: String(decoding: $0, as: UTF8.self)) }
            let problem = error.map { "\($0.localizedDescription)" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.checked(found, problem: problem, showing: showing) }
            }
        }.resume()
    }

    private func checked(_ found: (version: String, notes: String)?, problem: String?, showing: Bool) {
        guard let found else {
            log("updates: \(problem ?? "no versions in the appcast")")
            if showing { showWindow(nil, problem: problem ?? "The update feed couldn't be read.") }
            return
        }
        latest = found
        if Self.isNewer(found.version, than: Self.version) {
            log("updates: \(found.version) is available; waiting in the menu")
            model.updateAvailable = found.version
            if showing { showWindow(found) }
        } else {
            log("updates: up to date")
            if showing { showWindow(nil) }
        }
    }

    /// The newest item's version and what's new in it (its description, tags removed).
    nonisolated static func newest(in appcast: String) -> (version: String, notes: String)? {
        var best: (String, String)?
        for item in appcast.components(separatedBy: "<item>").dropFirst() {
            guard let version = between(item, "<sparkle:shortVersionString>", "</sparkle:shortVersionString>") else { continue }
            let notes = (between(item, "<description><![CDATA[", "]]></description>") ?? "")
                .replacingOccurrences(of: "<li>", with: "• ")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if best.map({ isNewer(version, than: $0.0) }) ?? true { best = (version, notes) }
        }
        return best
    }

    private nonisolated static func between(_ text: String, _ start: String, _ end: String) -> String? {
        guard let from = text.range(of: start), let to = text.range(of: end, range: from.upperBound..<text.endIndex)
        else { return nil }
        return String(text[from.upperBound..<to.lowerBound])
    }

    /// "0.10.0" is newer than "0.9.1"; anything is newer than a dev build.
    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        guard !b.isEmpty, current != "dev" else { return true }
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return false
    }

    private func showWindow(_ update: (version: String, notes: String)?, problem: String? = nil) {
        let window = DigUpLinux.window("Software Update", width: 460, height: -1)
        let content = vbox(spacing: 12)
        margins(content, 20)
        if let update {
            append(content, label("DigUp \(update.version) is available", "title-2"),
                   label("You have \(Self.version).", "dim"), label(update.notes, wrap: true),
                   hbox(spacing: 8, children: [spacer(), button("Later") { gtk_window_destroy(cast(window)) },
                                               button("Open the Release Page", "suggested-action") {
                                                   Desktop.open(Self.releases)
                                                   gtk_window_destroy(cast(window))
                                               }]))
        } else {
            append(content, label(problem == nil ? "DigUp is up to date" : "Couldn't check for updates", "title-2"),
                   label(problem ?? "\(Self.version) is the newest version.", "dim", wrap: true),
                   hbox(children: [spacer(), button("OK", "suggested-action") { gtk_window_destroy(cast(window)) }]))
        }
        on(window, "destroy") { [weak self] in self?.onSessionEnded() }
        gtk_window_set_child(cast(window), content)
        present(window)
    }
}
