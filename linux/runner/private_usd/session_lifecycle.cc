#include "private_usd/session_lifecycle.h"

#include <gio/gio.h>
#include <unistd.h>

#include <set>
#include <string>

#include "private_usd/railgun_host.h"

namespace {

enum class Away { kScreenLocked, kScreenSaver, kAsleep, kSessionInactive };

constexpr char kLifecycleChannel[] = "flutter/lifecycle";
constexpr char kHidden[] = "AppLifecycleState.hidden";
constexpr char kLogind[] = "org.freedesktop.login1";
constexpr char kLogindPath[] = "/org/freedesktop/login1";
constexpr char kSessionInterface[] = "org.freedesktop.login1.Session";
constexpr guint kSettleMs = 1000;

struct SessionLifecycle {
  FlBinaryMessenger* messenger = nullptr;
  GtkWindow* window = nullptr;
  std::set<Away> away;
  guint settle = 0;
  GDBusConnection* system = nullptr;
  GDBusConnection* session = nullptr;
  std::string session_path;
};

SessionLifecycle* g_lifecycle = nullptr;

void Send(const char* state) {
  g_autoptr(FlValue) value = fl_value_new_string(state);
  g_autoptr(FlStringCodec) codec = fl_string_codec_new();
  g_autoptr(GError) error = nullptr;
  g_autoptr(GBytes) message = fl_message_codec_encode_message(FL_MESSAGE_CODEC(codec), value, &error);
  if (message == nullptr) return;
  fl_binary_messenger_send_on_channel(g_lifecycle->messenger, kLifecycleChannel, message, nullptr, nullptr, nullptr);
}

// What Flutter's embedder reports from the window's state: hidden while minimised or withdrawn, resumed while
// focused, else inactive.
const char* CurrentState() {
  GdkWindow* window =
      g_lifecycle->window != nullptr ? gtk_widget_get_window(GTK_WIDGET(g_lifecycle->window)) : nullptr;
  if (window == nullptr) return kHidden;
  const GdkWindowState state = gdk_window_get_state(window);
  if (state & (GDK_WINDOW_STATE_WITHDRAWN | GDK_WINDOW_STATE_ICONIFIED)) return kHidden;
  return (state & GDK_WINDOW_STATE_FOCUSED) ? "AppLifecycleState.resumed" : "AppLifecycleState.inactive";
}

gboolean SendSettled(gpointer) {
  g_lifecycle->settle = 0;
  if (g_lifecycle->away.empty()) Send(CurrentState());
  return G_SOURCE_REMOVE;
}

void Begin(Away reason) {
  const bool was_away = !g_lifecycle->away.empty();
  g_lifecycle->away.insert(reason);
  if (g_lifecycle->settle != 0) g_source_remove(g_lifecycle->settle);
  g_lifecycle->settle = 0;
  Send(kHidden);
  if (!was_away) railgun_host_set_session_away(TRUE);
}

void End(Away reason) {
  if (g_lifecycle->away.erase(reason) == 0 || !g_lifecycle->away.empty()) return;
  railgun_host_set_session_away(FALSE);
  Send(CurrentState());
  // Again a moment later: focus can trail an unlock.
  if (g_lifecycle->settle != 0) g_source_remove(g_lifecycle->settle);
  g_lifecycle->settle = g_timeout_add(kSettleMs, SendSettled, nullptr);
}

void Set(Away reason, bool away) {
  if (away) {
    Begin(reason);
  } else {
    End(reason);
  }
}

// The embedder reports every change of the window's state, focus included; while the user is away the app stays
// hidden. Connected after the embedder's own handler, so this message follows its.
gboolean OnWindowState(GtkWidget*, GdkEventWindowState*, gpointer) {
  if (!g_lifecycle->away.empty()) Send(kHidden);
  return FALSE;
}

// MARK: logind

void OnPrepareForSleep(GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*, GVariant* parameters,
                       gpointer) {
  gboolean start = FALSE;
  if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(b)"))) return;
  g_variant_get(parameters, "(b)", &start);
  Set(Away::kAsleep, start);
}

void ApplySessionProperty(const gchar* name, GVariant* value) {
  if (!g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN)) return;
  const bool flag = g_variant_get_boolean(value);
  if (g_strcmp0(name, "LockedHint") == 0) {
    Set(Away::kScreenLocked, flag);
  } else if (g_strcmp0(name, "Active") == 0) {
    Set(Away::kSessionInactive, !flag);
  }
}

void OnSessionPropertiesChanged(GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*,
                                GVariant* parameters, gpointer) {
  if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(sa{sv}as)"))) return;
  const gchar* interface = nullptr;
  g_autoptr(GVariant) changed = nullptr;
  g_autoptr(GVariant) invalidated = nullptr;
  g_variant_get(parameters, "(&s@a{sv}@as)", &interface, &changed, &invalidated);
  if (g_strcmp0(interface, kSessionInterface) != 0) return;
  GVariantIter iter;
  const gchar* name = nullptr;
  GVariant* value = nullptr;
  g_variant_iter_init(&iter, changed);
  while (g_variant_iter_loop(&iter, "{&sv}", &name, &value)) ApplySessionProperty(name, value);
}

