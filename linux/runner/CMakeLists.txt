cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "caps_lock_channel.cc"
  "single_instance.cc"
  "private_usd/private_usd_channels.cc"
  "private_usd/railgun_frames.cc"
  "private_usd/railgun_host.cc"
  "private_usd/railgun_json.cc"
  "private_usd/railgun_protocol.cc"
  "private_usd/session_lifecycle.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
# Shielded USD's host code (private_usd/) is C++17.
target_compile_features(${BINARY_NAME} PRIVATE cxx_std_17)

# Add preprocessor definitions for the application identity.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")
add_definitions(-DAPP_DISPLAY_NAME="${APP_DISPLAY_NAME}")
add_definitions(-DAPP_ICON_NAME="${APPLICATION_ID}")
add_definitions(-DAPP_ICON_THEME_PATH="${CMAKE_SOURCE_DIR}/icons")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}")

# Shielded USD's Railgun page process (docs/private-usd.md, "Private USD"): the page runs
# in it, on the system's WebKitGTK 4.1, which it loads at run time. It is built
# against WebKitGTK's headers and never linked to WebKit, libsoup or
# JavaScriptCore, so nothing in the bundle needs them; without the headers the
# build has no page process and Shielded USD stays hidden. It carries no RPATH:
# Veylor starts it with a clean environment, so it loads the system's libraries
# alone, never the AppImage's.
pkg_check_modules(RAILGUN_WEBKIT QUIET webkit2gtk-4.1)
if(RAILGUN_WEBKIT_FOUND)
  add_executable(railgun_page
    "railgun_page/railgun_page_main.cc"
    "railgun_page/railgun_page.cc"
    "railgun_page/railgun_archive.cc"
    "railgun_page/railgun_endpoints.cc"
    "railgun_page/webkit_api.cc"
    "private_usd/railgun_frames.cc"
  )
  apply_standard_settings(railgun_page)
  target_compile_features(railgun_page PRIVATE cxx_std_17)
  set_target_properties(railgun_page PROPERTIES
    OUTPUT_NAME "veylor-railgun-page"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
    INSTALL_RPATH ""
  )
  target_include_directories(railgun_page PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}" ${RAILGUN_WEBKIT_INCLUDE_DIRS})
  # The 4.1 API's script messages still arrive as WebKitJavascriptResult.
  target_compile_options(railgun_page PRIVATE
    ${RAILGUN_WEBKIT_CFLAGS_OTHER} -Wno-deprecated-declarations)
  target_link_libraries(railgun_page PRIVATE PkgConfig::GTK ${CMAKE_DL_LIBS})
else()
  message(WARNING "webkit2gtk-4.1 development headers not found: this build "
    "has no Railgun page process, so Shielded USD stays hidden.")
endif()
