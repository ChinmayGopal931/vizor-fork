#include "private_usd_channels.h"

#include <flutter/standard_method_codec.h>

#include <string>
#include <variant>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> NewChannel(flutter::BinaryMessenger* messenger,
                                                                   const char* name) {
  return std::make_unique<flutter::MethodChannel<EncodableValue>>(messenger, name,
                                                                  &flutter::StandardMethodCodec::GetInstance());
}

// `{enabled: bool}`, or null.
const bool* EnabledArgument(const EncodableValue* arguments) {
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return nullptr;
  auto found = map->find(EncodableValue(std::string("enabled")));
  return found == map->end() ? nullptr : std::get_if<bool>(&found->second);
}

}  // namespace

PrivateUsdChannels::PrivateUsdChannels(flutter::BinaryMessenger* messenger, HWND window, HWND view)
    : window_(window) {
  railgun_ = std::make_unique<railgun_windows::RailgunHostChannels>(messenger, window, view);
  lifecycle_ = std::make_unique<SessionLifecycle>(messenger, window);

  // `com.zcash.wallet/screen_awake` on Windows (`setEnabled {enabled}`), the flag `SyncKeepAwakeNativeHost` owns:
  // while it is on, neither the display nor the computer sleeps on idle, as the phones keep their screen on and the
  // Mac holds an IOKit assertion. A locked or sleeping computer hides the app, and a hidden app pauses Private USD (plan
  // D9), so a Railgun first sync, or a bridge with a key step to come, would stall. It never stops the user locking the
  // computer or putting it to sleep, and Windows drops it with the process.
  screen_awake_ = NewChannel(messenger, "com.zcash.wallet/screen_awake");
  screen_awake_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "setEnabled") {
      result->NotImplemented();
      return;
    }
    const bool* enabled = EnabledArgument(call.arguments());
    if (enabled == nullptr) {
      result->Error("bad_args", "Expected enabled argument.");
      return;
    }
    const EXECUTION_STATE state =
        *enabled ? (ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED) : ES_CONTINUOUS;
    if (::SetThreadExecutionState(state) == 0) {
      result->Error("unavailable", "The idle hold was refused.");
      return;
    }
    awake_ = *enabled;
    result->Success();
  });

  // `com.zcash.wallet/haptics` on Windows, for its one desktop meaning: `settlementDeadline`, the phones' buzz when a
  // shielded USD → ZEC bridge first offers "Authorize settlement" (the user's turn) and again two minutes before it
  // closes. A computer has no haptics to buzz, so it asks for the user's attention instead, as the Mac and Linux do:
  // the window's taskbar button flashes until Veylor is in front again (not at all while it is), and the default
  // sound plays. Neither needs a permission or a notification, and nothing is shown or logged.
  //
  // Dart's `privateUsdSettlementReminderProvider` decides when: only while the app is in the foreground (a window
  // showing, focused or not) and unlocked, once per offer and once per closing. Every other haptics call answers not
  // implemented, so Dart falls back as before.
  haptics_ = NewChannel(messenger, "com.zcash.wallet/haptics");
  haptics_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "settlementDeadline") {
      result->NotImplemented();
      return;
    }
    if (window_ != nullptr && ::GetForegroundWindow() != window_) {
      FLASHWINFO flash = {};
      flash.cbSize = sizeof(flash);
      flash.hwnd = window_;
      flash.dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG;
      ::FlashWindowEx(&flash);
    }
    ::MessageBeep(MB_OK);
    result->Success(EncodableValue(true));
  });
}

PrivateUsdChannels::~PrivateUsdChannels() {
  for (auto* channel : {&screen_awake_, &haptics_}) {
    if (*channel) (*channel)->SetMethodCallHandler(nullptr);
  }
  if (awake_) ::SetThreadExecutionState(ES_CONTINUOUS);
  lifecycle_.reset();
  railgun_.reset();
}

void PrivateUsdChannels::OnWindowMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (lifecycle_) lifecycle_->OnWindowMessage(window, message, wparam, lparam);
}
