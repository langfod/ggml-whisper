# Build ggml from upstream v0.24.0
#
# Source: https://github.com/ggml-org/ggml @ 456172ec733a135778adcd32d00e576a58232e45 (v0.24.0)

vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO ggml-org/ggml
    REF 456172ec733a135778adcd32d00e576a58232e45
    SHA512 3d870c6ad1e1d691553dbc32be08eee706dde2eaf9f39fb3b2ad59b3a7f61697508975cca3fb8701eb5ca5e3d595c89a464e4dd2b67718f8da000ac1f42b8aad
    HEAD_REF master
    PATCHES
        vulkan-shaders-gen.diff
        disable-glslc-spirv-opt.diff
)

vcpkg_check_features(OUT_FEATURE_OPTIONS FEATURE_OPTIONS
    FEATURES
        blas     GGML_BLAS
        cuda     GGML_CUDA
        metal    GGML_METAL
        opencl   GGML_OPENCL
        openmp   GGML_OPENMP
        vulkan   GGML_VULKAN
)

if("blas" IN_LIST FEATURES)
    vcpkg_find_acquire_program(PKGCONFIG)
    list(APPEND FEATURE_OPTIONS
        "-DCMAKE_REQUIRE_FIND_PACKAGE_BLAS=ON" # workaround message(ERROR ...)
        "-DPKG_CONFIG_EXECUTABLE=${PKGCONFIG}"
    )
endif()

if("cuda" IN_LIST FEATURES)
    vcpkg_find_cuda(OUT_CUDA_TOOLKIT_ROOT cuda_toolkit_root)
    list(APPEND FEATURE_OPTIONS
        "-DCMAKE_CUDA_COMPILER=${NVCC}"
        "-DCUDAToolkit_ROOT=${cuda_toolkit_root}"
        # CUDA < 13.0 nvcc rejects host compilers newer than VS2022 (MSVC 14.4x).
        # Allow building against e.g. v12.9 with a newer MSVC. See host_config.h C1189.
        "-DCMAKE_CUDA_FLAGS=-allow-unsupported-compiler"
    )
endif()

if("opencl" IN_LIST FEATURES)
    vcpkg_find_acquire_program(PYTHON3)
    list(APPEND FEATURE_OPTIONS
        "-DPython3_EXECUTABLE=${PYTHON3}"
    )
endif()

if(VCPKG_TARGET_IS_WINDOWS AND NOT VCPKG_TARGET_IS_MINGW AND VCPKG_TARGET_ARCHITECTURE STREQUAL "arm64")
    message(STATUS "The CPU backend is not supported for arm64 with MSVC.")
    list(APPEND FEATURE_OPTIONS
        "-DGGML_CPU=OFF"
    )
    if(FEATURES STREQUAL "core")
        message(WARNING "No backend enabled!")
    endif()
endif()

