#ifndef RUNNER_PRIVATE_USD_RAILGUN_PROTOCOL_H_
#define RUNNER_PRIVATE_USD_RAILGUN_PROTOCOL_H_

#include <cstdint>
#include <string>
#include <string_view>

// The Railgun page's wire format on Linux: Kotlin's `RailgunProtocol` and iOS's, for the runner's end of the host.
// Params, results and events stay raw JSON text; Dart owns the typed models. Nothing here logs what it reads.
namespace railgun_protocol {

// Why a page call failed. Each kind is one of the channel's error codes, the same as Android's, iOS's and the Mac's,
// so Dart treats every host alike. A `kFailed` message is the engine's own text and can quote a keyed RPC URL: it goes
// to Dart, which redacts it before anything prints it, and is never logged here.
struct Error {
  enum class Kind { kDisconnected, kTimeout, kUnavailable, kProtocol, kFailed, kRpcFailed };
  Kind kind = Kind::kFailed;
  std::string message;

  static Error Disconnected(std::string message) { return {Kind::kDisconnected, std::move(message)}; }
  // `what` timed out.
  static Error Timeout(const std::string& what) { return {Kind::kTimeout, what + " timed out"}; }
  static Error Unavailable(std::string message) { return {Kind::kUnavailable, std::move(message)}; }
  static Error Protocol(std::string message) { return {Kind::kProtocol, std::move(message)}; }
  static Error Failed(std::string message) { return {Kind::kFailed, std::move(message)}; }

  // The channel's error code.
  const char* Code() const;
};

struct Method {
  const char* name;
  int timeout_seconds;
};

// Every call the page answers, its wire name, and how long it may take, in seconds: the same table as Kotlin's
// `RailgunMethod` (RailgunProtocol.kt). A Rust test (railgun_bridge.rs) reads this table, so keep its entries literal.
// A wallet's first sync (`refresh`) reads all of Railgun's history, half an hour or more on Ethereum, and keeps none
// of it until it's done; a timeout closes the page, which starts it over. `deleteWallet` is local only: it opens the
// page's database without a provider, on a page loaded for it alone.
inline constexpr Method kMethods[] = {
    {"start", 120},
    {"openWallet", 60},
    {"refresh", 7200},
    {"deleteWallet", 60},
    {"transfer", 600},
    {"unshield", 600},
    {"broadcasterFee", 120},
    {"reverseCost", 30},
    {"prepareReverse", 600},
};

// Engine lines; forwarded only from a page loaded with `debug`.
inline constexpr char kLogEvent[] = "log";

// What the page sends unasked, which goes on to Dart: Kotlin's `EVENTS`, which RailgunProtocolTest holds to every
// event the page emits. A Rust test (railgun_bridge.rs) reads this list, so keep its entries literal.
inline constexpr const char* kEvents[] = {"log", "scan", "proof", "screening", "refresh", "synced"};

// The method named `name`, or null.
const Method* FindMethod(std::string_view name);

// `params_json` must be exactly one JSON object, so it can't add keys to the envelope around it. It is spliced, not
// re-serialized, so large numbers keep every digit.
bool Request(int64_t id, const Method& method, const std::string& params_json, std::string* request, Error* error);

// Whether a `start` asks the page to read Anon's archive (`RailgunStartParams.archive`). Read for this alone; the
// params carry keyed RPC URLs and stay unlogged.
bool StartsWithArchive(const std::string& params_json);

// A message from the page, as this build reads it.
struct Message {
  enum class Type { kNone, kReady, kEvent, kReply, kFailure };
  Type type = Type::kNone;
  // An event's name; the whole message, `{"event": name, "data": …}`, goes on as the page sent it.
  std::string event;
  int64_t id = 0;
  std::string result_json;
  Error error;
};

// What `text` says; `kNone` for what this build can't read, except a reply: that one still fails its call.
Message Decode(const std::string& text);

}  // namespace railgun_protocol

#endif  // RUNNER_PRIVATE_USD_RAILGUN_PROTOCOL_H_
