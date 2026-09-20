# It's recommended to set a minimum CMake version.
# If you use CMake features from higher versions, update this to match.
cmake_minimum_required(VERSION 3.21)
add_definitions(-D_WIN32_WINNT=0x0A00)

if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
endif()

# Limit build parallelism (configurable via -DCMAKE_COMPILE_JOBS and -DCMAKE_LINK_JOBS)
if(NOT DEFINED CMAKE_COMPILE_JOBS)
    set(CMAKE_COMPILE_JOBS 8)
endif()

if(NOT DEFINED CMAKE_LINK_JOBS)
    set(CMAKE_LINK_JOBS 2)
endif()

set_property(GLOBAL PROPERTY JOB_POOLS "compile=${CMAKE_COMPILE_JOBS}" "link=${CMAKE_LINK_JOBS}")
set(CMAKE_JOB_POOL_COMPILE compile)
set(CMAKE_JOB_POOL_LINK link)
set(CMAKE_INSTALL_MESSAGE LAZY)
#set(CMAKE_INSTALL_RPATH_USE_LINK_PATH ON)
#set(CMAKE_LINK_DEPENDS_NO_SHARED TRUE)

# Set your project name. This will be the name of your SKSE .dll file.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" raw_version)
string(STRIP "${raw_version}" APP_VERSION)
project(GGML_WHISPER VERSION ${APP_VERSION} LANGUAGES CXX)


list(APPEND CMAKE_MODULE_PATH "${PROJECT_SOURCE_DIR}/cmake")

# Define BUILD_ROOT for external dependency builds shared across all presets
# Use the top-level build directory to ensure external deps are built once and reused
set(BUILD_ROOT "${CMAKE_SOURCE_DIR}/build")


# Configure compiler flags (must come before ccache to set flags correctly)
include(CompilerFlags)


enable_language(C)
find_package(ggml CONFIG REQUIRED)

include(FindGGML)
include(FindWhisper)


# Add include directories from found libraries
include_directories(${WHISPER_INCLUDE_DIRS})
include_directories(${GGML_INCLUDE_DIRS})

# Add include directories
# add_subdirectory(external/vosk-api vosk_build)
include_directories(${CMAKE_SOURCE_DIR}/include)
include_directories(${CMAKE_BINARY_DIR}/include)
include_directories(${CMAKE_SOURCE_DIR}/src)


# ---------------------------------------------------------------------------
# Dist staging: copy runtime DLLs, headers, and import libraries into
# versioned dist folders under the build folder (see local_projects\dist_archives):
#   build\whisper-windows-x64-<version>\{bin,include,lib}
#   build\ggml-windows-x64-<version>-cuda<version>\{bin,include,lib}
#   build\cudart-windows-x64-v<version>\bin
# ---------------------------------------------------------------------------

function(dist_copy src dst)
    foreach(_f IN LISTS src)
        file(COPY "${_f}" DESTINATION "${dst}")
    endforeach()
endfunction()

set(DIST_ROOT "${BUILD_ROOT}/dist")

# Whisper version from the vcpkg port manifest
file(READ "${CMAKE_SOURCE_DIR}/vcpkg-ports/whisper-cpp/vcpkg.json" _whisper_manifest)
string(JSON WHISPER_DIST_VERSION GET "${_whisper_manifest}" version)
set(WHISPER_DIST_DIR "${DIST_ROOT}/whisper-windows-x64-${WHISPER_DIST_VERSION}")

# GGML version from the vcpkg port manifest
file(READ "${CMAKE_SOURCE_DIR}/vcpkg-ports/ggml/vcpkg.json" _ggml_manifest)
string(JSON GGML_DIST_VERSION GET "${_ggml_manifest}" version)

