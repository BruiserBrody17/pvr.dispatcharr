<#
.SYNOPSIS
    Build, package, and optionally install the pvr.dispatcharr Kodi addon on Windows.

.DESCRIPTION
    PowerShell equivalent of build.sh. Configures, builds, installs, versions,
    packages (ZIP), and optionally copies the addon into Kodi's addons folder.

.PARAMETER KodiAddonSdk
    Required. Path to kodi-addon-dev-kit containing include\kodi\addon-instance\PVR.h.

.PARAMETER KodiAddonsDir
    Kodi addons folder. Default: $env:APPDATA\Kodi\addons

.PARAMETER InstallToKodi
    Switch: copy the built addon into the Kodi addons folder after building.

.PARAMETER SkipZip
    Switch: skip the ZIP packaging step.

.PARAMETER Version
    Optional version string to stamp into addon.xml (leading 'v' is stripped).

.PARAMETER CmakeExtraArgs
    Optional string of extra cmake -D flags (e.g. "-DFOO=bar -DBAZ=qux").

.PARAMETER CmakeToolchainFile
    Optional path to a vcpkg or other CMake toolchain file.

.PARAMETER CmakeGenerator
    CMake generator to use. Default: "Visual Studio 17 2022"

.PARAMETER CmakeGeneratorPlatform
    CMake generator platform. Default: "x64"

.PARAMETER Help
    Print usage information and exit.

.EXAMPLE
    # Minimal
    .\build.ps1 -KodiAddonSdk C:\kodi-src\xbmc\addons\kodi-dev-kit

.EXAMPLE
    # With vcpkg toolchain
    .\build.ps1 -KodiAddonSdk C:\kodi-src\xbmc\addons\kodi-dev-kit `
                -CmakeToolchainFile C:\vcpkg\scripts\buildsystems\vcpkg.cmake

.EXAMPLE
    # Build, package, and install into Kodi
    .\build.ps1 -KodiAddonSdk C:\kodi-src\xbmc\addons\kodi-dev-kit `
                -CmakeToolchainFile C:\vcpkg\scripts\buildsystems\vcpkg.cmake `
                -InstallToKodi

.EXAMPLE
    # Custom Kodi addons folder
    .\build.ps1 -KodiAddonSdk C:\kodi-src\xbmc\addons\kodi-dev-kit `
                -KodiAddonsDir "C:\Users\Me\AppData\Roaming\Kodi\addons" `
                -InstallToKodi
#>
[CmdletBinding()]
param(
    [string]  $KodiAddonSdk,
    [string]  $KodiAddonsDir         = "$env:APPDATA\Kodi\addons",
    [switch]  $InstallToKodi,
    [switch]  $SkipZip,
    [string]  $Version,
    [string]  $CmakeExtraArgs,
    [string]  $CmakeToolchainFile,
    [string]  $CmakeGenerator        = 'Visual Studio 17 2022',
    [string]  $CmakeGeneratorPlatform = 'x64',
    [Alias('h')]
    [switch]  $Help
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit 0
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$RootDir  = $PSScriptRoot
$BuildDir = Join-Path $RootDir 'build'
$DistDir  = Join-Path $RootDir 'dist'

# ---------------------------------------------------------------------------
# Validate KodiAddonSdk
# ---------------------------------------------------------------------------
if ([string]::IsNullOrEmpty($KodiAddonSdk)) {
    Write-Error "ERROR: -KodiAddonSdk is required.`nUsage: .\build.ps1 -KodiAddonSdk <path-to-kodi-addon-dev-kit>`nRun '.\build.ps1 -Help' for full usage."
    exit 1
}

$PvrHeader = Join-Path $KodiAddonSdk 'include\kodi\addon-instance\PVR.h'
if (-not (Test-Path $PvrHeader)) {
    Write-Error "ERROR: -KodiAddonSdk does not look like kodi-addon-dev-kit (missing include\kodi\addon-instance\PVR.h).`nKodiAddonSdk=$KodiAddonSdk"
    exit 1
}

# ---------------------------------------------------------------------------
# Prepare build and dist directories
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
New-Item -ItemType Directory -Force -Path $DistDir  | Out-Null

# ---------------------------------------------------------------------------
# Helper: run cmake and throw on non-zero exit
# ---------------------------------------------------------------------------
function Invoke-Cmake {
    param([string[]]$Arguments)
    & cmake @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "cmake exited with code $LASTEXITCODE. Arguments: $Arguments"
    }
}

# ---------------------------------------------------------------------------
# Configure
# ---------------------------------------------------------------------------
$ConfigArgs = @(
    '-S', $RootDir,
    '-B', $BuildDir,
    '-G', $CmakeGenerator,
    '-A', $CmakeGeneratorPlatform,
    "-DCMAKE_BUILD_TYPE=Release",
    "-DKODI_ADDON_SDK=$KodiAddonSdk",
    "-DCMAKE_INSTALL_PREFIX=$DistDir",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL"
)

if (-not [string]::IsNullOrEmpty($CmakeToolchainFile)) {
    $ConfigArgs += "-DCMAKE_TOOLCHAIN_FILE=$CmakeToolchainFile"
}

