#ifndef RUNNER_PRIVATE_USD_CHANNELS_H_
#define RUNNER_PRIVATE_USD_CHANNELS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

#include "session_lifecycle.h"
#include "railgun/railgun_host_channels.h"

// Shielded USD's channels on Windows, as on the Mac and Linux (docs/private-usd-windows.md): the Railgun page
// (railgun/railgun_host_channels.h), Privacy Pass attestation (`unavailable`), the keep-awake flag
// (`SetThreadExecutionState`), the settlement reminder (the taskbar button flashes, and the default sound plays) and
// the session lifecycle (session_lifecycle.h). Registered in FlutterWindow::OnCreate, before Dart's bootstrap asks the
// page host `supported`.
class PrivateUsdChannels {
 public:
  PrivateUsdChannels(flutter::BinaryMessenger* messenger, HWND window, HWND view);
  ~PrivateUsdChannels();
  PrivateUsdChannels(const PrivateUsdChannels&) = delete;
  PrivateUsdChannels& operator=(const PrivateUsdChannels&) = delete;

  // Every message of the app's window, after Flutter has seen it.
  void OnWindowMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam);

 private:
  HWND window_;
  std::unique_ptr<railgun_windows::RailgunHostChannels> railgun_;
  std::unique_ptr<SessionLifecycle> lifecycle_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> attestation_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> screen_awake_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> haptics_;
  bool awake_ = false;
};

#endif  // RUNNER_PRIVATE_USD_CHANNELS_H_
