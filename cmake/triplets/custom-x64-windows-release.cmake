###
# vcpkg triplet for x64 Windows release build
###

# Set architecture to x64
set(VCPKG_TARGET_ARCHITECTURE x64)

# Set MSVC runtime to static for release builds
set(VCPKG_CRT_LINKAGE static)

# Set library linkage to static for release builds
set(VCPKG_LIBRARY_LINKAGE static)

# Set vcpkg build type to release
set(VCPKG_BUILD_TYPE release)

# vcpkg ports that should be built as dynamic libraries
set(_dynamic_ports "ffmpeg" "ggml" "vulkan" "cuda" "whisper-cpp")
if(PORT IN_LIST _dynamic_ports)
    set(VCPKG_CRT_LINKAGE dynamic)
    set(VCPKG_LIBRARY_LINKAGE dynamic)
endif()
