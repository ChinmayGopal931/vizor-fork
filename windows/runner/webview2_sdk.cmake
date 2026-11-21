# The WebView2 SDK (Microsoft.Web.WebView2 from NuGet), pinned by version and
# SHA-256, for Shielded USD's Railgun page (docs/private-usd-windows.md). Only
# its headers and its static loader are used: the app links the loader in and
# ships no WebView2Loader.dll, and the page runs on the system's Evergreen
# WebView2 Runtime. Included by runner/CMakeLists.txt and by the page's check
# program (runner/tests/railgun_page).
set(VEYLOR_WEBVIEW2_SDK_VERSION "1.0.3485.44")
set(VEYLOR_WEBVIEW2_SDK_SHA256 "bc09150b179246ac90189649b13be8e6b11b3ac200e817e18df106e1f3cf489e")

# Sets OUT_INCLUDE to the SDK's include directory and OUT_LOADER to the static
# loader for ARCH (x64 or arm64), downloading the package once per build tree.
function(veylor_webview2_sdk OUT_INCLUDE OUT_LOADER ARCH)
  set(version "${VEYLOR_WEBVIEW2_SDK_VERSION}")
  set(root "${CMAKE_BINARY_DIR}/webview2_sdk_${version}")
  set(archive "${CMAKE_BINARY_DIR}/webview2_sdk_${version}.nupkg")
  if(NOT EXISTS "${root}/build/native/include/WebView2.h")
    file(DOWNLOAD
      "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/${version}/microsoft.web.webview2.${version}.nupkg"
      "${archive}"
      EXPECTED_HASH "SHA256=${VEYLOR_WEBVIEW2_SDK_SHA256}"
      TLS_VERIFY ON
    )
    file(MAKE_DIRECTORY "${root}")
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E tar xf "${archive}"
      WORKING_DIRECTORY "${root}"
      RESULT_VARIABLE extracted
    )
    if(NOT extracted EQUAL 0)
      message(FATAL_ERROR "Failed to extract the WebView2 SDK.")
    endif()
    file(REMOVE "${archive}")
  endif()
  set(loader "${root}/build/native/${ARCH}/WebView2LoaderStatic.lib")
  if(NOT EXISTS "${loader}")
    message(FATAL_ERROR "The WebView2 SDK has no static loader for ${ARCH}: ${loader}")
  endif()
  set(${OUT_INCLUDE} "${root}/build/native/include" PARENT_SCOPE)
  set(${OUT_LOADER} "${loader}" PARENT_SCOPE)
endfunction()
