cmake_minimum_required(VERSION 3.14)
project(railgun_page_check LANGUAGES CXX)

# The Railgun page host's check program (docs/private-usd-windows.md, "What has
# run"): the host's own page code (runner/railgun) and Linux's shared protocol,
# JSON and endpoints files, driven by railgun_page_check.cpp as Dart drives the
# host, with no Flutter, wallet or storage. Not part of the app.
#
#   cmake -S windows/runner/tests/railgun_page -B build/railgun-page-check -A x64
#   cmake --build build/railgun-page-check --config Release
#
# scripts/windows-railgun/check_railgun_page.py runs it against a stand-in for
# the Rust bridge.
set(RUNNER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../..")
set(LINUX_RUNNER_DIR "${RUNNER_DIR}/../../linux/runner")
include("${RUNNER_DIR}/webview2_sdk.cmake")

if(CMAKE_GENERATOR_PLATFORM MATCHES "[Aa][Rr][Mm]64" OR
   (NOT CMAKE_GENERATOR_PLATFORM AND CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|aarch64|arm64"))
  set(CHECK_ARCH "arm64")
else()
  set(CHECK_ARCH "x64")
endif()
veylor_webview2_sdk(WEBVIEW2_INCLUDE WEBVIEW2_LOADER "${CHECK_ARCH}")

add_executable(railgun_page_check
  railgun_page_check.cpp
  "${RUNNER_DIR}/railgun/railgun_archive.cpp"
  "${RUNNER_DIR}/railgun/railgun_channel.cpp"
  "${RUNNER_DIR}/railgun/railgun_dispatch.cpp"
  "${RUNNER_DIR}/railgun/railgun_network.cpp"
  "${RUNNER_DIR}/railgun/railgun_page.cpp"
  "${RUNNER_DIR}/railgun/railgun_page_host.cpp"
  "${RUNNER_DIR}/railgun/railgun_requests.cpp"
  "${LINUX_RUNNER_DIR}/private_usd/railgun_json.cc"
  "${LINUX_RUNNER_DIR}/private_usd/railgun_protocol.cc"
  "${LINUX_RUNNER_DIR}/railgun_page/railgun_endpoints.cc"
)
target_compile_features(railgun_page_check PRIVATE cxx_std_17)
target_compile_options(railgun_page_check PRIVATE /W4 /WX /wd4100 /utf-8 /EHsc)
target_compile_definitions(railgun_page_check PRIVATE UNICODE _UNICODE NOMINMAX "_HAS_EXCEPTIONS=0")
target_include_directories(railgun_page_check PRIVATE
  "${RUNNER_DIR}" "${LINUX_RUNNER_DIR}" "${WEBVIEW2_INCLUDE}")
target_link_libraries(railgun_page_check PRIVATE
  "${WEBVIEW2_LOADER}" iphlpapi.lib ole32.lib shell32.lib shlwapi.lib user32.lib version.lib ws2_32.lib)
