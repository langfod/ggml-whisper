param(
    [string]$preset = "release",
    [int]$threads,
    [switch]$noLTO = $false,
    [switch]$fresh
)
$ErrorActionPreference = "Stop"

$defaultThreads = 16

function Import-VsDevCmdEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VsDevCmdPath
    )

    if (-not (Test-Path $VsDevCmdPath)) {
        Write-Warning "VsDevCmd fallback not found at '$VsDevCmdPath'"
        return $false
    }

    Write-Host "Falling back to VsDevCmd environment import: $VsDevCmdPath" -ForegroundColor Yellow

    $cmdLine = 'call "' + $VsDevCmdPath + '" -arch=amd64 -host_arch=amd64 >nul && set'
    $envDump = cmd /c $cmdLine

    if ($LASTEXITCODE -ne 0 -or -not $envDump) {
        Write-Warning "VsDevCmd fallback failed to produce an environment"
        return $false
    }

    $seenPath = $false
    foreach ($line in $envDump) {
        $idx = $line.IndexOf('=')
        if ($idx -le 0) {
            continue
        }

        $name = $line.Substring(0, $idx)
        $value = $line.Substring($idx + 1)

        if ($name -ieq 'PATH') {
            if (-not $seenPath) {
                $env:Path = $value
                [System.Environment]::SetEnvironmentVariable('Path', $value, 'Process')
                $seenPath = $true
            }
            continue
        }

        if ($name -ieq 'Path') {
            continue
        }

        [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }

    return $true
}

# Load in template default variables
. .\Build_Config_Template.ps1

# Load in local variable overides
if (Test-Path .\Build_Config_Local.ps1) {
    . .\Build_Config_Local.ps1
}

# --- CUDA toolkit reset -----------------------------------------------------
# vcpkg's ABI hash does NOT include the CUDA toolkit version: `vcpkg_find_cuda`
# resolves the toolkit from $env:CUDA_PATH at build time, but that value is never
# folded into the package ABI. So flipping CUDA_PATH between toolkits (v13.3 <->
# v12.9) silently reuses ggml/whisper-cpp binaries built against the OTHER toolkit.
#
# This VS-bundled vcpkg has no `vcpkg_abi_path_check`, so we use the one ABI input
# we control: the portfile.cmake hash. Stamping the active toolkit into the ggml
# portfile changes ggml's ABI -> vcpkg rebuilds ggml against $env:CUDA_PATH, and
# ggml's new hash changes whisper-cpp's ABI -> whisper-cpp rebuilds too. Only those
# two packages rebuild; the vulkan stack stays cached. Same toolkit => same marker =>
# the cached build is reused.
if ($env:CUDA_PATH) {
    $cudaToolkit = Split-Path $env:CUDA_PATH -Leaf
    $ggmlPortfile = Join-Path $PSScriptRoot "vcpkg-ports\ggml\portfile.cmake"
    $marker = "# LOCAL_CUDA_TOOLKIT: $cudaToolkit"
    if (Test-Path $ggmlPortfile) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $lines = [System.IO.File]::ReadAllLines($ggmlPortfile)
        $existingIndex = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^# LOCAL_CUDA_TOOLKIT:') { $existingIndex = $i; break }
        }
        if ($existingIndex -ge 0 -and $lines[$existingIndex] -eq $marker) {
            Write-Host "CUDA toolkit $cudaToolkit unchanged - reusing cached ggml/whisper-cpp"
        } else {
            if ($existingIndex -ge 0) {
                $lines[$existingIndex] = $marker
            } else {
                $lines += $marker
            }
            [System.IO.File]::WriteAllLines($ggmlPortfile, $lines, $utf8NoBom)
            if ($existingIndex -ge 0) {
                Write-Host "CUDA toolkit changed to $cudaToolkit - ggml/whisper-cpp will rebuild against it"
            } else {
                Write-Host "CUDA toolkit $cudaToolkit recorded - ggml/whisper-cpp will rebuild against it"
            }
        }
    }
}
# -----------------------------------------------------------------------------

if (-not $threads) {
    if ($env:LOCAL_BUILD_THREADS) {
        $threads = [int]$env:LOCAL_BUILD_THREADS
        Write-Host "Using thread count from environment: $threads"
    } elseif ($localDefaultThreads) {
        $threads = $localDefaultThreads
        Write-Host "Using thread count from local config: $threads"
    } else {
        $threads = $defaultThreads
        Write-Host "Using default thread count: $threads"
    }   
}



Write-Host "Running preset $preset"

