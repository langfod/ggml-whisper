# Use as a template
# Copy to "Build_Config_Local.ps1"

# Set up Visual Studio 2022 x64 environment
$vsDevShellPath =  "W:/Program Files/Microsoft Visual Studio/2022/Community/Common7/Tools/Launch-VsDevShell.ps1"

# Default thread count for cmake builds if not set by env var or command line argument
$localDefaultThreads = 16

# https://developer.nvidia.com/cuda-toolkit-archive
$env:CUDA_PATH="C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.3"

# https://vulkan.lunarg.com/sdk/home
$env:VULKAN_SDK="C:\VulkanSDK\1.4.357.0"