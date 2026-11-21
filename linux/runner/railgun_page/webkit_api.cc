#include "railgun_page/webkit_api.h"

#include <dlfcn.h>

namespace railgun_page {
namespace {

WebKitApi g_api;

void* Open(const char* name, std::string* why) {
  void* handle = dlopen(name, RTLD_NOW | RTLD_LOCAL);
  if (handle == nullptr) *why = std::string(name) + " is not installed";
  return handle;
}

}  // namespace

bool LoadWebKit(WebKitApi* api, std::string* why) {
  // The 4.1 API is GTK 3's, which this process and Flutter's runner use.
  void* webkit = Open("libwebkit2gtk-4.1.so.0", why);
  if (webkit == nullptr) return false;
  void* javascriptcore = Open("libjavascriptcoregtk-4.1.so.0", why);
  if (javascriptcore == nullptr) return false;
  void* soup = Open("libsoup-3.0.so.0", why);
  if (soup == nullptr) return false;

  auto resolve = [&](const char* name) -> void* {
    if (void* symbol = dlsym(webkit, name)) return symbol;
    if (void* symbol = dlsym(javascriptcore, name)) return symbol;
    return dlsym(soup, name);
  };
#define RAILGUN_RESOLVE(name)                                       \
  api->name = reinterpret_cast<decltype(&::name)>(resolve(#name)); \
  if (api->name == nullptr) {                                       \
    *why = "WebKitGTK has no " #name;                               \
    return false;                                                   \
  }
  RAILGUN_WEBKIT_FUNCTIONS(RAILGUN_RESOLVE)
#undef RAILGUN_RESOLVE
  api->soup_message_set_force_http1 =
      reinterpret_cast<void (*)(SoupMessage*, gboolean)>(resolve("soup_message_set_force_http1"));

  const unsigned major = api->webkit_get_major_version();
  const unsigned minor = api->webkit_get_minor_version();
  if (major < kMinimumMajor || (major == kMinimumMajor && minor < kMinimumMinor)) {
    *why = "WebKitGTK " + std::to_string(major) + "." + std::to_string(minor) + " is older than " +
           std::to_string(kMinimumMajor) + "." + std::to_string(kMinimumMinor);
    return false;
  }
  g_api = *api;
  return true;
}

const WebKitApi& Wk() { return g_api; }

}  // namespace railgun_page
