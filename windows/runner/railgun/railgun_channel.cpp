#include "railgun/railgun_channel.h"

#include <utility>
#include <vector>

#include "railgun/railgun_dispatch.h"

namespace railgun_windows {

RailgunChannel::RailgunChannel(Deliver deliver, OnEvent on_event)
    : deliver_(std::move(deliver)), on_event_(std::move(on_event)) {}

RailgunChannel::~RailgunChannel() { Close(Error::Disconnected("closed")); }

void RailgunChannel::AwaitReady(unsigned timeout_ms, Ready done) {
  if (ready_) {
    done(nullptr);
    return;
  }
  if (closed_) {
    const Error error = Error::Disconnected(closed_by_.message);
    done(&error);
    return;
  }
  if (ready_waiter_) {
    const Error error = Error::Protocol("the page is already loading");
    done(&error);
    return;
  }
  ready_waiter_ = std::move(done);
  std::weak_ptr<int> alive = alive_;
  ready_timer_ = Dispatch::Get().After(timeout_ms, [this, alive]() {
    if (alive.expired()) return;
    ready_timer_ = 0;
    const Error error = Error::Timeout("loading the page");
    SettleReady(&error);
  });
}

void RailgunChannel::Call(const Method& method, const std::string& params_json, Reply reply) {
  if (closed_) {
    const Error error = Error::Disconnected(closed_by_.message);
    reply(&error, std::string());
    return;
  }
  const int64_t id = ++last_id_;
  std::string request;
  Error invalid;
  if (!railgun_protocol::Request(id, method, params_json, &request, &invalid)) {
    reply(&invalid, std::string());
    return;
  }
  std::weak_ptr<int> alive = alive_;
  const std::string name = method.name;
  Pending pending;
  pending.reply = std::move(reply);
  pending.timer =
      Dispatch::Get().After(static_cast<UINT>(method.timeout_seconds) * 1000u, [this, alive, id, name]() {
        if (alive.expired()) return;
        auto found = pending_.find(id);
        if (found != pending_.end()) found->second.timer = 0;
        const Error error = Error::Timeout(name);
        Settle(id, &error, std::string());
      });
  pending_[id] = std::move(pending);
  if (!deliver_ || !deliver_(request)) {
    const Error error = Error::Disconnected("the page did not take the call");
    Settle(id, &error, std::string());
  }
}

void RailgunChannel::Receive(const std::string& text) {
  if (closed_) return;
  railgun_protocol::Message message = railgun_protocol::Decode(text);
  switch (message.type) {
    case railgun_protocol::Message::Type::kReady:
      ready_ = true;
      SettleReady(nullptr);
      break;
    case railgun_protocol::Message::Type::kEvent:
      if (on_event_) on_event_(message.event, text);
      break;
    case railgun_protocol::Message::Type::kReply:
      Settle(message.id, nullptr, message.result_json);
      break;
    case railgun_protocol::Message::Type::kFailure:
      Settle(message.id, &message.error, std::string());
      break;
    case railgun_protocol::Message::Type::kNone:
      break;
  }
}

void RailgunChannel::Close(const Error& reason) {
  if (!closed_) {
    closed_ = true;
    closed_by_ = reason;
  }
  const Error error = Error::Disconnected(closed_by_.message);
  SettleReady(&error);
  std::map<int64_t, Pending> calls;
  calls.swap(pending_);
  for (auto& entry : calls) {
    Dispatch::Get().Cancel(entry.second.timer);
    if (entry.second.reply) entry.second.reply(&error, std::string());
  }
}

void RailgunChannel::Settle(int64_t id, const Error* error, const std::string& result_json) {
  auto found = pending_.find(id);
  if (found == pending_.end()) return;
  Pending call = std::move(found->second);
  pending_.erase(found);
  Dispatch::Get().Cancel(call.timer);
  if (call.reply) call.reply(error, result_json);
}

void RailgunChannel::SettleReady(const Error* error) {
  Dispatch::Get().Cancel(ready_timer_);
  ready_timer_ = 0;
  if (!ready_waiter_) return;
  Ready waiter = std::move(ready_waiter_);
  ready_waiter_ = nullptr;
  waiter(error);
}

}  // namespace railgun_windows
