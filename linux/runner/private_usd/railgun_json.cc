#include "private_usd/railgun_json.h"

#include <limits>

namespace railgun_json {
namespace {

// Far deeper than anything the page sends; a deeper document is refused rather than read.
constexpr int kMaxDepth = 256;

class Reader {
 public:
  explicit Reader(std::string_view text) : text_(text) {}

  bool ReadDocument(Value* value) {
    SkipSpace();
    if (!ReadValue(value, 0)) return false;
    SkipSpace();
    return pos_ == text_.size();
  }

  // Reads the members of the object starting at `pos_`.
  bool ReadMembers(Members* members) {
    if (!Consume('{')) return false;
    SkipSpace();
    if (Consume('}')) return true;
    while (true) {
      SkipSpace();
      Value key;
      if (!ReadString(&key)) return false;
      std::string name;
      if (!DecodeString(text_, key, &name)) return false;
      SkipSpace();
      if (!Consume(':')) return false;
      SkipSpace();
      Value member;
      if (!ReadValue(&member, 1)) return false;
      members->emplace_back(std::move(name), member);
      SkipSpace();
      if (Consume(',')) continue;
      return Consume('}');
    }
  }

  void Seek(size_t pos) { pos_ = pos; }

 private:
  bool ReadValue(Value* value, int depth) {
    if (depth > kMaxDepth || pos_ >= text_.size()) return false;
    const size_t begin = pos_;
    bool ok = false;
    switch (text_[pos_]) {
      case '{':
        value->kind = Kind::kObject;
        ok = SkipObject(depth);
        break;
      case '[':
        value->kind = Kind::kArray;
        ok = SkipArray(depth);
        break;
      case '"': {
        Value string;
        ok = ReadString(&string);
        value->kind = Kind::kString;
        break;
      }
      case 't':
        value->kind = Kind::kTrue;
        ok = Literal("true");
        break;
      case 'f':
        value->kind = Kind::kFalse;
        ok = Literal("false");
        break;
      case 'n':
        value->kind = Kind::kNull;
        ok = Literal("null");
        break;
      default:
        value->kind = Kind::kNumber;
        ok = SkipNumber();
        break;
    }
    value->begin = begin;
    value->end = pos_;
    return ok;
  }

  bool SkipObject(int depth) {
    Consume('{');
    SkipSpace();
    if (Consume('}')) return true;
    while (true) {
      SkipSpace();
      Value key;
      if (!ReadString(&key)) return false;
      SkipSpace();
      if (!Consume(':')) return false;
      SkipSpace();
      Value member;
      if (!ReadValue(&member, depth + 1)) return false;
      SkipSpace();
      if (Consume(',')) continue;
      return Consume('}');
    }
  }

  bool SkipArray(int depth) {
    Consume('[');
    SkipSpace();
    if (Consume(']')) return true;
    while (true) {
      SkipSpace();
      Value element;
      if (!ReadValue(&element, depth + 1)) return false;
      SkipSpace();
      if (Consume(',')) continue;
      return Consume(']');
    }
  }

  // A string token, checked but not decoded.
  bool ReadString(Value* value) {
    value->kind = Kind::kString;
    value->begin = pos_;
    if (!Consume('"')) return false;
    while (pos_ < text_.size()) {
      const unsigned char c = static_cast<unsigned char>(text_[pos_++]);
      if (c == '"') {
        value->end = pos_;
        return true;
      }
      if (c < 0x20) return false;
      if (c != '\\') continue;
      if (pos_ >= text_.size()) return false;
      const char escape = text_[pos_++];
      switch (escape) {
        case '"':
        case '\\':
        case '/':
        case 'b':
        case 'f':
        case 'n':
        case 'r':
        case 't':
          break;
        case 'u':
          for (int i = 0; i < 4; ++i) {
            if (pos_ >= text_.size() || !IsHex(text_[pos_++])) return false;
          }
          break;
        default:
          return false;
      }
    }
    return false;
  }

  bool SkipNumber() {
    Consume('-');
    if (pos_ >= text_.size()) return false;
    if (text_[pos_] == '0') {
      ++pos_;
    } else if (IsDigit(text_[pos_])) {
      while (pos_ < text_.size() && IsDigit(text_[pos_])) ++pos_;
    } else {
      return false;
    }
    if (Consume('.')) {
      if (pos_ >= text_.size() || !IsDigit(text_[pos_])) return false;
      while (pos_ < text_.size() && IsDigit(text_[pos_])) ++pos_;
    }
    if (pos_ < text_.size() && (text_[pos_] == 'e' || text_[pos_] == 'E')) {
      ++pos_;
      if (!Consume('+')) Consume('-');
      if (pos_ >= text_.size() || !IsDigit(text_[pos_])) return false;
      while (pos_ < text_.size() && IsDigit(text_[pos_])) ++pos_;
    }
    return true;
  }

  bool Literal(std::string_view literal) {
    if (text_.substr(pos_, literal.size()) != literal) return false;
    pos_ += literal.size();
    return true;
  }

