#ifndef RUNNER_RAILGUN_RAILGUN_DISPATCH_H_
#define RUNNER_RAILGUN_RAILGUN_DISPATCH_H_

#include <windows.h>

#include <functional>
#include <unordered_map>

namespace railgun_windows {

// Runs the Railgun host's work on the UI thread, where WebView2 and Flutter's channels live: its timers, and what other
// threads hand back (the archive's answers, from the wallet library's threads). A message-only window, so it shows
// nowhere and takes no input. One per process, made on the UI thread by its first use (the page host makes it).
class Dispatch {
 public:
  static Dispatch& Get();

  Dispatch(const Dispatch&) = delete;
  Dispatch& operator=(const Dispatch&) = delete;

  // Runs `task` on the UI thread after the messages already queued. Any thread. False when it can't be queued.
  bool Post(std::function<void()> task);

  // Calls `fire` once, `milliseconds` from now, on the UI thread; returns 0 when no timer could be set. UI thread only.
  UINT_PTR After(UINT milliseconds, std::function<void()> fire);

  // A timer that has not fired is dropped. UI thread only.
  void Cancel(UINT_PTR timer);

 private:
  Dispatch();
  static LRESULT CALLBACK Proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);

  HWND window_ = nullptr;
  std::unordered_map<UINT_PTR, std::function<void()>> timers_;
  UINT_PTR next_timer_ = 1;
};

}  // namespace railgun_windows

#endif  // RUNNER_RAILGUN_RAILGUN_DISPATCH_H_
