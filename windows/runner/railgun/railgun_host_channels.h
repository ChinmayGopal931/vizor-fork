#ifndef RUNNER_RAILGUN_RAILGUN_HOST_CHANNELS_H_
#define RUNNER_RAILGUN_RAILGUN_HOST_CHANNELS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

namespace railgun_windows {

// Binds the process-wide Railgun page (railgun_page_host.h) to Dart, over the contract every host speaks (checklist
// H1): `com.zcash.wallet/railgun` answers `supported`, `load {proxyPort, debug}`, `call {method, paramsJson}`, `close`,
// `wipe` and `isOpen` with Android's, iOS's, the Mac's and Linux's codes, exactly once each, and
// `com.zcash.wallet/railgun/events` carries the page's events as their raw JSON. Registered with the app's channels,
// before Dart's bootstrap asks `supported`.
//
// Never log a call's `paramsJson`, its result or a failure's message: `start` carries keyed RPC URLs, `openWallet`
// and `deleteWallet` a mnemonic, and engine errors can quote either.
class RailgunHostChannels {
 public:
  // `window` is the app's window, where the page's 1x1 window goes; `view` the Flutter view, which keeps the keyboard.
  RailgunHostChannels(flutter::BinaryMessenger* messenger, HWND window, HWND view);
  ~RailgunHostChannels();
  RailgunHostChannels(const RailgunHostChannels&) = delete;
  RailgunHostChannels& operator=(const RailgunHostChannels&) = delete;

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methods_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
};

}  // namespace railgun_windows

#endif  // RUNNER_RAILGUN_RAILGUN_HOST_CHANNELS_H_