  bool Consume(char c) {
    if (pos_ < text_.size() && text_[pos_] == c) {
      ++pos_;
      return true;
    }
    return false;
  }

  void SkipSpace() {
    while (pos_ < text_.size() &&
           (text_[pos_] == ' ' || text_[pos_] == '\t' || text_[pos_] == '\n' || text_[pos_] == '\r')) {
      ++pos_;
    }
  }

  static bool IsDigit(char c) { return c >= '0' && c <= '9'; }
  static bool IsHex(char c) { return IsDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }

  std::string_view text_;
  size_t pos_ = 0;
};

int HexValue(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return c - 'A' + 10;
}

void AppendUtf8(uint32_t code, std::string* out) {
  if (code < 0x80) {
    out->push_back(static_cast<char>(code));
  } else if (code < 0x800) {
    out->push_back(static_cast<char>(0xC0 | (code >> 6)));
    out->push_back(static_cast<char>(0x80 | (code & 0x3F)));
  } else if (code < 0x10000) {
    out->push_back(static_cast<char>(0xE0 | (code >> 12)));
    out->push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | (code & 0x3F)));
  } else {
    out->push_back(static_cast<char>(0xF0 | (code >> 18)));
    out->push_back(static_cast<char>(0x80 | ((code >> 12) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | (code & 0x3F)));
  }
}

}  // namespace

bool Parse(std::string_view text, Value* value) {
  Reader reader(text);
  return reader.ReadDocument(value);
}

bool ObjectMembers(std::string_view text, const Value& value, Members* members) {
  if (value.kind != Kind::kObject) return false;
  Reader reader(text.substr(0, value.end));
  reader.Seek(value.begin);
  members->clear();
  return reader.ReadMembers(members);
}

const Value* Find(const Members& members, std::string_view key) {
  const Value* found = nullptr;
  for (const auto& member : members) {
    if (member.first == key) found = &member.second;
  }
  return found;
}

bool DecodeString(std::string_view text, const Value& value, std::string* out) {
  if (value.kind != Kind::kString || value.end < value.begin + 2) return false;
  out->clear();
  // Between the quotes; the token was checked when it was read.
  size_t pos = value.begin + 1;
  const size_t end = value.end - 1;
  auto hex4 = [&](size_t at) {
    uint32_t code = 0;
    for (size_t i = 0; i < 4; ++i) code = (code << 4) | static_cast<uint32_t>(HexValue(text[at + i]));
    return code;
  };
  while (pos < end) {
    const char c = text[pos++];
    if (c != '\\') {
      out->push_back(c);
      continue;
    }
    const char escape = text[pos++];
    switch (escape) {
      case 'b':
        out->push_back('\b');
        break;
      case 'f':
        out->push_back('\f');
        break;
      case 'n':
        out->push_back('\n');
        break;
      case 'r':
        out->push_back('\r');
        break;
      case 't':
        out->push_back('\t');
        break;
      case 'u': {
        uint32_t code = hex4(pos);
        pos += 4;
        if (code >= 0xD800 && code <= 0xDBFF && pos + 6 <= end && text[pos] == '\\' && text[pos + 1] == 'u') {
          const uint32_t low = hex4(pos + 2);
          if (low >= 0xDC00 && low <= 0xDFFF) {
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
            pos += 6;
          }
        }
        // A lone surrogate is no character.
        if (code >= 0xD800 && code <= 0xDFFF) code = 0xFFFD;
        AppendUtf8(code, out);
        break;
      }
      default:
        out->push_back(escape);
        break;
    }
  }
  return true;
}

bool Integer(std::string_view text, const Value& value, int64_t* out) {
  if (value.kind != Kind::kNumber) return false;
  std::string_view digits = Raw(text, value);
  bool negative = false;
  if (!digits.empty() && digits.front() == '-') {
    negative = true;
    digits.remove_prefix(1);
  }
  if (digits.empty() || digits.size() > 19) return false;
  uint64_t magnitude = 0;
  for (char c : digits) {
    if (c < '0' || c > '9') return false;
    magnitude = magnitude * 10 + static_cast<uint64_t>(c - '0');
  }
  const uint64_t limit = static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) + (negative ? 1 : 0);
  if (magnitude > limit) return false;
  *out = negative ? static_cast<int64_t>(0 - magnitude) : static_cast<int64_t>(magnitude);
  return true;
}

std::string Quote(std::string_view text) {
  static const char kHex[] = "0123456789abcdef";
  std::string out;
  out.reserve(text.size() + 2);
  out.push_back('"');
  for (char c : text) {
    const unsigned char u = static_cast<unsigned char>(c);
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (u < 0x20) {
          out += "\\u00";
          out.push_back(kHex[u >> 4]);
          out.push_back(kHex[u & 0xF]);
        } else {
          out.push_back(c);
        }
    }
  }
  out.push_back('"');
  return out;
}

}  // namespace railgun_json
