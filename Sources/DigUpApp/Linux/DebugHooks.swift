import Foundation

/// Launch arguments for driving the app from a script (the Mac's DebugHooks, the few a Linux test run needs):
///
///     -debugPanel "query"     the search panel, with this typed
///     -debugWindow "query"    the search window, with this typed
///     -debugSettings folders  Settings, at a tab
///     -debugSelect 2          after the panel's final results, move the selection down this many rows
enum DebugHooks {
    static func run(_ app: AppController) {
        let defaults = UserDefaults.standard
        if let query = defaults.string(forKey: "debugPanel") {
            app.panel.show()
            app.panel.setQuery(query)
            let steps = defaults.integer(forKey: "debugSelect")
            app.panel.onFinalResults = { [weak app] in
                guard let panel = app?.panel else { return }
                if steps > 0 { panel.moveSelection(by: steps) }
                log("debug: panel shows \(panel.results.strongRows.count) results for \"\(query)\", "
                    + "selected \(panel.selectedRow?.name ?? "nothing")")
            }
        }
        if let query = defaults.string(forKey: "debugWindow") { app.showSearchWindow(query: query) }
        if let tab = defaults.string(forKey: "debugSettings").flatMap(SettingsTab.init(rawValue:)) { app.showSettings(tab) }
    }
}
