import CGtk
import Foundation
import Observation

// The few GTK conveniences the Linux views are written with. GTK's casts and g_signal_connect are C macros, so
// widgets travel as `Widget` (GtkWidget *) and `cast` turns them into the type a call wants.

typealias Widget = UnsafeMutablePointer<GtkWidget>

/// A GObject pointer as another GObject type (what GTK_WINDOW(), GTK_BOX()… do in C).
@inline(__always) func cast<T, U>(_ pointer: UnsafeMutablePointer<U>) -> UnsafeMutablePointer<T> {
    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: T.self)
}

@inline(__always) func cast<T>(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutablePointer<T> {
    pointer.assumingMemoryBound(to: T.self)
}

/// GTK's final types (GtkLabel, GtkBox…) come into Swift as opaque pointers.
@inline(__always) func cast<U>(_ pointer: UnsafeMutablePointer<U>) -> OpaquePointer { OpaquePointer(pointer) }
@inline(__always) func cast(_ pointer: OpaquePointer) -> OpaquePointer { pointer }
@inline(__always) func cast<T>(_ pointer: OpaquePointer) -> UnsafeMutablePointer<T> { UnsafeMutablePointer(pointer) }

func unref(_ object: some GObjectPointer) {
    g_object_unref(object.raw)
}

/// Anything a signal can be connected to.
protocol GObjectPointer { var raw: UnsafeMutableRawPointer { get } }
extension UnsafeMutablePointer: GObjectPointer { var raw: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) } }
extension OpaquePointer: GObjectPointer { var raw: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) } }
extension UnsafeMutableRawPointer: GObjectPointer { var raw: UnsafeMutableRawPointer { self } }

// MARK: Signals

/// A Swift closure as a signal handler's user data, released with the handler.
private nonisolated final class Handler<F>: @unchecked Sendable {
    let run: F
    init(_ run: F) { self.run = run }
}

private nonisolated func connect<F>(_ object: UnsafeMutableRawPointer, _ signal: String, _ run: F, _ callback: GCallback,
                                    after: Bool = false) {
    let data = Unmanaged.passRetained(Handler(run)).toOpaque()
    g_signal_connect_data(object, signal, callback, data, { data, _ in
        guard let data else { return }
        Unmanaged<AnyObject>.fromOpaque(data).release()
    }, after ? G_CONNECT_AFTER : GConnectFlags(rawValue: 0))
}

private nonisolated func handler<F>(_ data: gpointer?) -> F {
    Unmanaged<Handler<F>>.fromOpaque(data!).takeUnretainedValue().run
}

/// `signal` with no arguments of interest ("clicked", "changed", "activate", "toggled", "destroy"…).
func on(_ object: some GObjectPointer, _ signal: String, _ run: @escaping @MainActor () -> Void) {
    typealias F = @MainActor () -> Void
    let callback: @convention(c) (gpointer?, gpointer?) -> Void = { _, data in
        let run: F = handler(data)
        MainActor.assumeIsolated { run() }
    }
    connect(object.raw, signal, run, unsafeBitCast(callback, to: GCallback.self))
}

/// `signal` with one pointer argument ("row-activated", "row-selected", "child-activated", "notify::…").
func on(_ object: some GObjectPointer, _ signal: String,
           _ run: @escaping @MainActor (UnsafeMutableRawPointer?) -> Void) {
    typealias F = @MainActor (UnsafeMutableRawPointer?) -> Void
    let callback: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, argument, data in
        let run: F = handler(data)
        let argument = argument.map { UInt(bitPattern: $0) }
        MainActor.assumeIsolated { run(argument.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }) }
    }
    connect(object.raw, signal, run, unsafeBitCast(callback, to: GCallback.self))
}

/// A window's close button: return true to keep it open (it's hidden instead, so it opens again as it was).
func onClose(_ window: Widget, _ run: @escaping @MainActor () -> Bool) {
    typealias F = @MainActor () -> Bool
    let callback: @convention(c) (gpointer?, gpointer?) -> gboolean = { _, data in
        let run: F = handler(data)
        return MainActor.assumeIsolated { run() } ? 1 : 0
    }
    connect(window.raw, "close-request", run, unsafeBitCast(callback, to: GCallback.self))
}

