#include "private_usd/private_usd_channels.h"

#include <gio/gio.h>

#include <cstring>

#include "private_usd/railgun_host.h"
#include "private_usd/session_lifecycle.h"

namespace {

struct Channels {
  GtkApplication* application = nullptr;
  GtkWindow* window = nullptr;
  FlMethodChannel* attestation = nullptr;
  FlMethodChannel* screen_awake = nullptr;
  FlMethodChannel* haptics = nullptr;
  // The keep-awake hold: GTK's inhibitor where the session manager takes one, else the freedesktop screensaver's.
  guint inhibit_cookie = 0;
  guint32 screensaver_cookie = 0;
  bool screensaver_held = false;
};

Channels* g_channels = nullptr;

// Shown in the desktop's list of what keeps it awake, never in the app.
constexpr char kAwakeReason[] = "Keeping the display awake while Shielded USD syncs or bridges";

void Respond(FlMethodCall* call, FlMethodResponse* response) {
  g_autoptr(GError) error = nullptr;
  fl_method_call_respond(call, response, &error);
  g_object_unref(response);
}

// MARK: Attestation

// `com.zcash.wallet/private_usd_attestation` on Linux, as on iOS and the Mac: zecSwap's issuer checks Android key
// attestation alone, so every `sign` is `unavailable`, and Dart then says conversions need an Android device while a
// market maker asks for tokens. The same codes as Android's, so Dart treats every host alike.
void OnAttestationCall(FlMethodChannel*, FlMethodCall* call, gpointer) {
  if (std::strcmp(fl_method_call_get_name(call), "sign") == 0) {
    Respond(call, FL_METHOD_RESPONSE(fl_method_error_response_new(
                      "unavailable", "the token issuer has no Linux mode yet", nullptr)));
  } else {
    Respond(call, FL_METHOD_RESPONSE(fl_method_not_implemented_response_new()));
  }
}

// MARK: Keep-awake

// `com.zcash.wallet/screen_awake` on Linux (`setEnabled {enabled}`), the flag `SyncKeepAwakeNativeHost` owns: while it
// is on, the session does not blank, lock or suspend on idle, as the phones keep their screen on and the Mac holds an
// IOKit assertion. A locked screen hides the app, and a hidden app pauses Private USD (plan D9), so a Railgun first
// sync, or a bridge with a key step to come, would stall. It never stops the user locking the screen or suspending,
// and the session manager drops the hold with the process.
bool SetAwake(bool enabled) {
  if (enabled) {
    if (g_channels->inhibit_cookie != 0 || g_channels->screensaver_held) return true;
    g_channels->inhibit_cookie = gtk_application_inhibit(g_channels->application, g_channels->window,
                                                         GTK_APPLICATION_INHIBIT_IDLE, kAwakeReason);
    if (g_channels->inhibit_cookie != 0) return true;
    // GTK reaches GNOME's session manager; KDE, Xfce and others take the freedesktop screensaver's hold.
    g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
    if (bus == nullptr) return false;
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
        bus, "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver", "Inhibit",
        g_variant_new("(ss)", APP_DISPLAY_NAME, kAwakeReason), G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 2000,
        nullptr, nullptr);
    if (reply == nullptr) return false;
    g_variant_get(reply, "(u)", &g_channels->screensaver_cookie);
    g_channels->screensaver_held = true;
    return true;
  }
  if (g_channels->inhibit_cookie != 0) {
    gtk_application_uninhibit(g_channels->application, g_channels->inhibit_cookie);
    g_channels->inhibit_cookie = 0;
  }
  if (g_channels->screensaver_held) {
    g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
    if (bus != nullptr) {
      g_dbus_connection_call(bus, "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
                             "org.freedesktop.ScreenSaver", "UnInhibit",
                             g_variant_new("(u)", g_channels->screensaver_cookie), nullptr, G_DBUS_CALL_FLAGS_NONE,
                             2000, nullptr, nullptr, nullptr);
    }
    g_channels->screensaver_held = false;
    g_channels->screensaver_cookie = 0;
  }
  return true;
}

