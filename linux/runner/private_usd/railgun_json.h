#ifndef RUNNER_PRIVATE_USD_RAILGUN_JSON_H_
#define RUNNER_PRIVATE_USD_RAILGUN_JSON_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

// A strict JSON reader for the Railgun page's wire format, which keeps every value as the text it was sent in: the
// host passes params, results and events on as raw JSON, as Kotlin's and Swift's hosts do, so large numbers keep
// every digit. It reads, never re-serializes, and never logs what it reads.
namespace railgun_json {

enum class Kind { kObject, kArray, kString, kNumber, kTrue, kFalse, kNull };

// One value: its kind and where its text starts and ends in the document.
struct Value {
  Kind kind = Kind::kNull;
  size_t begin = 0;
  size_t end = 0;
};

using Members = std::vector<std::pair<std::string, Value>>;

// `text` is exactly one JSON value, with only whitespace around it. Fills `value`.
bool Parse(std::string_view text, Value* value);

// The members of object `value`, keys decoded, in the order sent (a key sent twice is kept twice).
bool ObjectMembers(std::string_view text, const Value& value, Members* members);

// The last member named `key`, as JavaScript reads a duplicated key; null if there is none.
const Value* Find(const Members& members, std::string_view key);

// String `value` decoded to UTF-8.
bool DecodeString(std::string_view text, const Value& value, std::string* out);

// Number `value` when it is an integer that fits in 64 bits: no fraction or exponent.
bool Integer(std::string_view text, const Value& value, int64_t* out);

// The value's text as sent.
inline std::string_view Raw(std::string_view text, const Value& value) {
  return text.substr(value.begin, value.end - value.begin);
}

// `text` quoted as a JSON string.
std::string Quote(std::string_view text);

}  // namespace railgun_json

#endif  // RUNNER_PRIVATE_USD_RAILGUN_JSON_H_
