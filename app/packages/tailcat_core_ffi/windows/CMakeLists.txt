# Bundles the prebuilt tailcat_core.dll (built by build/build_windows.sh and
# copied here by build/sync_libs.sh) next to the Flutter executable.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "tailcat_core_ffi")
project(${PROJECT_NAME} LANGUAGES CXX)

set(TAILCAT_CORE_DLL "${CMAKE_CURRENT_SOURCE_DIR}/lib/tailcat_core.dll")
if(NOT EXISTS "${TAILCAT_CORE_DLL}")
  message(FATAL_ERROR "tailcat_core.dll not found at ${TAILCAT_CORE_DLL}; run build/build_windows.sh && build/sync_libs.sh")
endif()

# List of absolute paths to libraries that should be bundled with the plugin.
set(tailcat_core_ffi_bundled_libraries
  "${TAILCAT_CORE_DLL}"
  PARENT_SCOPE
)