/// Key presses on `widget` (and in it), before its children see them when `capture`. Return true when handled.
func onKey(_ widget: Widget, capture: Bool = true, _ run: @escaping @MainActor (UInt32, GdkModifierType) -> Bool) {
    typealias F = @MainActor (UInt32, GdkModifierType) -> Bool
    let controller = gtk_event_controller_key_new()!
    if capture { gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE) }
    let callback: @convention(c) (gpointer?, guint, guint, GdkModifierType, gpointer?) -> gboolean = {
        _, key, _, state, data in
        let run: F = handler(data)
        return MainActor.assumeIsolated { run(key, state) } ? 1 : 0
    }
    connect(controller.raw, "key-pressed", run, unsafeBitCast(callback, to: GCallback.self))
    gtk_widget_add_controller(widget, controller)
}

/// Clicks on `widget`: `run` gets how many in a row (2 for a double-click). `button` 3 is the right one.
func onClick(_ widget: Widget, button: UInt32 = 1, _ run: @escaping @MainActor (Int32) -> Void) {
    typealias F = @MainActor (Int32) -> Void
    let gesture = gtk_gesture_click_new()!
    gtk_gesture_single_set_button(cast(gesture), button)
    let callback: @convention(c) (gpointer?, gint, gdouble, gdouble, gpointer?) -> Void = { _, count, _, _, data in
        let run: F = handler(data)
        MainActor.assumeIsolated { run(count) }
    }
    connect(gesture.raw, "pressed", run, unsafeBitCast(callback, to: GCallback.self))
    gtk_widget_add_controller(widget, cast(gesture))
}

/// Dragging `widget` drags the file at `path()` out (to a file manager, a chat, a mail).
func dragsFile(_ widget: Widget, _ path: @escaping @MainActor () -> String?) {
    typealias F = @MainActor () -> String?
    let source = gtk_drag_source_new()!
    gtk_drag_source_set_actions(source, GDK_ACTION_COPY)
    let callback: @convention(c) (gpointer?, gdouble, gdouble, gpointer?) -> OpaquePointer? = { _, _, _, data in
        let path: F = handler(data)
        guard let file = MainActor.assumeIsolated({ path() }) else { return nil }
        return OpaquePointer(digup_file_content(file))
    }
    connect(source.raw, "prepare", path, unsafeBitCast(callback, to: GCallback.self))
    gtk_widget_add_controller(widget, cast(source))
}

/// GApplication's "command-line": the arguments of this run, or of a later one passed over to this copy.
func onCommandLine(_ application: some GObjectPointer, _ run: @escaping @MainActor ([String]) -> Int32) {
    typealias F = @MainActor ([String]) -> Int32
    let callback: @convention(c) (gpointer?, UnsafeMutablePointer<GApplicationCommandLine>?, gpointer?) -> gint = {
        _, line, data in
        let run: F = handler(data)
        var count: gint = 0
        var arguments: [String] = []
        if let argv = g_application_command_line_get_arguments(line, &count) {
            for index in 0..<Int(count) { if let argument = argv[index] { arguments.append(String(cString: argument)) } }
            g_strfreev(argv)
        }
        let values = arguments
        return MainActor.assumeIsolated { run(values) }
    }
    connect(application.raw, "command-line", run, unsafeBitCast(callback, to: GCallback.self))
}

// MARK: Observation

/// Runs `body` now and again whenever an observable value it read changes (on the main thread, after the change).
func watch(_ body: @escaping @MainActor () -> Void) {
    withObservationTracking { body() } onChange: {
        DispatchQueue.main.async { MainActor.assumeIsolated { watch(body) } }
    }
}

/// `watch`, for as long as `widget` lives (views that are rebuilt mustn't be updated after they're gone).
func watch(_ widget: Widget, _ body: @escaping @MainActor () -> Void) {
    let alive = Alive()
    on(widget, "destroy") { alive.value = false }
    watch(while: alive, body)
}

private func watch(while alive: Alive, _ body: @escaping @MainActor () -> Void) {
    guard alive.value else { return }
    withObservationTracking { body() } onChange: {
        DispatchQueue.main.async { MainActor.assumeIsolated { watch(while: alive, body) } }
    }
}

private nonisolated final class Alive: @unchecked Sendable {
    var value = true
}

// MARK: Building widgets