// Only changes count, as only the Mac's notifications do: a session Veylor started in is one its user sees, and a
// state read at the start (another session's, in an odd setup) must never hide the app for good.
void WatchSession(const std::string& path) {
  if (path.empty() || path == "/" || !g_lifecycle->session_path.empty()) return;
  g_lifecycle->session_path = path;
  g_dbus_connection_signal_subscribe(g_lifecycle->system, kLogind, "org.freedesktop.DBus.Properties",
                                     "PropertiesChanged", path.c_str(), kSessionInterface, G_DBUS_SIGNAL_FLAGS_NONE,
                                     OnSessionPropertiesChanged, nullptr, nullptr);
}

void OnSessionByPid(GObject* source, GAsyncResult* result, gpointer) {
  g_autoptr(GVariant) reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, nullptr);
  if (reply == nullptr || !g_variant_is_of_type(reply, G_VARIANT_TYPE("(o)"))) return;
  const gchar* path = nullptr;
  g_variant_get(reply, "(&o)", &path);
  WatchSession(path);
}

// The user's graphical session: apps a desktop starts usually run outside any session, in the user's manager, so the
// session to watch is the one logind calls the user's display; else the session this process belongs to.
void OnUserDisplay(GObject* source, GAsyncResult* result, gpointer) {
  g_autoptr(GVariant) reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, nullptr);
  if (reply != nullptr && g_variant_is_of_type(reply, G_VARIANT_TYPE("(v)"))) {
    g_autoptr(GVariant) boxed = g_variant_get_child_value(reply, 0);
    g_autoptr(GVariant) display = g_variant_get_variant(boxed);
    if (g_variant_is_of_type(display, G_VARIANT_TYPE("(so)"))) {
      const gchar* id = nullptr;
      const gchar* path = nullptr;
      g_variant_get(display, "(&s&o)", &id, &path);
      if (id != nullptr && id[0] != '\0') {
        WatchSession(path);
        return;
      }
    }
  }
  g_dbus_connection_call(g_lifecycle->system, kLogind, kLogindPath, "org.freedesktop.login1.Manager",
                         "GetSessionByPID", g_variant_new("(u)", static_cast<guint32>(getpid())),
                         G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, 5000, nullptr, OnSessionByPid, nullptr);
}

void OnSystemBus(GObject*, GAsyncResult* result, gpointer) {
  g_lifecycle->system = g_bus_get_finish(result, nullptr);
  if (g_lifecycle->system == nullptr) return;
  g_dbus_connection_signal_subscribe(g_lifecycle->system, kLogind, "org.freedesktop.login1.Manager",
                                     "PrepareForSleep", kLogindPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
                                     OnPrepareForSleep, nullptr, nullptr);
  g_dbus_connection_call(g_lifecycle->system, kLogind, "/org/freedesktop/login1/user/self",
                         "org.freedesktop.DBus.Properties", "Get",
                         g_variant_new("(ss)", "org.freedesktop.login1.User", "Display"), G_VARIANT_TYPE("(v)"),
                         G_DBUS_CALL_FLAGS_NONE, 5000, nullptr, OnUserDisplay, nullptr);
}

// MARK: The screensaver

void OnScreenSaverActive(GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*,
                         GVariant* parameters, gpointer) {
  if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(b)"))) return;
  gboolean active = FALSE;
  g_variant_get(parameters, "(b)", &active);
  Set(Away::kScreenSaver, active);
}

void OnSessionBus(GObject*, GAsyncResult* result, gpointer) {
  g_lifecycle->session = g_bus_get_finish(result, nullptr);
  if (g_lifecycle->session == nullptr) return;
  struct Saver {
    const char* name;
    const char* path;
  };
  // GNOME's, then the freedesktop one KDE, Xfce and others implement, at both of its paths.
  static const Saver kSavers[] = {
      {"org.gnome.ScreenSaver", "/org/gnome/ScreenSaver"},
      {"org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver"},
      {"org.freedesktop.ScreenSaver", "/ScreenSaver"},
  };
  for (const Saver& saver : kSavers) {
    g_dbus_connection_signal_subscribe(g_lifecycle->session, saver.name, saver.name, "ActiveChanged", saver.path,
                                       nullptr, G_DBUS_SIGNAL_FLAGS_NONE, OnScreenSaverActive, nullptr, nullptr);
  }
}

}  // namespace

void session_lifecycle_register(FlView* view, GtkWindow* window) {
  if (g_lifecycle != nullptr) return;
  g_lifecycle = new SessionLifecycle();
  g_lifecycle->messenger = fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_lifecycle->window = window;
  g_signal_connect(window, "window-state-event", G_CALLBACK(OnWindowState), nullptr);
  g_bus_get(G_BUS_TYPE_SYSTEM, nullptr, OnSystemBus, nullptr);
  g_bus_get(G_BUS_TYPE_SESSION, nullptr, OnSessionBus, nullptr);
}