if (-not [string]::IsNullOrEmpty($CmakeExtraArgs)) {
    # Split on whitespace outside of double-quoted strings
    $ExtraTokens = [System.Text.RegularExpressions.Regex]::Split(
        $CmakeExtraArgs.Trim(), '\s+(?=(?:[^"]*"[^"]*")*[^"]*$)'
    ) | Where-Object { $_ -ne '' }
    $ConfigArgs += $ExtraTokens
}

Write-Host "==> cmake configure"
Invoke-Cmake $ConfigArgs

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
Write-Host "==> cmake build"
Invoke-Cmake @('--build', $BuildDir, '--config', 'Release')

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
Write-Host "==> cmake install"
Invoke-Cmake @('--install', $BuildDir, '--config', 'Release')

# ---------------------------------------------------------------------------
# Version stamp
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrEmpty($Version)) {
    $AddonXml = Join-Path $DistDir 'pvr.dispatcharr\addon.xml'
    if (Test-Path $AddonXml) {
        # Strip leading 'v'
        $Version = $Version -replace '^v', ''
        Write-Host "==> Updating addon.xml version to: $Version"
        $Content = Get-Content $AddonXml -Raw
        # Replace the version attribute only inside the opening <addon ...> tag
        $Content = $Content -replace '(<addon\b[^>]*\bversion=")[^"]*(")', "`${1}$Version`$2"
        Set-Content -Path $AddonXml -Value $Content -NoNewline
    } else {
        Write-Warning "addon.xml not found at $AddonXml, skipping version update"
    }
}

Write-Host "OK: Built addon package at: $DistDir\pvr.dispatcharr"

# ---------------------------------------------------------------------------
# ZIP packaging
# ---------------------------------------------------------------------------
if ($SkipZip) {
    Write-Host "Skipping ZIP creation (-SkipZip flag set)"
} else {
    $AddonSrcDir = Join-Path $DistDir 'pvr.dispatcharr'
    if (Test-Path $AddonSrcDir) {
        # Read version from installed addon.xml
        $AddonVersion = ''
        $AddonXml = Join-Path $AddonSrcDir 'addon.xml'
        if (Test-Path $AddonXml) {
            $XmlContent = Get-Content $AddonXml -Raw
            if ($XmlContent -match '<addon\b[^>]*\bversion="([^"]+)"') {
                $AddonVersion = $Matches[1]
            }
        }

        # Fallback: read version from CMakeLists.txt
        if ([string]::IsNullOrEmpty($AddonVersion)) {
            $CmakeFile = Join-Path $RootDir 'CMakeLists.txt'
            if (Test-Path $CmakeFile) {
                $CmakeContent = Get-Content $CmakeFile -Raw
                if ($CmakeContent -match 'set\(ADDON_VERSION\s+"([^"]+)"\)') {
                    $AddonVersion = $Matches[1]
                }
            }
        }

        $ZipName = 'pvr.dispatcharr'
        if (-not [string]::IsNullOrEmpty($AddonVersion)) {
            $ZipName += "-$AddonVersion"
        } else {
            Write-Warning "Could not determine addon version; ZIP will not include version."
        }
        $ZipName += '-windows.zip'
        $ZipPath  = Join-Path $DistDir $ZipName

        Write-Host "Packaging addon version: $AddonVersion -> $ZipName"

        # Remove existing ZIP if present
        if (Test-Path $ZipPath) {
            Remove-Item $ZipPath -Force
        }

        # Compress-Archive requires the source to be a directory whose *contents*
        # appear under a named top-level folder inside the archive.
        # We achieve this by compressing $DistDir\pvr.dispatcharr so that the
        # archive contains pvr.dispatcharr\ at the top level.
        Compress-Archive -Path $AddonSrcDir -DestinationPath $ZipPath

        Write-Host "OK: Packaged Kodi ZIP at: $ZipPath"
    } else {
        Write-Warning "Addon source directory not found at $AddonSrcDir, skipping ZIP."
    }
}

# ---------------------------------------------------------------------------
# Install to Kodi
# ---------------------------------------------------------------------------
if ($InstallToKodi) {
    $SrcDir = Join-Path $DistDir 'pvr.dispatcharr'
    $DstDir = Join-Path $KodiAddonsDir 'pvr.dispatcharr'

    if (-not (Test-Path $SrcDir)) {
        Write-Error "ERROR: Built addon package not found at: $SrcDir"
        exit 1
    }

    # Warn if Kodi is running (check case-insensitively for all kodi* process variants)
    $KodiProcess = Get-Process -Name 'kodi*' -ErrorAction SilentlyContinue
    if ($KodiProcess) {
        Write-Warning "Kodi appears to be running. If the addon doesn't refresh, quit and reopen Kodi."
    }

    # Remove existing installation and copy fresh
    if (Test-Path $DstDir) {
        Remove-Item -Recurse -Force $DstDir
    }
    New-Item -ItemType Directory -Force -Path $KodiAddonsDir | Out-Null
    Copy-Item -Recurse $SrcDir $DstDir

    Write-Host "OK: Installed addon to: $DstDir"
}