# Set up Visual Studio 2022 x64 environment
# Override with env var if set
if ($env:VS_DEV_SHELL_PATH) {
    if (Test-Path $env:VS_DEV_SHELL_PATH) {
        $vsDevShellPath = $env:VS_DEV_SHELL_PATH
        Write-Host "Using VS Dev Shell path from environment: $vsDevShellPath"
    }
}
# Verify the path exists
if (-not (Test-Path $vsDevShellPath)) {
    Write-Error "Visual Studio Dev Shell script not found at '$vsDevShellPath'. Please check the path."
    exit 1
}
# The VS dev shell - and the VsDevCmd fallback below - overwrite VCPKG_ROOT with
# Visual Studio's bundled vcpkg, which is usually older than the vcpkg this project's
# pinned registry baseline needs. CMakePresets.json expands $env{VCPKG_ROOT} into
# toolchainFile, so allowing that through silently swaps the toolchain, invalidates
# every cached package ABI, and forces a full from-source rebuild of all dependencies.
$savedVcpkgRoot = $env:VCPKG_ROOT

# Save current directory, launch VS dev shell, and return to original directory
$currentDirectory = $PWD.Path
& $vsDevShellPath -Arch amd64; Set-Location -Path "${currentDirectory}"

$requiredCommands = @("cl", "cmake", "git")
$missingCommands = @($requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missingCommands.Count -gt 0) {
    Write-Host "Developer PowerShell bootstrap did not expose required commands: $($missingCommands -join ', ')" -ForegroundColor Yellow
    $vsDevCmdPath = Join-Path (Split-Path $vsDevShellPath -Parent) "VsDevCmd.bat"
    if (-not (Import-VsDevCmdEnvironment -VsDevCmdPath $vsDevCmdPath)) {
        Write-Error "Failed to import Visual Studio build environment. Missing commands: $($missingCommands -join ', ')"
        exit 1
    }

    $missingCommands = @($requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missingCommands.Count -gt 0) {
        Write-Error "Visual Studio build environment still missing required commands after fallback: $($missingCommands -join ', ')"
        exit 1
    }
}

# Restore VCPKG_ROOT if the Visual Studio environment setup replaced it (see note above).
if ($savedVcpkgRoot -and $env:VCPKG_ROOT -ne $savedVcpkgRoot) {
    Write-Host "Restoring VCPKG_ROOT to '$savedVcpkgRoot' (VS environment set it to '$env:VCPKG_ROOT')" -ForegroundColor Yellow
    $env:VCPKG_ROOT = $savedVcpkgRoot
}

$clCommand = Get-Command cl -ErrorAction SilentlyContinue
$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
$gitCommand = Get-Command git -ErrorAction SilentlyContinue
$ninjaCommand = Get-Command ninja -ErrorAction SilentlyContinue
$ninjaPath = $null

if (-not $clCommand -or -not $cmakeCommand) {
    Write-Error "Build environment is not ready. cl.exe or cmake.exe is still unavailable."
    exit 1
}

if ($gitCommand) {
    $env:GIT = $gitCommand.Source
}

if (-not $ninjaCommand) {
    $cmakeBinDir = Split-Path $cmakeCommand.Source -Parent
    $cmakePackageDir = Split-Path $cmakeBinDir -Parent
    $cmakeExtensionDir = Split-Path $cmakePackageDir -Parent
    $vsNinjaPath = Join-Path $cmakeExtensionDir "Ninja\ninja.exe"
    if (Test-Path $vsNinjaPath) {
        $ninjaPath = $vsNinjaPath
    }
} elseif ($ninjaCommand.Source) {
    $ninjaPath = $ninjaCommand.Source
} elseif ($ninjaCommand.Path) {
    $ninjaPath = $ninjaCommand.Path
}



# Build cmake configure arguments
$cmakeArgs = @("-S", ".", "--preset=$preset", "-DCMAKE_COMPILE_JOBS=$threads", "-Wno-dev")
$cmakeArgs += "-DCMAKE_C_COMPILER=$($clCommand.Source)"
$cmakeArgs += "-DCMAKE_CXX_COMPILER=$($clCommand.Source)"
if ($ninjaPath) {
    $cmakeArgs += "-DCMAKE_MAKE_PROGRAM:FILEPATH=$ninjaPath"
}


if ($noLTO) {
    $cmakeArgs += "-DENABLE_LTO=OFF"
    Write-Host "LTO disabled (-noLTO flag) for faster link times"
}

$global:buildStartTime = Get-Date

& cmake $cmakeArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "cmake configure failed with exit code $LASTEXITCODE." -ForegroundColor Red
    exit $LASTEXITCODE
}


& cmake --build --preset=$preset --parallel $threads
if ($LASTEXITCODE -ne 0) {
    Write-Host "cmake build failed with exit code $LASTEXITCODE." -ForegroundColor Red
    exit $LASTEXITCODE
}

$build_time = (Get-Date) - $global:buildStartTime


Write-Host "`nBuild time: $($build_time.TotalSeconds) seconds.`n" -ForegroundColor Green
