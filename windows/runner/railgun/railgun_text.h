#ifndef RUNNER_RAILGUN_RAILGUN_TEXT_H_
#define RUNNER_RAILGUN_RAILGUN_TEXT_H_

#include <windows.h>

#include <objbase.h>

#include <string>
#include <string_view>

// Text between WebView2's UTF-16 and the page's wire format (UTF-8 JSON). Free of Flutter, so the check program in
// tests/railgun_page builds it too.
namespace railgun_windows {

// UTF-16 `text` as UTF-8; empty when it isn't valid UTF-16.
inline std::string Utf8(std::wstring_view text) {
  if (text.empty()) return std::string();
  const int length = static_cast<int>(text.size());
  const int size =
      ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), length, nullptr, 0, nullptr, nullptr);
  if (size <= 0) return std::string();
  std::string out(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), length, out.data(), size, nullptr, nullptr);
  return out;
}

// UTF-8 `text` as UTF-16; empty when it isn't valid UTF-8.
inline std::wstring Utf16(std::string_view text) {
  if (text.empty()) return std::wstring();
  const int length = static_cast<int>(text.size());
  const int size = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), length, nullptr, 0);
  if (size <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), length, out.data(), size);
  return out;
}

// A string WebView2 hands over (CoTaskMemAlloc'd), freed when this goes.
class CoString {
 public:
  CoString() = default;
  ~CoString() { ::CoTaskMemFree(value_); }
  CoString(const CoString&) = delete;
  CoString& operator=(const CoString&) = delete;

  LPWSTR* put() {
    ::CoTaskMemFree(value_);
    value_ = nullptr;
    return &value_;
  }
  std::wstring_view view() const { return value_ == nullptr ? std::wstring_view() : std::wstring_view(value_); }
  const wchar_t* get() const { return value_; }

 private:
  LPWSTR value_ = nullptr;
};

}  // namespace railgun_windows

#endif  // RUNNER_RAILGUN_RAILGUN_TEXT_H_
