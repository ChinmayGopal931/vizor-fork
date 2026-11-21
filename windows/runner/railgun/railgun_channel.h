#ifndef RUNNER_RAILGUN_RAILGUN_CHANNEL_H_
#define RUNNER_RAILGUN_RAILGUN_CHANNEL_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>

#include "private_usd/railgun_protocol.h"

namespace railgun_windows {

using railgun_protocol::Error;
using railgun_protocol::Method;

// One page's end of the transport, as the Mac's `RailgunChannel` (macos/Runner/Railgun/RailgunPage.swift): requests
// out, replies matched back to them, events to their listener. Every call is answered exactly once, by its reply, its
// failure, its timeout or the close, and everything fails once the channel closes. Params, results and events stay raw
// JSON text (Linux's `railgun_protocol`, which the Windows build compiles unchanged); nothing here logs them. UI thread
// only: its timers are the host's (railgun_dispatch.h).
class RailgunChannel {
 public:
  // Hands a request to the page; false when the page did not take it.
  using Deliver = std::function<bool(const std::string& request)>;
  using OnEvent = std::function<void(const std::string& name, const std::string& raw_json)>;
  // `error` is null for a reply, whose result's raw JSON is `result_json`.
  using Reply = std::function<void(const Error* error, const std::string& result_json)>;
  using Ready = std::function<void(const Error* error)>;

  RailgunChannel(Deliver deliver, OnEvent on_event);
  ~RailgunChannel();
  RailgunChannel(const RailgunChannel&) = delete;
  RailgunChannel& operator=(const RailgunChannel&) = delete;

  bool IsOpen() const { return !closed_; }
  bool IsReady() const { return ready_; }
  bool HasPendingCalls() const { return !pending_.empty(); }
  const Error& closed_by() const { return closed_by_; }

  // Calls `done` once: when the page says it is ready, or with why it never will (it timed out, or the channel closed).
  void AwaitReady(unsigned timeout_ms, Ready done);

  // Sends `method` with `params_json` (exactly one JSON object) and answers `reply` once.
  void Call(const Method& method, const std::string& params_json, Reply reply);

  // One message from the page, as it sent it.
  void Receive(const std::string& text);

  // Fails what waits and everything after; the first reason is kept.
  void Close(const Error& reason);

 private:
  struct Pending {
    Reply reply;
    UINT_PTR timer = 0;
  };

  // Whoever takes a call out of `pending_` answers it, so it is answered once.
  void Settle(int64_t id, const Error* error, const std::string& result_json);
  void SettleReady(const Error* error);

  Deliver deliver_;
  OnEvent on_event_;
  int64_t last_id_ = 0;
  std::map<int64_t, Pending> pending_;
  bool ready_ = false;
  bool closed_ = false;
  Error closed_by_;
  Ready ready_waiter_;
  UINT_PTR ready_timer_ = 0;
  // Timers hold it weakly, so one that fires after the channel went does nothing.
  std::shared_ptr<int> alive_ = std::make_shared<int>(0);
};

}  // namespace railgun_windows

#endif  // RUNNER_RAILGUN_RAILGUN_CHANNEL_H_
