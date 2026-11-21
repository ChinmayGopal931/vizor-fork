#ifndef RUNNER_SESSION_LIFECYCLE_H_
#define RUNNER_SESSION_LIFECYCLE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <set>

// The session away on Windows, as the Mac's `MacSessionLifecycle` and Linux's session_lifecycle.cc: while the user is
// away, Shielded USD's foreground rule (AGENTS.md, "Foreground and unlocked only") sees the app as hidden. Flutter's
// embedder reports `hidden` for a minimised or hidden window, `inactive` for one without focus and `resumed` otherwise
// (windows_lifecycle_manager.cc), and nothing of the session; this says `AppLifecycleState.hidden` on
// `flutter/lifecycle` while:
// - the session is locked (WTS_SESSION_LOCK to WTS_SESSION_UNLOCK);
// - another session is on the console or the remote session disconnected (fast user switching, RDP);
// - the computer sleeps (PBT_APMSUSPEND to its resume);
// - the display is off (GUID_CONSOLE_DISPLAY_STATE), as the Mac's displays asleep: modern standby sends no suspend.
// Like the Mac's notifications it reacts to changes only, never to a state read at the start. While the user is away
// every window-state change the embedder reports is followed by `hidden` again; once nothing keeps the user away it
// sends the state the embedder would report, and again a second later (focus can trail an unlock).
//
// It also shows and hides the Railgun page (railgun/railgun_page_host.h) with Veylor's window and the session, so
// WebView2 throttles a page nobody can see, as WebKit suspends the Mac's.
class SessionLifecycle {
 public:
  SessionLifecycle(flutter::BinaryMessenger* messenger, HWND window);
  ~SessionLifecycle();
  SessionLifecycle(const SessionLifecycle&) = delete;
  SessionLifecycle& operator=(const SessionLifecycle&) = delete;

  // Every message of the app's window; it only watches.
  void OnWindowMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam);

 private:
  enum class Away { kLocked, kDisconnected, kAsleep, kDisplayOff };

  void Set(Away reason, bool away);
  void Send(const char* state);
  const char* CurrentState() const;
  void HideAgainSoon();
  void UpdateWindowShown(bool visible);

  flutter::BinaryMessenger* messenger_;
  HWND window_;
  std::set<Away> away_;
  HPOWERNOTIFY display_notification_ = nullptr;
  // Windows reports the display's state as it registers: that is no change.
  bool display_reported_ = false;
  bool session_registered_ = false;
  UINT_PTR settle_timer_ = 0;
  UINT_PTR hide_timer_ = 0;
};

#endif  // RUNNER_SESSION_LIFECYCLE_H_