func label(_ text: String, _ classes: String..., wrap: Bool = false, xalign: Float = 0, ellipsize: Bool = false)
    -> Widget {
    let widget = gtk_label_new(text)!
    gtk_label_set_xalign(cast(widget), xalign)
    if wrap {
        gtk_label_set_wrap(cast(widget), 1)
        gtk_label_set_wrap_mode(cast(widget), PANGO_WRAP_WORD_CHAR)
    }
    if ellipsize { gtk_label_set_ellipsize(cast(widget), PANGO_ELLIPSIZE_MIDDLE) }
    for name in classes { gtk_widget_add_css_class(widget, name) }
    return widget
}

func setText(_ label: Widget, _ text: String) {
    gtk_label_set_text(cast(label), text)
}

func setMarkup(_ label: Widget, _ markup: String) {
    gtk_label_set_markup(cast(label), markup)
}

/// Text safe inside Pango markup.
func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func button(_ title: String, _ classes: String..., action: @escaping @MainActor () -> Void) -> Widget {
    let widget = gtk_button_new_with_label(title)!
    for name in classes { gtk_widget_add_css_class(widget, name) }
    on(widget, "clicked", action)
    return widget
}

func iconButton(_ icon: String, tooltip: String, action: @escaping @MainActor () -> Void) -> Widget {
    let widget = gtk_button_new_from_icon_name(icon)!
    gtk_widget_add_css_class(widget, "flat")
    gtk_widget_set_tooltip_text(widget, tooltip)
    on(widget, "clicked", action)
    return widget
}

func box(_ orientation: GtkOrientation, spacing: Int32 = 0, _ classes: [String] = [], _ children: [Widget] = [])
    -> Widget {
    let widget = gtk_box_new(orientation, spacing)!
    for name in classes { gtk_widget_add_css_class(widget, name) }
    for child in children { gtk_box_append(cast(widget), child) }
    return widget
}

func vbox(spacing: Int32 = 0, _ classes: String..., children: [Widget] = []) -> Widget {
    box(GTK_ORIENTATION_VERTICAL, spacing: spacing, classes, children)
}

func hbox(spacing: Int32 = 0, _ classes: String..., children: [Widget] = []) -> Widget {
    box(GTK_ORIENTATION_HORIZONTAL, spacing: spacing, classes, children)
}

func append(_ box: Widget, _ children: Widget...) {
    for child in children { gtk_box_append(cast(box), child) }
}

/// Removes every child of a box.
func clear(_ box: Widget) {
    while let child = gtk_widget_get_first_child(box) { gtk_box_remove(cast(box), child) }
}

func spacer() -> Widget {
    let widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
    gtk_widget_set_hexpand(widget, 1)
    return widget
}

func scrolled(_ child: Widget, horizontal: Bool = false) -> Widget {
    let widget = gtk_scrolled_window_new()!
    gtk_scrolled_window_set_policy(cast(widget), horizontal ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER,
                                   GTK_POLICY_AUTOMATIC)
    gtk_scrolled_window_set_child(cast(widget), child)
    gtk_widget_set_vexpand(widget, 1)
    return widget
}

func switchRow(_ title: String, detail: String?, on value: Bool, changed: @escaping @MainActor (Bool) -> Void)
    -> Widget {
    let toggle = gtk_switch_new()!
    gtk_switch_set_active(cast(toggle), value ? 1 : 0)
    gtk_widget_set_valign(toggle, GTK_ALIGN_CENTER)
    on(toggle, "notify::active") { _ in changed(gtk_switch_get_active(cast(toggle)) != 0) }
    let texts = vbox(spacing: 2, children: [label(title, "row-title")])
    if let detail { append(texts, label(detail, "dim", wrap: true)) }
    gtk_widget_set_hexpand(texts, 1)
    return hbox(spacing: 12, "card-row", children: [texts, toggle])
}

func entry(placeholder: String, text: String = "") -> Widget {
    let widget = gtk_entry_new()!
    gtk_entry_set_placeholder_text(cast(widget), placeholder)
    gtk_editable_set_text(cast(widget), text)
    return widget
}

func entryText(_ entry: Widget) -> String {
    String(cString: gtk_editable_get_text(cast(entry)))
}

func setVisible(_ widget: Widget, _ visible: Bool) {
    gtk_widget_set_visible(widget, visible ? 1 : 0)
}

func setTooltip(_ widget: Widget, _ text: String) {
    gtk_widget_set_tooltip_text(widget, text)
}

