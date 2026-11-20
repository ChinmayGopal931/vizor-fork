#ifndef RUNNER_RAILGUN_PAGE_WEBKIT_API_H_
#define RUNNER_RAILGUN_PAGE_WEBKIT_API_H_

// WebKitGTK 4.1, its JavaScriptCore and libsoup 3, loaded at run time. The page process is compiled against their
// headers and never linked to them, so nothing in the bundle needs WebKit: a computer without WebKitGTK still runs
// Veylor, with Shielded USD hidden. Every function is resolved into a `decltype(&fn)` pointer, and no macro that calls
// a `*_get_type` function is used (`WEBKIT_WEB_VIEW (…)` and the like); a direct call would fail the link.
#include <webkit2/webkit2.h>

#include <string>

namespace railgun_page {

#define RAILGUN_WEBKIT_FUNCTIONS(X)                       \
  X(webkit_get_major_version)                             \
  X(webkit_get_minor_version)                             \
  X(webkit_get_micro_version)                             \
  X(webkit_website_data_manager_new)                      \
  X(webkit_website_data_manager_new_ephemeral)            \
  X(webkit_website_data_manager_set_network_proxy_settings) \
  X(webkit_network_proxy_settings_new)                    \
  X(webkit_network_proxy_settings_free)                   \
  X(webkit_web_context_new_with_website_data_manager)     \
  X(webkit_web_context_set_sandbox_enabled)               \
  X(webkit_web_context_get_sandbox_enabled)               \
  X(webkit_web_context_set_cache_model)                   \
  X(webkit_web_context_register_uri_scheme)               \
  X(webkit_web_context_get_security_manager)              \
  X(webkit_security_manager_register_uri_scheme_as_secure) \
  X(webkit_security_manager_register_uri_scheme_as_cors_enabled) \
  X(webkit_user_content_manager_new)                      \
  X(webkit_user_content_manager_register_script_message_handler) \
  X(webkit_user_content_manager_add_filter)               \
  X(webkit_user_content_filter_store_new)                 \
  X(webkit_user_content_filter_store_save)                \
  X(webkit_user_content_filter_store_save_finish)         \
  X(webkit_user_content_filter_unref)                     \
  X(webkit_settings_get_type)                             \
  X(webkit_web_view_get_type)                             \
  X(webkit_web_view_set_background_color)                 \
  X(webkit_web_view_load_uri)                             \
  X(webkit_web_view_get_uri)                              \
  X(webkit_web_view_call_async_javascript_function)       \
  X(webkit_web_view_call_async_javascript_function_finish) \
  X(webkit_web_view_evaluate_javascript)                  \
  X(webkit_web_view_evaluate_javascript_finish)           \
  X(webkit_javascript_result_get_js_value)                \
  X(webkit_uri_scheme_request_get_path)                   \
  X(webkit_uri_scheme_request_get_uri)                    \
  X(webkit_uri_scheme_request_get_http_method)            \
  X(webkit_uri_scheme_request_finish_with_response)       \
  X(webkit_uri_scheme_request_finish_error)               \
  X(webkit_uri_scheme_response_new)                       \
  X(webkit_uri_scheme_response_set_status)                \
  X(webkit_uri_scheme_response_set_content_type)          \
  X(webkit_uri_scheme_response_set_http_headers)          \
  X(webkit_policy_decision_use)                           \
  X(webkit_policy_decision_ignore)                        \
  X(webkit_navigation_policy_decision_get_navigation_action) \
  X(webkit_navigation_action_get_request)                 \
  X(webkit_uri_request_get_uri)                           \
  X(webkit_permission_request_deny)                       \
  X(webkit_file_chooser_request_cancel)                   \
  X(webkit_download_cancel)                               \
  X(webkit_authentication_request_cancel)                 \
  X(jsc_value_is_string)                                  \
  X(jsc_value_is_boolean)                                 \
  X(jsc_value_to_boolean)                                 \
  X(jsc_value_to_string)                                  \
  X(soup_session_new_with_options)                        \
  X(soup_session_remove_feature_by_type)                  \
  X(soup_session_send_async)                              \
  X(soup_session_send_finish)                             \
  X(soup_session_abort)                                   \
  X(soup_content_decoder_get_type)                        \
  X(soup_content_sniffer_get_type)                        \
  X(soup_auth_manager_get_type)                           \
  X(soup_message_new)                                     \
  X(soup_message_set_flags)                               \
  X(soup_message_set_force_http1)                         \
  X(soup_message_get_status)                              \
  X(soup_message_get_request_headers)                     \
  X(soup_message_get_response_headers)                    \
  X(soup_message_headers_new)                             \
  X(soup_message_headers_append)                          \
  X(soup_message_headers_replace)                         \
  X(soup_message_headers_get_encoding)                    \
  X(soup_message_headers_get_content_length)              \
  X(soup_message_headers_get_content_type)

struct WebKitApi {
#define RAILGUN_DECLARE(name) decltype(&::name) name = nullptr;
  RAILGUN_WEBKIT_FUNCTIONS(RAILGUN_DECLARE)
#undef RAILGUN_DECLARE
};

// The oldest WebKitGTK the page runs on: the page's engine and the calls above need no older, and every distribution
// still supported ships a newer one.
inline constexpr unsigned kMinimumMajor = 2;
inline constexpr unsigned kMinimumMinor = 44;

// Loads WebKitGTK 4.1 and libsoup 3 and resolves every function, or says why it could not (a fixed text naming the
// library, the function or the version; nothing else).
bool LoadWebKit(WebKitApi* api, std::string* why);

// The loaded functions; valid once `LoadWebKit` succeeded.
const WebKitApi& Wk();

}  // namespace railgun_page

#endif  // RUNNER_RAILGUN_PAGE_WEBKIT_API_H_
