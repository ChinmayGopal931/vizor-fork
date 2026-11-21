#include "railgun/railgun_dispatch.h"

#include <memory>
#include <utility>

namespace railgun_windows {
namespace {

constexpr wchar_t kClassName[] = L"VeylorRailgunDispatch";
constexpr UINT kTaskMessage = WM_APP + 0x52;

}  // namespace

Dispatch& Dispatch::Get() {
  static Dispatch dispatch;
  return dispatch;
}

Dispatch::Dispatch() {
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = &Dispatch::Proc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kClassName;
  ::RegisterClassExW(&window_class);
  window_ = ::CreateWindowExW(0, kClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, window_class.hInstance,
                              nullptr);
}

bool Dispatch::Post(std::function<void()> task) {
  if (window_ == nullptr) return false;
  auto* queued = new std::function<void()>(std::move(task));
  if (::PostMessageW(window_, kTaskMessage, 0, reinterpret_cast<LPARAM>(queued)) == 0) {
    delete queued;
    return false;
  }
  return true;
}

UINT_PTR Dispatch::After(UINT milliseconds, std::function<void()> fire) {
  if (window_ == nullptr) return 0;
  const UINT_PTR id = next_timer_++;
  if (::SetTimer(window_, id, milliseconds == 0 ? USER_TIMER_MINIMUM : milliseconds, nullptr) == 0) return 0;
  timers_[id] = std::move(fire);
  return id;
}

void Dispatch::Cancel(UINT_PTR timer) {
  if (timer == 0) return;
  if (timers_.erase(timer) > 0 && window_ != nullptr) ::KillTimer(window_, timer);
}

LRESULT CALLBACK Dispatch::Proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kTaskMessage) {
    std::unique_ptr<std::function<void()>> task(reinterpret_cast<std::function<void()>*>(lparam));
    if (task && *task) (*task)();
    return 0;
  }
  if (message == WM_TIMER) {
    ::KillTimer(window, wparam);
    Dispatch& dispatch = Get();
    auto found = dispatch.timers_.find(static_cast<UINT_PTR>(wparam));
    if (found == dispatch.timers_.end()) return 0;
    std::function<void()> fire = std::move(found->second);
    dispatch.timers_.erase(found);
    if (fire) fire();
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace railgun_windows
