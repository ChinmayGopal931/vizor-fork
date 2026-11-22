# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(Vizor LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "Vizor")

# The VIZOR_APPLICATION_ID environment variable selects Veylor's identity
# (docs/releases.md, "Desktop identity"); without it the build keeps upstream's. The
# identity sets the version resource's company and product names, which name
# the app-data directory, and the prefix of its secure storage and
# single-instance lock, so none of them is shared with an installed Vizor.
set(VIZOR_IDENTITY_STORAGE_PREFIX "Vizor")
set(VIZOR_IDENTITY_COMPANY_NAME "com.keplr")
set(VIZOR_IDENTITY_PRODUCT_NAME "Vizor")
set(VIZOR_IDENTITY_COPYRIGHT_HOLDER "com.keplr")
set(VIZOR_IDENTITY_VEYLOR_ICON 0)
set(VIZOR_APPLICATION_ID "$ENV{VIZOR_APPLICATION_ID}")
if(NOT VIZOR_APPLICATION_ID STREQUAL "")
  if(NOT VIZOR_APPLICATION_ID MATCHES "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$")
    message(FATAL_ERROR
      "VIZOR_APPLICATION_ID must be a package name such as com.veylor.desktop, "
      "not '${VIZOR_APPLICATION_ID}'.")
  elseif(VIZOR_APPLICATION_ID STREQUAL "com.veylor.desktop")
    set(VIZOR_IDENTITY_STORAGE_PREFIX "Veylor")
    set(VIZOR_IDENTITY_PRODUCT_NAME "Veylor")
  elseif(VIZOR_APPLICATION_ID STREQUAL "com.veylor.desktop.testnet")
    set(VIZOR_IDENTITY_STORAGE_PREFIX "VeylorTestnet")
    set(VIZOR_IDENTITY_PRODUCT_NAME "Veylor Testnet")
  else()
    message(FATAL_ERROR
      "No Windows identity is defined for VIZOR_APPLICATION_ID "
      "'${VIZOR_APPLICATION_ID}'. Use com.veylor.desktop or "
      "com.veylor.desktop.testnet.")
  endif()
  set(VIZOR_IDENTITY_COMPANY_NAME "com.veylor")
  set(VIZOR_IDENTITY_COPYRIGHT_HOLDER "Zapp LLC")
  set(VIZOR_IDENTITY_VEYLOR_ICON 1)
  # A value left in the environment by another build must not mix into this
  # identity: the data and secure storage would then be Vizor's.
  foreach(identity_field STORAGE_PREFIX COMPANY_NAME PRODUCT_NAME)
    set(identity_env "VIZOR_WINDOWS_${identity_field}")
    if(NOT "$ENV{${identity_env}}" STREQUAL "" AND
       NOT "$ENV{${identity_env}}" STREQUAL "${VIZOR_IDENTITY_${identity_field}}")
      message(FATAL_ERROR
        "${identity_env}='$ENV{${identity_env}}' conflicts with "
        "VIZOR_APPLICATION_ID=${VIZOR_APPLICATION_ID}. Unset ${identity_env}.")
    endif()
  endforeach()
endif()

if(DEFINED ENV{VIZOR_WINDOWS_STORAGE_PREFIX} AND NOT "$ENV{VIZOR_WINDOWS_STORAGE_PREFIX}" STREQUAL "")
  set(VIZOR_WINDOWS_STORAGE_PREFIX "$ENV{VIZOR_WINDOWS_STORAGE_PREFIX}")
else()
  set(VIZOR_WINDOWS_STORAGE_PREFIX "${VIZOR_IDENTITY_STORAGE_PREFIX}")
endif()
set(STORAGE_PREFIX "${VIZOR_WINDOWS_STORAGE_PREFIX}")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
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
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# Shielded USD's Railgun page bundle in data/railgun: the copy
# android/railgun-web/build.mjs writes for iOS, which the Mac and Linux serve
# too (no further copy). The host serves it as veylor-railgun://app/
# (docs/private-usd-windows.md).
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../ios/Runner/Railgun/railgun/"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/railgun" COMPONENT Runtime)
