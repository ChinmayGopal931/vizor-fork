#include "session_lifecycle.h"

#include <wtsapi32.h>

#include <cstring>

#include "railgun/railgun_dispatch.h"
#include "railgun/railgun_page_host.h"

namespace {

constexpr char kLifecycleChannel[] = "flutter/lifecycle";
constexpr char kHidden[] = "AppLifecycleState.hidden";
constexpr char kInactive[] = "AppLifecycleState.inactive";
constexpr char kResumed[] = "AppLifecycleState.resumed";
constexpr UINT kSettleMs = 1000;
// GUID_CONSOLE_DISPLAY_STATE (winnt.h), here so that no library has to define it.
constexpr GUID kConsoleDisplayState = {0x6fe69556, 0x704a, 0x47a0, {0x8f, 0x24, 0xc2, 0x8d, 0x93, 0x6f, 0xda, 0x47}};
// After the embedder's own report, which it makes on its next run-loop turn.
constexpr UINT kHideAgainMs = 100;

}  // namespace

SessionLifecycle::SessionLifecycle(flutter::BinaryMessenger* messenger, HWND window)
    : messenger_(messenger), window_(window) {
  session_registered_ = ::WTSRegisterSessionNotification(window_, NOTIFY_FOR_THIS_SESSION) != FALSE;
  display_notification_ =
      ::RegisterPowerSettingNotification(window_, &kConsoleDisplayState, DEVICE_NOTIFY_WINDOW_HANDLE);
  UpdateWindowShown(::IsWindowVisible(window_) != FALSE);
}

SessionLifecycle::~SessionLifecycle() {
  railgun_windows::Dispatch::Get().Cancel(settle_timer_);
  railgun_windows::Dispatch::Get().Cancel(hide_timer_);
  if (session_registered_) ::WTSUnRegisterSessionNotification(window_);
  if (display_notification_ != nullptr) ::UnregisterPowerSettingNotification(display_notification_);
}

void SessionLifecycle::OnWindowMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (window != window_) return;
  switch (message) {
    case WM_WTSSESSION_CHANGE:
      switch (wparam) {
        case WTS_SESSION_LOCK:
          Set(Away::kLocked, true);
          break;
        case WTS_SESSION_UNLOCK:
          Set(Away::kLocked, false);
          break;
        case WTS_CONSOLE_DISCONNECT:
        case WTS_REMOTE_DISCONNECT:
          Set(Away::kDisconnected, true);
          break;
        case WTS_CONSOLE_CONNECT:
        case WTS_REMOTE_CONNECT:
          Set(Away::kDisconnected, false);
          break;
      }
      break;
    case WM_POWERBROADCAST:
      if (wparam == PBT_APMSUSPEND) {
        Set(Away::kAsleep, true);
      } else if (wparam == PBT_APMRESUMESUSPEND || wparam == PBT_APMRESUMEAUTOMATIC) {
        Set(Away::kAsleep, false);
      } else if (wparam == PBT_POWERSETTINGCHANGE && lparam != 0) {
        const auto* setting = reinterpret_cast<const POWERBROADCAST_SETTING*>(lparam);
        if (::IsEqualGUID(setting->PowerSetting, kConsoleDisplayState) && setting->DataLength >= sizeof(DWORD)) {
          DWORD state = 0;
          std::memcpy(&state, setting->Data, sizeof(state));
          // 0 off, 1 on, 2 dimmed.
          if (display_reported_) Set(Away::kDisplayOff, state == 0);
          display_reported_ = true;
        }
      }
      break;
    case WM_SIZE:
      UpdateWindowShown(::IsWindowVisible(window_) != FALSE);
      if (!away_.empty()) HideAgainSoon();
      break;
    case WM_SHOWWINDOW:
      // Sent before the window's visibility changes: `wparam` is the new one.
      UpdateWindowShown(wparam != FALSE);
      if (!away_.empty()) HideAgainSoon();
      break;
    case WM_ACTIVATE:
    case WM_ACTIVATEAPP:
    case WM_SETFOCUS:
    case WM_KILLFOCUS:
      if (!away_.empty()) HideAgainSoon();
      break;
  }
}

void SessionLifecycle::Set(Away reason, bool away) {
  railgun_windows::RailgunPageHost& host = railgun_windows::RailgunPageHost::Get();
  if (away) {
    const bool was_away = !away_.empty();
    away_.insert(reason);
    railgun_windows::Dispatch::Get().Cancel(settle_timer_);
    settle_timer_ = 0;
    Send(kHidden);
    if (!was_away) host.SetSessionAway(true);
    return;
  }
  if (away_.erase(reason) == 0 || !away_.empty()) return;
  host.SetSessionAway(false);
  Send(CurrentState());
  railgun_windows::Dispatch::Get().Cancel(settle_timer_);
  settle_timer_ = railgun_windows::Dispatch::Get().After(kSettleMs, [this]() {
    settle_timer_ = 0;
    if (away_.empty()) Send(CurrentState());
  });
}

void SessionLifecycle::HideAgainSoon() {
  if (hide_timer_ != 0) return;
  hide_timer_ = railgun_windows::Dispatch::Get().After(kHideAgainMs, [this]() {
    hide_timer_ = 0;
    if (!away_.empty()) Send(kHidden);
  });
}

void SessionLifecycle::UpdateWindowShown(bool visible) {
  railgun_windows::RailgunPageHost::Get().SetWindowShown(visible && ::IsIconic(window_) == FALSE);
}

// What the embedder reports from the window's state: hidden while minimised or hidden, resumed while in front, else
// inactive.
const char* SessionLifecycle::CurrentState() const {
  if (::IsWindowVisible(window_) == FALSE || ::IsIconic(window_) != FALSE) return kHidden;
  return ::GetForegroundWindow() == window_ ? kResumed : kInactive;
}

void SessionLifecycle::Send(const char* state) {
  if (messenger_ == nullptr) return;
  messenger_->Send(kLifecycleChannel, reinterpret_cast<const uint8_t*>(state), std::strlen(state));
}
