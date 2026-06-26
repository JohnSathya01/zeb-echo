# Bundle the backend executable + ffmpeg into the built Windows app so the
# packaged app is self-contained (PHASE2_PLAN.md §1, M2). The Dart
# BackendLauncher resolves these at:
#   <install-dir>\backend\{zeb-echo-backend.exe, ffmpeg.exe}
# (see client/lib/services/backend_launcher_io.dart _defaultExecutablePath).
#
# Usage:
#   scripts\bundle_windows.ps1 -ReleaseDir <flutter-build-release-dir> `
#       -BackendExe <path-to-backend.exe> -FfmpegExe <path-to-ffmpeg.exe>
#
# ReleaseDir is the folder containing zeb_echo_client.exe, i.e.
#   client\build\windows\x64\runner\Release
param(
    [Parameter(Mandatory = $true)][string]$ReleaseDir,
    [Parameter(Mandatory = $true)][string]$BackendExe,
    [Parameter(Mandatory = $true)][string]$FfmpegExe
)

$ErrorActionPreference = "Stop"

Write-Host "[bundle:windows] release: $ReleaseDir"
Write-Host "[bundle:windows] backend: $BackendExe"
Write-Host "[bundle:windows] ffmpeg:  $FfmpegExe"

if (-not (Test-Path $ReleaseDir)) { throw "Release dir not found: $ReleaseDir" }
if (-not (Test-Path $BackendExe)) { throw "Backend exe not found: $BackendExe" }
if (-not (Test-Path $FfmpegExe)) { throw "ffmpeg not found: $FfmpegExe" }

$backendDir = Join-Path $ReleaseDir "backend"
New-Item -ItemType Directory -Force -Path $backendDir | Out-Null

Copy-Item $BackendExe (Join-Path $backendDir "zeb-echo-backend.exe") -Force
Copy-Item $FfmpegExe (Join-Path $backendDir "ffmpeg.exe") -Force

Write-Host "[bundle:windows] bundled into ${backendDir}:"
Get-ChildItem $backendDir | Format-Table Name, Length
Write-Host "[bundle:windows] done."
