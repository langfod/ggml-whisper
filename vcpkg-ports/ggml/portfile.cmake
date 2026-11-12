vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO ggml-org/ggml
    REF v${VERSION}
    SHA512 4bf83e4f3f20b364003f74d16f97aed14bdc2af609d7b9980db90b415290eff6d90e5db85c72b1f3a4715647216fdac7fc41990593d8d02d48a5d0c7c0327c68
    HEAD_REF master
    PATCHES
        patches/cmake-config.diff
        patches/max-name.diff
        patches/pkgconfig.diff
        patches/relax-link-options.diff
        patches/vulkan-shaders-gen.diff
        patches/vulkan-queue-fetch.diff
        patches/fused_snake.diff
)
        # cpu: add fused snake activation (mul -> sin -> sqr -> mul -> add)
        # https://github.com/ggml-org/ggml/commit/210138933b22221ced02943b7b6e4308610ab530

vcpkg_replace_string("${SOURCE_PATH}/src/ggml-cpu/CMakeLists.txt"
    "target_compile_options(\${GGML_CPU_FEATS_NAME} PRIVATE -fno-lto)"
    "target_compile_options(\${GGML_CPU_FEATS_NAME} PRIVATE $<IF:$<CXX_COMPILER_ID:MSVC>,/GL-,-fno-lto>)"
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

if("vulkan" IN_LIST FEATURES AND VCPKG_CROSSCOMPILING)
    list(APPEND FEATURE_OPTIONS
        "-DVulkan_GLSLC_EXECUTABLE=${CURRENT_HOST_INSTALLED_DIR}/tools/shaderc/glslc${VCPKG_HOST_EXECUTABLE_SUFFIX}"
        "-DVULKAN_SHADERS_GEN_EXECUTABLE=${CURRENT_HOST_INSTALLED_DIR}/tools/${PORT}/vulkan-shaders-gen${VCPKG_HOST_EXECUTABLE_SUFFIX}"
    )
endif()

string(COMPARE EQUAL "${VCPKG_LIBRARY_LINKAGE}" "static"  GGML_STATIC)

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DGGML_STATIC=${GGML_STATIC}
        -DGGML_CCACHE=OFF
        -DGGML_BUILD_NUMBER=1
        -DGGML_BUILD_TESTS=OFF
        -DGGML_BUILD_EXAMPLES=OFF
        -DGGML_HIP=OFF
        -DGGML_SYCL=OFF
        -DGGML_NATIVE=OFF
        -DGGML_CUDA_GRAPHS=ON
        -DGGML_CPU_ALL_VARIANTS=ON
        -DGGML_BACKEND_DL=ON
        -DGGML_MAX_NAME=64
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

if("vulkan" IN_LIST FEATURES AND NOT VCPKG_CROSSCOMPILING)
    vcpkg_copy_tools(TOOL_NAMES vulkan-shaders-gen AUTO_CLEAN)
endif()

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/share")

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
# LOCAL_CUDA_TOOLKIT: v13.5
