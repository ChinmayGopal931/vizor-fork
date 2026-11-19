# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(APP_IDENTIFIER "vizor")
set(APP_DISPLAY_NAME "Vizor")
# Flutter tool reads BINARY_NAME without evaluating CMake variable expansion
# when launching `flutter run`, so keep the default executable name literal.
set(BINARY_NAME "vizor")
set(FLUTTER_RUN_BINARY_NAME "${BINARY_NAME}")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "app.keplr.${APP_IDENTIFIER}")

# The VIZOR_APPLICATION_ID environment variable selects Veylor's identity
# (AGENTS.md, "Desktop identity"); without it the build keeps upstream's. The
# identity renames the executable too: path_provider_linux names the support
# directory after the executable when it cannot load libgio-2.0.so, so a shared
# name would share the wallet data of an installed Vizor.
set(VIZOR_APPLICATION_ID "$ENV{VIZOR_APPLICATION_ID}")
if(NOT VIZOR_APPLICATION_ID STREQUAL "")
  if(NOT VIZOR_APPLICATION_ID MATCHES "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$")
    message(FATAL_ERROR
      "VIZOR_APPLICATION_ID must be a package name such as com.veylor.desktop, "
      "not '${VIZOR_APPLICATION_ID}'.")
  elseif(VIZOR_APPLICATION_ID STREQUAL "com.veylor.desktop")
    set(APP_IDENTIFIER "veylor")
    set(APP_DISPLAY_NAME "Veylor")
  elseif(VIZOR_APPLICATION_ID STREQUAL "com.veylor.desktop.testnet")
    set(APP_IDENTIFIER "veylor-testnet")
    set(APP_DISPLAY_NAME "Veylor Testnet")
  else()
    message(FATAL_ERROR
      "No Linux identity is defined for VIZOR_APPLICATION_ID "
      "'${VIZOR_APPLICATION_ID}'. Use com.veylor.desktop or "
      "com.veylor.desktop.testnet.")
  endif()
  set(BINARY_NAME "${APP_IDENTIFIER}")
  set(APPLICATION_ID "${VIZOR_APPLICATION_ID}")
endif()

# Build scripts can provide per-flavor Linux identity overrides here. Keep this
# generated file out of version control. It and VIZOR_APPLICATION_ID must not
# both pick an identity.
set(FLAVOR_OVERRIDES_FILE "${CMAKE_CURRENT_SOURCE_DIR}/FlavorOverrides.cmake")
if(NOT VIZOR_APPLICATION_ID STREQUAL "" AND EXISTS "${FLAVOR_OVERRIDES_FILE}")
  message(FATAL_ERROR
    "VIZOR_APPLICATION_ID and linux/FlavorOverrides.cmake both select an "
    "identity. Unset one of them.")
endif()
include("${FLAVOR_OVERRIDES_FILE}" OPTIONAL)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")
set(APP_DESKTOP_FILE "${PROJECT_BINARY_DIR}/${APPLICATION_ID}.desktop")

configure_file("${CMAKE_CURRENT_SOURCE_DIR}/vizor.desktop.in" "${APP_DESKTOP_FILE}" @ONLY)

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

# `flutter run` starts the literal BINARY_NAME above, so an executable renamed
# by VIZOR_APPLICATION_ID gets a link under that name. The process still sees
# its own executable name, which keeps its support directory apart.
if(NOT VIZOR_APPLICATION_ID STREQUAL "" AND
   NOT BINARY_NAME STREQUAL FLUTTER_RUN_BINARY_NAME)
  install(CODE "
    execute_process(COMMAND \"${CMAKE_COMMAND}\" -E create_symlink
      \"${BINARY_NAME}\" \"${CMAKE_INSTALL_PREFIX}/${FLUTTER_RUN_BINARY_NAME}\"
      RESULT_VARIABLE flutter_run_link_result)
    if(NOT flutter_run_link_result EQUAL 0)
      message(FATAL_ERROR \"Could not link ${FLUTTER_RUN_BINARY_NAME} to ${BINARY_NAME}\")
    endif()
    " COMPONENT Runtime)
endif()

install(FILES "${APP_DESKTOP_FILE}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/applications"
  COMPONENT Runtime)

foreach(icon_size 16 32 48 64 256)
  install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/icons/hicolor/${icon_size}x${icon_size}/apps/${APPLICATION_ID}.png"
    DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/icons/hicolor/${icon_size}x${icon_size}/apps"
    COMPONENT Runtime)
endforeach()

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Ship the USB permission setup with bundles/AppImages; installation on the host
# remains an explicit administrator action.
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/udev/"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/ledger-usb" COMPONENT Runtime)