func size(_ widget: Widget, width: Int32 = -1, height: Int32 = -1) {
    gtk_widget_set_size_request(widget, width, height)
}

func margins(_ widget: Widget, _ all: Int32) {
    gtk_widget_set_margin_top(widget, all)
    gtk_widget_set_margin_bottom(widget, all)
    gtk_widget_set_margin_start(widget, all)
    gtk_widget_set_margin_end(widget, all)
}

/// A picture of the file at `path` (fitted into its box), or nil when GTK can't read it.
func picture(_ path: String) -> Widget? {
    guard let texture = gdk_texture_new_from_filename(path, nil) else { return nil }
    defer { unref(texture) }
    let widget = gtk_picture_new_for_paintable(cast(texture))!
    gtk_picture_set_content_fit(cast(widget), GTK_CONTENT_FIT_CONTAIN)
    return widget
}

func icon(_ name: String, size: Int32) -> Widget {
    let widget = gtk_image_new_from_icon_name(name)!
    gtk_image_set_pixel_size(cast(widget), size)
    return widget
}

func window(_ title: String, width: Int32, height: Int32) -> Widget {
    let widget = gtk_window_new()!
    gtk_window_set_title(cast(widget), title)
    gtk_window_set_default_size(cast(widget), width, height)
    if let app = DigUpGtk.application { gtk_window_set_application(cast(widget), app) }
    return widget
}

func present(_ window: Widget) {
    gtk_window_present(cast(window))
}

/// A yes/no question over `parent`: `confirm` runs on the destructive answer.
func confirm(_ parent: Widget, title: String, detail: String, action: String,
             _ confirm: @escaping @MainActor () -> Void) {
    let dialog = window(title, width: 380, height: -1)
    gtk_window_set_modal(cast(dialog), 1)
    gtk_window_set_transient_for(cast(dialog), cast(parent))
    gtk_window_set_resizable(cast(dialog), 0)
    let cancel = button("Cancel") { gtk_window_destroy(cast(dialog)) }
    let yes = button(action, "destructive-action") {
        gtk_window_destroy(cast(dialog))
        confirm()
    }
    let content = vbox(spacing: 12, children: [label(title, "title-3", wrap: true), label(detail, "dim", wrap: true),
                                               hbox(spacing: 8, children: [spacer(), cancel, yes])])
    margins(content, 18)
    gtk_window_set_child(cast(dialog), content)
    present(dialog)
}

// MARK: The application

enum DigUpGtk {
    nonisolated(unsafe) static var application: UnsafeMutablePointer<GtkApplication>?

    /// The look: GTK's own theme, with DigUp's few touches.
    static func loadStyle() {
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider),
                                                   UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }

    private static let css = """
        window.panel { background-color: @theme_bg_color; border: 1px solid alpha(currentColor, 0.2); }
        .search-field { font-size: 20px; min-height: 44px; border: none; box-shadow: none; background: none; }
        .dim { opacity: 0.65; font-size: 12px; }
        .faint { opacity: 0.45; font-size: 11px; }
        .row-title { font-weight: 600; }
        .group-header { font-size: 11px; font-weight: 700; opacity: 0.55; margin: 8px 10px 2px 10px; }
        .result-row { padding: 6px 8px; border-radius: 8px; }
        .badge { background: alpha(#f2b33d, 0.25); border-radius: 6px; padding: 1px 6px; font-size: 11px; font-weight: 600; }
        .mark { background: #ffdb33; color: black; }
        .passage { background: white; color: #222; border-radius: 8px; padding: 14px; }
        .code-card { background: alpha(currentColor, 0.05); border-radius: 8px; padding: 10px; font-family: monospace; font-size: 11px; }
        .card-row { background: alpha(currentColor, 0.05); border-radius: 10px; padding: 10px 12px; }
        .footer { font-size: 11px; opacity: 0.6; padding: 6px 12px; }
        .chip { border-radius: 14px; padding: 2px 10px; }
        .hero { font-size: 26px; font-weight: 800; }
        .title-2 { font-size: 20px; font-weight: 700; }
        .title-3 { font-size: 15px; font-weight: 700; }
        .grid-cell { padding: 6px; border-radius: 10px; }
        .keycap { border: 1px solid alpha(currentColor, 0.3); border-radius: 5px; padding: 0 5px; font-size: 11px; }
        """
}
