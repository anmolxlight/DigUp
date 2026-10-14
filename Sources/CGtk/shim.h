#include <gtk/gtk.h>
#include <glib-unix.h>
#include <sys/eventfd.h>

// libdispatch's main queue, which Swift's main actor and DispatchQueue.main run on. On a Mac the run loop drains it;
// here GLib's main loop does, woken by the queue's eventfd.
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *message);

static inline gboolean digup_drain_main_queue(gint fd, GIOCondition condition, gpointer data) {
    eventfd_t value;
    eventfd_read(fd, &value);
    _dispatch_main_queue_callback_4CF(NULL);
    return G_SOURCE_CONTINUE;
}

static inline void digup_attach_main_queue(void) {
    g_unix_fd_add(_dispatch_get_main_queue_handle_4CF(), G_IO_IN, digup_drain_main_queue, NULL);
}

// A file, for dragging a result out (gdk_content_provider_new_typed is variadic: Swift can't call it).
static inline GdkContentProvider *digup_file_content(const char *path) {
    GFile *file = g_file_new_for_path(path);
    GdkContentProvider *provider = gdk_content_provider_new_typed(G_TYPE_FILE, file);
    g_object_unref(file);
    return provider;
}