# Build the vulkan-shaders-gen host tool up-front in its own standalone build.
# The nested ExternalProject hits MSVC PDB collisions (C1041) inside vcpkg's
# build environment; a dedicated out-of-tree host build avoids that.
if("vulkan" IN_LIST FEATURES)
    vcpkg_find_acquire_program(PYTHON3)
    set(VULKAN_SHADERS_GEN_BUILD_DIR "${CURRENT_BUILDTREES_DIR}/${TARGET_TRIPLET}-shadergen")
    # Always start from a clean directory: this path is not versioned by source
    # hash, so a stale CMakeCache.txt from a previous REF will make CMake
    # refuse to reconfigure ("source ... does not match the source ... used to
    # generate cache").
    file(REMOVE_RECURSE "${VULKAN_SHADERS_GEN_BUILD_DIR}")
    file(MAKE_DIRECTORY "${VULKAN_SHADERS_GEN_BUILD_DIR}")
    # Replicate the fork's glslc feature tests so the tool is compiled with the
    # same shader-extension support as the outer build expects. glslc comes
    # from vcpkg's own "shaderc" host dependency, not necessarily the Vulkan
    # SDK, so look there first (a Vulkan-SDK-only search silently produced an
    # empty VULKAN_SHADER_GEN_CMAKE_ARGS, generating shaders without the
    # coopmat/coopmat2/int8 variants that ggml-vulkan.cpp expects).
    set(VULKAN_SHADER_GEN_CMAKE_ARGS "")
    find_program(VULKAN_GLSLC_EXECUTABLE NAMES glslc
        HINTS "${CURRENT_HOST_INSTALLED_DIR}/tools/shaderc"
              "$ENV{VULKAN_SDK}/Bin" "$ENV{VULKAN_SDK}/bin"
        PATHS "C:/VulkanSDK" ENV VK_SDK_PATH ENV VULKAN_SDK
        PATH_SUFFIXES Bin bin)
    if (VULKAN_GLSLC_EXECUTABLE)
        foreach (_pair "GL_KHR_cooperative_matrix|GGML_VULKAN_COOPMAT_GLSLC_SUPPORT"
                       "GL_NV_cooperative_matrix2|GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT"
                       "GL_NV_cooperative_matrix_decode_vector|GGML_VULKAN_COOPMAT2_DECODE_VECTOR_GLSLC_SUPPORT"
                       "GL_EXT_integer_dot_product|GGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT"
                       "GL_EXT_bfloat16|GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT"
                       "GL_EXT_float_e2m1|GGML_VULKAN_FLOAT_E2M1_GLSLC_SUPPORT"
                       "GL_EXT_float_e4m3|GGML_VULKAN_FLOAT_E4M3_GLSLC_SUPPORT")
            string(REPLACE "|" ";" _pair_list "${_pair}")
            list(GET _pair_list 0 _ext)
            list(GET _pair_list 1 _def)
            execute_process(
                COMMAND "${VULKAN_GLSLC_EXECUTABLE}" -o - -fshader-stage=compute --target-env=vulkan1.3
                        "${SOURCE_PATH}/src/ggml-vulkan/vulkan-shaders/feature-tests/${_ext}.comp"
                OUTPUT_VARIABLE _glslc_out
                ERROR_VARIABLE _glslc_err)
            if (NOT _glslc_err MATCHES "extension not supported: ${_ext}")
                list(APPEND VULKAN_SHADER_GEN_CMAKE_ARGS "-D${_def}=ON")
            endif()
        endforeach()
    endif()
    message(STATUS "Building vulkan-shaders-gen host tool in ${VULKAN_SHADERS_GEN_BUILD_DIR} with args: ${VULKAN_SHADER_GEN_CMAKE_ARGS}")
    execute_process(
        COMMAND "${CMAKE_COMMAND}"
                -S "${SOURCE_PATH}/src/ggml-vulkan/vulkan-shaders"
                -B "${VULKAN_SHADERS_GEN_BUILD_DIR}"
                -G Ninja
                -DCMAKE_BUILD_TYPE=Release
                ${VULKAN_SHADER_GEN_CMAKE_ARGS}
                "-DPython3_EXECUTABLE=${PYTHON3}"
        COMMAND_ERROR_IS_FATAL ANY
        OUTPUT_FILE "${CURRENT_BUILDTREES_DIR}/shadergen-config.log"
        ERROR_FILE "${CURRENT_BUILDTREES_DIR}/shadergen-config.log"
    )
    execute_process(
        COMMAND "${CMAKE_COMMAND}" --build "${VULKAN_SHADERS_GEN_BUILD_DIR}" --config Release
        COMMAND_ERROR_IS_FATAL ANY
        OUTPUT_FILE "${CURRENT_BUILDTREES_DIR}/shadergen-build.log"
        ERROR_FILE "${CURRENT_BUILDTREES_DIR}/shadergen-build.log"
    )
    find_file(
        VULKAN_SHADERS_GEN_EXE NAMES vulkan-shaders-gen.exe vulkan-shaders-gen
        PATHS "${VULKAN_SHADERS_GEN_BUILD_DIR}"
        NO_DEFAULT_PATH REQUIRED)
    list(APPEND FEATURE_OPTIONS
        "-DVULKAN_SHADERS_GEN_EXECUTABLE=${VULKAN_SHADERS_GEN_EXE}")
endif()
string(COMPARE EQUAL "${VCPKG_LIBRARY_LINKAGE}" "static"  GGML_STATIC)

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DGGML_STATIC=${GGML_STATIC}
        -DGGML_CCACHE=OFF
        -DGGML_BUILD_TESTS=OFF
        -DGGML_BUILD_EXAMPLES=OFF
        -DGGML_HIP=OFF
        -DGGML_SYCL=OFF
        -DGGML_CUDA_GRAPHS=ON
        -DGGML_LLAMAFILE=ON
        ${FEATURE_OPTIONS}
    MAYBE_UNUSED_VARIABLES
        PKG_CONFIG_EXECUTABLE
)

vcpkg_cmake_install()
vcpkg_copy_pdbs()
vcpkg_cmake_config_fixup(PACKAGE_NAME ggml CONFIG_PATH "lib/cmake/ggml")
vcpkg_fixup_pkgconfig()

if(VCPKG_LIBRARY_LINKAGE STREQUAL "dynamic")
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/include/ggml.h" "#ifdef GGML_SHARED" "#if 1")
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/include/ggml-backend.h" "#ifdef GGML_BACKEND_SHARED" "#if 1")
endif()

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/share")

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
# LOCAL_CUDA_TOOLKIT: v13.3