# CUDA version from the tail of $env:CUDA_PATH (e.g. ...\CUDA\v13.3 -> 13.3)
if(GGML_CUDA_AVAILABLE)
    set(_cuda_version "")
    if(DEFINED ENV{CUDA_PATH})
        file(TO_CMAKE_PATH "$ENV{CUDA_PATH}" _cuda_path)
        get_filename_component(_cuda_version "${_cuda_path}" NAME)
        string(REGEX REPLACE "^v" "" _cuda_version "${_cuda_version}")
    endif()
    if(NOT _cuda_version AND DEFINED CMAKE_CUDA_VERSION)
        set(_cuda_version "${CMAKE_CUDA_VERSION}")
    endif()
    if(_cuda_version)
        set(GGML_DIST_DIR "${DIST_ROOT}/ggml-windows-x64-${GGML_DIST_VERSION}-cuda${_cuda_version}")
        set(CUDART_DIST_DIR "${DIST_ROOT}/cudart-windows-x64-v${_cuda_version}")
    else()
        set(GGML_DIST_DIR "${DIST_ROOT}/ggml-windows-x64-${GGML_DIST_VERSION}")
    endif()
else()
    set(GGML_DIST_DIR "${DIST_ROOT}/ggml-windows-x64-${GGML_DIST_VERSION}")
endif()

# --- Whisper: DLLs (bin), headers (include), import libraries (lib) ---
foreach(_subdir bin include lib)
    file(MAKE_DIRECTORY "${WHISPER_DIST_DIR}/${_subdir}")
endforeach()
foreach(_dll ${WHISPER_DEPLOY_DLLS})
    dist_copy("${_dll}" "${WHISPER_DIST_DIR}/bin")
endforeach()
set(_whisper_headers "${WHISPER_INCLUDE_DIR}/whisper.h")
if(EXISTS "${WHISPER_INCLUDE_DIR}/parakeet.h")
    list(APPEND _whisper_headers "${WHISPER_INCLUDE_DIR}/parakeet.h")
endif()
dist_copy("${_whisper_headers}" "${WHISPER_DIST_DIR}/include")
foreach(_lib whisper.lib parakeet.lib)
    if(EXISTS "${WHISPER_LIB_DIR}/${_lib}")
        dist_copy("${WHISPER_LIB_DIR}/${_lib}" "${WHISPER_DIST_DIR}/lib")
    endif()
endforeach()

# --- GGML: DLLs (bin), headers (include), import libraries (lib) ---
foreach(_subdir bin include lib)
    file(MAKE_DIRECTORY "${GGML_DIST_DIR}/${_subdir}")
endforeach()
foreach(_dll ${GGML_DEPLOY_DLLS})
    dist_copy("${_dll}" "${GGML_DIST_DIR}/bin")
endforeach()
# Vulkan runtime is required by ggml-vulkan.dll but not part of GGML_DEPLOY_DLLS
if(GGML_VULKAN_AVAILABLE AND GGML_VULKAN_RUNTIME_DLL)
    dist_copy("${GGML_VULKAN_RUNTIME_DLL}" "${GGML_DIST_DIR}/bin")
endif()
dist_copy("${GGML_INCLUDE_DIR}/ggml.h" "${GGML_DIST_DIR}/include")
file(GLOB _ggml_libs "${GGML_LIB_DIR}/ggml*.lib")
dist_copy("${_ggml_libs}" "${GGML_DIST_DIR}/lib")

# --- CUDA runtime DLLs (bin) when the CUDA backend is enabled ---
if(GGML_CUDA_AVAILABLE AND DEFINED ENV{CUDA_PATH} AND _cuda_version)
    file(TO_CMAKE_PATH "$ENV{CUDA_PATH}" _cuda_path)
    file(MAKE_DIRECTORY "${CUDART_DIST_DIR}/bin")
    foreach(_pattern cudart64_*.dll cufft64_*.dll cublas64_*.dll cublasLt64_*.dll)
        file(GLOB _cuda_dlls "${_cuda_path}/bin/x64/${_pattern}")
        if(_cuda_dlls)
            dist_copy("${_cuda_dlls}" "${CUDART_DIST_DIR}/bin")
        endif()
    endforeach()
endif()

message(STATUS "Dist staging complete under: ${DIST_ROOT}")