void OnScreenAwakeCall(FlMethodChannel*, FlMethodCall* call, gpointer) {
  if (std::strcmp(fl_method_call_get_name(call), "setEnabled") != 0) {
    Respond(call, FL_METHOD_RESPONSE(fl_method_not_implemented_response_new()));
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  FlValue* enabled = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                         ? fl_value_lookup_string(args, "enabled")
                         : nullptr;
  if (enabled == nullptr || fl_value_get_type(enabled) != FL_VALUE_TYPE_BOOL) {
    Respond(call, FL_METHOD_RESPONSE(fl_method_error_response_new("bad_args", "Expected enabled argument.", nullptr)));
    return;
  }
  if (SetAwake(fl_value_get_bool(enabled))) {
    Respond(call, FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr)));
  } else {
    Respond(call, FL_METHOD_RESPONSE(fl_method_error_response_new("unavailable", "The idle hold was refused.", nullptr)));
  }
}

// MARK: The settlement reminder

// `com.zcash.wallet/haptics` on Linux, for its one desktop meaning: `settlementDeadline`, the phones' buzz when a
// shielded USD → ZEC bridge first offers "Authorize settlement" (the user's turn) and again two minutes before it
// closes. A computer has no haptics to buzz, so it asks for the user's attention instead, as the Mac does: the window's
// urgency hint, which the window list or dock shows until Veylor is active again (none while it already is), and the
// desktop's alert sound. Neither needs a permission or a notification, and nothing is shown or logged.
//
// Dart's `privateUsdSettlementReminderProvider` decides when: only while the app is in the foreground (a window
// showing, focused or not) and unlocked, once per offer and once per closing. Every other haptics call answers not
// implemented, so Dart falls back as before.
void OnHapticsCall(FlMethodChannel*, FlMethodCall* call, gpointer) {
  if (std::strcmp(fl_method_call_get_name(call), "settlementDeadline") != 0) {
    Respond(call, FL_METHOD_RESPONSE(fl_method_not_implemented_response_new()));
    return;
  }
  GtkWindow* window = g_channels->window;
  if (window != nullptr && !gtk_window_is_active(window)) gtk_window_set_urgency_hint(window, TRUE);
  GdkWindow* gdk_window = window != nullptr ? gtk_widget_get_window(GTK_WIDGET(window)) : nullptr;
  if (gdk_window != nullptr) {
    gdk_window_beep(gdk_window);
  } else if (GdkDisplay* display = gdk_display_get_default()) {
    gdk_display_beep(display);
  }
  g_autoptr(FlValue) handled = fl_value_new_bool(TRUE);
  Respond(call, FL_METHOD_RESPONSE(fl_method_success_response_new(handled)));
}

void OnActiveChanged(GObject* window, GParamSpec*, gpointer) {
  if (gtk_window_is_active(GTK_WINDOW(window))) gtk_window_set_urgency_hint(GTK_WINDOW(window), FALSE);
}

FlMethodChannel* NewChannel(FlBinaryMessenger* messenger, const char* name, FlMethodChannelMethodCallHandler handler) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(messenger, name, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, handler, nullptr, nullptr);
  return channel;
}

}  // namespace

void register_private_usd_channels(FlView* view, GtkWindow* window, GtkApplication* application) {
  if (g_channels != nullptr) return;
  g_channels = new Channels();
  g_channels->application = application;
  g_channels->window = window;
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_channels->attestation = NewChannel(messenger, "com.zcash.wallet/private_usd_attestation", OnAttestationCall);
  g_channels->screen_awake = NewChannel(messenger, "com.zcash.wallet/screen_awake", OnScreenAwakeCall);
  g_channels->haptics = NewChannel(messenger, "com.zcash.wallet/haptics", OnHapticsCall);
  g_signal_connect(window, "notify::is-active", G_CALLBACK(OnActiveChanged), nullptr);
  railgun_host_register(view, window);
  session_lifecycle_register(view, window);
}
