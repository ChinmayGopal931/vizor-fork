#include "railgun/railgun_host_channels.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <knownfolders.h>
#include <shlobj.h>

#include <cstdint>
#include <filesystem>
#include <string>
#include <utility>
#include <variant>

#include "private_usd/railgun_protocol.h"
#include "railgun/railgun_page_host.h"
#include "railgun/railgun_text.h"
#include "resource_values.h"

namespace railgun_windows {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = flutter::MethodResult<EncodableValue>;

// Whether this build may debug the page at all; `load`'s `debug` can only narrow it.
#ifdef _DEBUG
constexpr bool kDebuggable = true;
#else
constexpr bool kDebuggable = false;
#endif

std::wstring ExecutableDirectory() {
  std::wstring path(MAX_PATH, L'\0');
  while (true) {
    const DWORD length = ::GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0) return std::wstring();
    if (length < path.size() - 1) {
      path.resize(length);
      break;
    }
    path.resize(path.size() * 2);
  }
  return std::filesystem::path(path).parent_path().wstring();
}

// `%LOCALAPPDATA%\<company>\<product>\railgun-page`: the app's local data, named by the version resource as
// path_provider names its directories and the uninstaller deletes them, so each identity (Veylor, Veylor Testnet,
// Vizor) keeps its own store, out of roaming profiles and File History.
std::wstring StoreDirectory() {
  PWSTR local = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr, &local)) || local == nullptr) {
    return std::wstring();
  }
  std::filesystem::path store(local);
  ::CoTaskMemFree(local);
  store /= Utf16(VIZOR_WINDOWS_COMPANY_NAME);
  store /= Utf16(VIZOR_WINDOWS_PRODUCT_NAME);
  store /= L"railgun-page";
  return store.wstring();
}

const EncodableValue* Argument(const EncodableValue* arguments, const char* key) {
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return nullptr;
  auto found = map->find(EncodableValue(std::string(key)));
  return found == map->end() ? nullptr : &found->second;
}

bool IntegerArgument(const EncodableValue* arguments, const char* key, int64_t* out) {
  const EncodableValue* value = Argument(arguments, key);
  if (value == nullptr) return false;
  // Not `small`: rpcndr.h, which windows.h pulls in, defines it as `char`.
  if (const auto* narrow = std::get_if<int32_t>(value)) {
    *out = *narrow;
    return true;
  }
  if (const auto* wide = std::get_if<int64_t>(value)) {
    *out = *wide;
    return true;
  }
  return false;
}

const std::string* StringArgument(const EncodableValue* arguments, const char* key) {
  const EncodableValue* value = Argument(arguments, key);
  return value == nullptr ? nullptr : std::get_if<std::string>(value);
}

bool BoolArgument(const EncodableValue* arguments, const char* key) {
  const EncodableValue* value = Argument(arguments, key);
  const bool* flag = value == nullptr ? nullptr : std::get_if<bool>(value);
  return flag != nullptr && *flag;
}

// Exactly one answer per call: whoever holds the result answers it and lets it go.
std::shared_ptr<std::unique_ptr<Result>> Share(std::unique_ptr<Result> result) {
  return std::make_shared<std::unique_ptr<Result>>(std::move(result));
}

void Answer(const std::shared_ptr<std::unique_ptr<Result>>& result, const Error* error) {
  if (!*result) return;
  if (error != nullptr) {
    (*result)->Error(error->Code(), error->message);
  } else {
    (*result)->Success();
  }
  result->reset();
}

void OnCall(const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<Result> result) {
  const std::string& name = call.method_name();
  const EncodableValue* arguments = call.arguments();
  RailgunPageHost& host = RailgunPageHost::Get();
  if (name == "supported") {
    result->Success(EncodableValue(RailgunPageHost::IsSupported()));
  } else if (name == "load") {
    int64_t port = 0;
    if (!IntegerArgument(arguments, "proxyPort", &port) || port < 1 || port > 65535) {
      result->Error("bad_args", "proxyPort");
      return;
    }
    const bool debug = kDebuggable && BoolArgument(arguments, "debug");
    auto shared = Share(std::move(result));
    host.Load(static_cast<int>(port), debug, [shared](const Error* error) { Answer(shared, error); });
  } else if (name == "call") {
    const std::string* method_name = StringArgument(arguments, "method");
    const std::string* params = StringArgument(arguments, "paramsJson");
    const railgun_protocol::Method* method =
        method_name == nullptr ? nullptr : railgun_protocol::FindMethod(*method_name);
    if (method == nullptr || params == nullptr) {
      result->Error("bad_args", "method or paramsJson");
      return;
    }
    auto shared = Share(std::move(result));
    host.Call(*method, *params, [shared](const Error* error, const std::string& result_json) {
      if (!*shared) return;
      if (error != nullptr) {
        (*shared)->Error(error->Code(), error->message);
      } else {
        (*shared)->Success(EncodableValue(result_json));
      }
      shared->reset();
    });
  } else if (name == "close") {
    host.Close();
    result->Success();
  } else if (name == "wipe") {
    auto shared = Share(std::move(result));
    host.Wipe([shared](const Error* error) { Answer(shared, error); });
  } else if (name == "isOpen") {
    result->Success(EncodableValue(host.IsOpen()));
  } else {
    result->NotImplemented();
  }
}

}  // namespace

RailgunHostChannels::RailgunHostChannels(flutter::BinaryMessenger* messenger, HWND window, HWND view) {
  RailgunPageHost& host = RailgunPageHost::Get();
  host.Attach(window, view);
  host.SetPaths({ExecutableDirectory() + L"\\data\\railgun", StoreDirectory()});

  methods_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "com.zcash.wallet/railgun", &flutter::StandardMethodCodec::GetInstance());
  methods_->SetMethodCallHandler(OnCall);

  events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, "com.zcash.wallet/railgun/events", &flutter::StandardMethodCodec::GetInstance());
  events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        std::shared_ptr<flutter::EventSink<EncodableValue>> sink(std::move(events));
        RailgunPageHost::Get().SetEventSink(
            [sink](const std::string& raw_json) { sink->Success(EncodableValue(raw_json)); });
        return nullptr;
      },
      [](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        RailgunPageHost::Get().SetEventSink(nullptr);
        return nullptr;
      }));
}

RailgunHostChannels::~RailgunHostChannels() {
  RailgunPageHost& host = RailgunPageHost::Get();
  host.SetEventSink(nullptr);
  if (methods_) methods_->SetMethodCallHandler(nullptr);
  if (events_) events_->SetStreamHandler(nullptr);
  // The engine is going: so is its page, and every WebView2 object with it, while COM is still up.
  host.Shutdown();
  host.Attach(nullptr, nullptr);
}

}  // namespace railgun_windows
