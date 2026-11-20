#include "private_usd/railgun_protocol.h"

#include <cstring>

#include "private_usd/railgun_json.h"

namespace railgun_protocol {

const char* Error::Code() const {
  switch (kind) {
    case Kind::kDisconnected:
      return "closed";
    case Kind::kTimeout:
      return "timeout";
    case Kind::kUnavailable:
      return "unavailable";
    case Kind::kProtocol:
      return "protocol";
    case Kind::kFailed:
      return "failed";
    case Kind::kRpcFailed:
      return "rpc_failed";
  }
  return "failed";
}

const Method* FindMethod(std::string_view name) {
  for (const Method& method : kMethods) {
    if (name == method.name) return &method;
  }
  return nullptr;
}

bool Request(int64_t id, const Method& method, const std::string& params_json, std::string* request, Error* error) {
  railgun_json::Value params;
  if (!railgun_json::Parse(params_json, &params) || params.kind != railgun_json::Kind::kObject) {
    *error = Error::Protocol(std::string(method.name) + " params must be one JSON object");
    return false;
  }
  *request = "{\"id\":" + std::to_string(id) + ",\"method\":" + railgun_json::Quote(method.name) +
             ",\"params\":" + params_json + "}";
  return true;
}

bool StartsWithArchive(const std::string& params_json) {
  railgun_json::Value params;
  railgun_json::Members members;
  if (!railgun_json::Parse(params_json, &params) ||
      !railgun_json::ObjectMembers(params_json, params, &members)) {
    return false;
  }
  const railgun_json::Value* archive = railgun_json::Find(members, "archive");
  return archive != nullptr && archive->kind == railgun_json::Kind::kTrue;
}

namespace {

bool IsEvent(const std::string& name) {
  for (const char* event : kEvents) {
    if (name == event) return true;
  }
  return false;
}

Error Unreadable() { return Error::Protocol("the page's reply is unreadable"); }

}  // namespace

Message Decode(const std::string& text) {
  Message message;
  railgun_json::Value root;
  railgun_json::Members members;
  if (!railgun_json::Parse(text, &root) || !railgun_json::ObjectMembers(text, root, &members)) return message;

  if (const railgun_json::Value* event = railgun_json::Find(members, "event")) {
    std::string name;
    if (!railgun_json::DecodeString(text, *event, &name)) return message;
    if (name == "ready") {
      message.type = Message::Type::kReady;
    } else if (IsEvent(name)) {
      message.type = Message::Type::kEvent;
      message.event = std::move(name);
    }
    return message;
  }

  // A JSON `true` is no id, nor is a fraction.
  const railgun_json::Value* id = railgun_json::Find(members, "id");
  if (id == nullptr || !railgun_json::Integer(text, *id, &message.id)) return message;

  const railgun_json::Value* error = railgun_json::Find(members, "error");
  if (error != nullptr && error->kind != railgun_json::Kind::kNull) {
    message.type = Message::Type::kFailure;
    railgun_json::Members wire;
    if (error->kind != railgun_json::Kind::kObject || !railgun_json::ObjectMembers(text, *error, &wire)) {
      message.error = Unreadable();
      return message;
    }
    std::string reason;
    const railgun_json::Value* reason_value = railgun_json::Find(wire, "message");
    if (reason_value == nullptr || !railgun_json::DecodeString(text, *reason_value, &reason) || reason.empty()) {
      reason = "the page failed";
    }
    std::string code;
    const railgun_json::Value* code_value = railgun_json::Find(wire, "code");
    if (code_value != nullptr) railgun_json::DecodeString(text, *code_value, &code);
    if (code == "BAD_REQUEST") {
      message.error = Error::Protocol(std::move(reason));
    } else if (code == "RPC_FAILED") {
      message.error = {Error::Kind::kRpcFailed, std::move(reason)};
    } else {
      message.error = Error::Failed(std::move(reason));
    }
    return message;
  }

  message.type = Message::Type::kReply;
  const railgun_json::Value* result = railgun_json::Find(members, "result");
  message.result_json =
      result == nullptr ? std::string("null") : std::string(railgun_json::Raw(text, *result));
  return message;
}

}  // namespace railgun_protocol
