# FindWhisper.cmake
# Finds and configures Whisper.cpp dynamic libraries for runtime loading
#
# Sets the following variables:
#   WHISPER_FOUND - TRUE if Whisper.cpp was found
#   WHISPER_INCLUDE_DIRS - Include directories for Whisper.cpp headers
#   WHISPER_DLL_DIR - Directory containing Whisper DLLs (for deployment)
#   WHISPER_LIB_DIR - Directory containing Whisper import libraries
#

set(WHISPER_VCPKG_INSTALLED_DIR "${CMAKE_SOURCE_DIR}/build/vcpkg_installed")


set(WHISPER_VCPKG_TRIPLET "$ENV{VCPKG_TARGET_TRIPLET}")
if(NOT WHISPER_VCPKG_TRIPLET)
    set(WHISPER_VCPKG_TRIPLET "custom-x64-windows-release")
endif()


set(WHISPER_DYNAMIC_ROOT "${WHISPER_VCPKG_INSTALLED_DIR}/${WHISPER_VCPKG_TRIPLET}")


set(WHISPER_INCLUDE_DIR "${WHISPER_DYNAMIC_ROOT}/include")
set(WHISPER_DLL_DIR "${WHISPER_DYNAMIC_ROOT}/bin")
set(WHISPER_LIB_DIR "${WHISPER_DYNAMIC_ROOT}/lib")

# Verify required DLLs exist
set(WHISPER_REQUIRED_DLLS
    "whisper.dll"
)

foreach(dll ${WHISPER_REQUIRED_DLLS})
    if(NOT EXISTS "${WHISPER_DLL_DIR}/${dll}")
        message(FATAL_ERROR "Required Whisper DLL not found: ${WHISPER_DLL_DIR}/${dll}. Run DownloadExternalDeps.ps1 or check external_versions.json for download details.")
    endif()
endforeach()

message(STATUS "Found Whisper.cpp dynamic libraries at: ${WHISPER_DYNAMIC_ROOT}")

# Backend DLLs live in lib/ in the legacy external layout but in bin/ in the
# vcpkg layout, so search both when checking for optional backends.
function(whisper_find_backend_dll out_var dll_name)
    if(EXISTS "${WHISPER_LIB_DIR}/${dll_name}")
        set(${out_var} "${WHISPER_LIB_DIR}/${dll_name}" PARENT_SCOPE)
    elseif(EXISTS "${WHISPER_DLL_DIR}/${dll_name}")
        set(${out_var} "${WHISPER_DLL_DIR}/${dll_name}" PARENT_SCOPE)
    else()
        set(${out_var} "" PARENT_SCOPE)
    endif()
endfunction()

# Check for optional backend DLLs

whisper_find_backend_dll(WHISPER_PARAKEET_DLL "parakeet.dll")
if(WHISPER_PARAKEET_DLL)
    message(STATUS "  - Parakeet backend available (parakeet.dll)")
    set(WHISPER_PARAKEET_AVAILABLE TRUE)
else()
    message(STATUS "  - Parakeet backend not available")
    set(WHISPER_PARAKEET_AVAILABLE FALSE)
endif()

# Find import libraries for linking (optional, used for header definitions)
find_library(WHISPER_IMPORT_LIB whisper PATHS "${WHISPER_LIB_DIR}" NO_DEFAULT_PATH)
if(WHISPER_IMPORT_LIB)
    message(STATUS "  - Import library found: ${WHISPER_IMPORT_LIB}")
endif()

# Create an interface library for include paths only
# We don't link against whisper - we load it dynamically at runtime
add_library(whisper_headers INTERFACE)
target_include_directories(whisper_headers INTERFACE "${WHISPER_INCLUDE_DIR}")

# Define WHISPER_SHARED so the headers use dllimport declarations
target_compile_definitions(whisper_headers INTERFACE WHISPER_SHARED)

# Set output variables
set(WHISPER_INCLUDE_DIRS "${WHISPER_INCLUDE_DIR}")
set(WHISPER_FOUND TRUE)

# Create a list of all DLLs to deploy
set(WHISPER_DEPLOY_DLLS
    "${WHISPER_DLL_DIR}/whisper.dll"
)

if(WHISPER_PARAKEET_AVAILABLE)
    list(APPEND WHISPER_DEPLOY_DLLS "${WHISPER_PARAKEET_DLL}")
endif()

# Function to copy Whisper DLLs to target directory
function(whisper_copy_dlls target_dir)
    foreach(dll ${WHISPER_DEPLOY_DLLS})
        get_filename_component(dll_name "${dll}" NAME)
        configure_file("${dll}" "${target_dir}/${dll_name}" COPYONLY)
        message(STATUS "Copying ${dll_name} to ${target_dir}")
    endforeach()
endfunction()
