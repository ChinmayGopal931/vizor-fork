#ifndef RUNNER_PRIVATE_USD_SESSION_LIFECYCLE_H_
#define RUNNER_PRIVATE_USD_SESSION_LIFECYCLE_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The session away from its user (the screen locked or blanked, the computer going to sleep, or another session in
// front) reads to Dart as the app hidden, as the Mac's `MacSessionLifecycle` makes it: Flutter's Linux embedder
// reports `hidden` only for a minimised or withdrawn window (`fl_window_state_monitor.cc`), and on Wayland not even
// that, so work that runs only in the foreground (Private USD's key steps and polling, plan D9) would carry on behind
// a locked screen. It speaks the engine's own `flutter/lifecycle` messages, from logind (sleep, the session's
// LockedHint and Active) and the session's screensaver (GNOME's and the freedesktop one), and once nothing keeps the
// user away sends the state the embedder would report now, and again a moment later.
void session_lifecycle_register(FlView* view, GtkWindow* window);

#endif  // RUNNER_PRIVATE_USD_SESSION_LIFECYCLE_H_
