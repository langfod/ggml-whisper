# FindGGML.cmake
# Finds and configures GGML dynamic libraries for runtime loading
#
# Sets the following variables:
#   GGML_FOUND - TRUE if GGML was found
#   GGML_INCLUDE_DIRS - Include directories for GGML headers
#   GGML_DLL_DIR - Directory containing GGML DLLs (for deployment)
#   GGML_LIB_DIR - Directory containing GGML import libraries
#

set(GGML_VCPKG_INSTALLED_DIR "${CMAKE_SOURCE_DIR}/build/vcpkg_installed")


set(GGML_VCPKG_TRIPLET "$ENV{VCPKG_TARGET_TRIPLET}")
if(NOT GGML_VCPKG_TRIPLET)
    set(GGML_VCPKG_TRIPLET "custom-x64-windows-release")
endif()


set(GGML_DYNAMIC_ROOT "${GGML_VCPKG_INSTALLED_DIR}/${GGML_VCPKG_TRIPLET}")


set(GGML_INCLUDE_DIR "${GGML_DYNAMIC_ROOT}/include")
set(GGML_DLL_DIR "${GGML_DYNAMIC_ROOT}/bin")
set(GGML_LIB_DIR "${GGML_DYNAMIC_ROOT}/lib")

# Verify required DLLs exist
set(GGML_REQUIRED_DLLS
    "ggml.dll"
    "ggml-base.dll"
)

foreach(dll ${GGML_REQUIRED_DLLS})
    if(NOT EXISTS "${GGML_DLL_DIR}/${dll}")
        message(FATAL_ERROR "Required GGML DLL not found: ${GGML_DLL_DIR}/${dll}. Run DownloadExternalDeps.ps1 or check external_versions.json for download details.")
    endif()
endforeach()

message(STATUS "Found GGML dynamic libraries at: ${GGML_DYNAMIC_ROOT}")

# Backend DLLs live in lib/ in the legacy external layout but in bin/ in the
# vcpkg layout, so search both when checking for optional backends.
function(ggml_find_backend_dll out_var dll_name)
    if(EXISTS "${GGML_LIB_DIR}/${dll_name}")
        set(${out_var} "${GGML_LIB_DIR}/${dll_name}" PARENT_SCOPE)
    elseif(EXISTS "${GGML_DLL_DIR}/${dll_name}")
        set(${out_var} "${GGML_DLL_DIR}/${dll_name}" PARENT_SCOPE)
    else()
        set(${out_var} "" PARENT_SCOPE)
    endif()
endfunction()

# Check for optional GPU backend DLLs
ggml_find_backend_dll(GGML_CUDA_DLL "ggml-cuda.dll")
if(GGML_CUDA_DLL)
    message(STATUS "  - CUDA backend available (ggml-cuda.dll)")
    set(GGML_CUDA_AVAILABLE TRUE)
else()
    message(STATUS "  - CUDA backend not available")
    set(GGML_CUDA_AVAILABLE FALSE)
endif()

ggml_find_backend_dll(GGML_VULKAN_DLL "ggml-vulkan.dll")
if(GGML_VULKAN_DLL)
    message(STATUS "  - Vulkan backend available (ggml-vulkan.dll)")
    set(GGML_VULKAN_AVAILABLE TRUE)
else()
    message(STATUS "  - Vulkan backend not available")
    set(GGML_VULKAN_AVAILABLE FALSE)
endif()

if (GGML_VULKAN_AVAILABLE)
    ggml_find_backend_dll(GGML_VULKAN_RUNTIME_DLL "vulkan-1.dll")
    if(GGML_VULKAN_RUNTIME_DLL)
        message(STATUS "  - Vulkan runtime available (vulkan-1.dll)")
    else()
        message(STATUS "  - Vulkan runtime not available")
        set(GGML_VULKAN_AVAILABLE FALSE)
    endif()
endif()

ggml_find_backend_dll(GGML_OPENCL_DLL "ggml-opencl.dll")
if(GGML_OPENCL_DLL)
    message(STATUS "  - OpenCL backend available (ggml-opencl.dll)")
    set(GGML_OPENCL_AVAILABLE TRUE)
else()
    message(STATUS "  - OpenCL backend not available")
    set(GGML_OPENCL_AVAILABLE FALSE)
endif()

ggml_find_backend_dll(GGML_CPU_DLL "ggml-cpu.dll")
if(GGML_CPU_DLL)
    message(STATUS "  - CPU backend available (ggml-cpu.dll)")
    set(GGML_CPU_AVAILABLE TRUE)
else()
    message(STATUS "  - CPU backend not available")
    set(GGML_CPU_AVAILABLE FALSE)
endif()

# Find import libraries for linking (optional, used for header definitions)
find_library(GGML_IMPORT_LIB ggml PATHS "${GGML_LIB_DIR}" NO_DEFAULT_PATH)
if(GGML_IMPORT_LIB)
    message(STATUS "  - Import library found: ${GGML_IMPORT_LIB}")
endif()

# Create an interface library for include paths only
# We don't link against ggml - we load it dynamically at runtime
add_library(ggml_headers INTERFACE)
target_include_directories(ggml_headers INTERFACE "${GGML_INCLUDE_DIR}")

# Define GGML_SHARED so the headers use dllimport declarations
target_compile_definitions(ggml_headers INTERFACE GGML_SHARED)

# Set output variables
set(GGML_INCLUDE_DIRS "${GGML_INCLUDE_DIR}")
set(GGML_FOUND TRUE)

# Create a list of all DLLs to deploy
set(GGML_DEPLOY_DLLS
    "${GGML_DLL_DIR}/ggml.dll"
    "${GGML_DLL_DIR}/ggml-base.dll"
)
if(GGML_CPU_AVAILABLE)
    list(APPEND GGML_DEPLOY_DLLS "${GGML_CPU_DLL}")
endif()

if(GGML_CUDA_AVAILABLE)
    list(APPEND GGML_DEPLOY_DLLS "${GGML_CUDA_DLL}")
endif()

if(GGML_VULKAN_AVAILABLE)
    list(APPEND GGML_DEPLOY_DLLS "${GGML_VULKAN_DLL}")
endif()

if(GGML_OPENCL_AVAILABLE)
    list(APPEND GGML_DEPLOY_DLLS "${GGML_OPENCL_DLL}")
endif()

# Function to copy GGML DLLs to target directory
function(ggml_copy_dlls target_dir)
    foreach(dll ${GGML_DEPLOY_DLLS})
        get_filename_component(dll_name "${dll}" NAME)
        configure_file("${dll}" "${target_dir}/${dll_name}" COPYONLY)
        message(STATUS "Copying ${dll_name} to ${target_dir}")
    endforeach()
endfunction()
