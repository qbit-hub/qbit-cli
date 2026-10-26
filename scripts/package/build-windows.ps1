# Builds a .msi installer from the release binary using WiX v5.
#
# Prerequisites (one-time, on the build machine / CI runner):
#   dotnet tool install --global wix --version 5.0.2
#
# Usage:
#   .\build-windows.ps1 -Version 1.0.0 -Arch x64 -BinaryPath target\release\qbit.exe -OutDir dist

param(
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$Arch,
    [Parameter(Mandatory=$true)][string]$BinaryPath,
    [string]$OutDir = "dist"
)

$ErrorActionPreference = "Stop"

# --- Requirement 3.1: reject invalid Windows version strings ---
# MSI ProductVersion requires a strict numeric X.Y.Z (Z optional) format.
# Suffixes like "-ci" or "-test" are not valid MSI versions and must be
# rejected here rather than silently truncated or passed through.
if ($Version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
    throw "Invalid version '$Version'. MSI requires strict numeric X.Y.Z or X.Y.Z.W format (no suffixes like '-ci')."
}

# --- Requirement 3.2: architecture allowlist ---
$allowedArch = @("x64", "arm64")
if ($allowedArch -notcontains $Arch) {
    throw "Invalid architecture '$Arch'. Allowed values: $($allowedArch -join ', ')"
}

if (-not (Test-Path -LiteralPath $BinaryPath)) {
    throw "Binary not found at $BinaryPath. Run 'cargo build --release' first."
}

$scriptDir = $PSScriptRoot
$repoRoot = Resolve-Path (Join-Path $scriptDir "..\..")
$wxsPath = Join-Path $repoRoot "packaging\windows\QbitCli.wxs"
$iconPath = Join-Path $repoRoot "assets\icon.ico"

if (-not (Test-Path -LiteralPath $wxsPath)) {
    throw "WiX source not found at $wxsPath"
}
if (-not (Test-Path -LiteralPath $iconPath)) {
    throw "Icon not found at $iconPath (expected assets\icon.ico)"
}

# Requirement 3.7: a genuinely invalid/corrupt .ico should fail the
# build rather than silently produce a broken installer. A minimal
# sanity check: real .ico files start with the bytes 00 00 01 00.
$iconBytes = [System.IO.File]::ReadAllBytes($iconPath)
if ($iconBytes.Length -lt 4 -or $iconBytes[0] -ne 0 -or $iconBytes[1] -ne 0 -or $iconBytes[2] -ne 1 -or $iconBytes[3] -ne 0) {
    throw "File at $iconPath does not have a valid .ico header. It may be corrupt or the wrong format."
}

# --- Requirement 3.3: verify WiX CLI is present and is the expected major version ---
$wixVersionOutput = & wix --version 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "WiX CLI not found or not runnable. Install it with: dotnet tool install --global wix --version 5.0.2"
}
if ($wixVersionOutput -notmatch '^5\.') {
    throw "Expected WiX v5.x, found: $wixVersionOutput. This project is pinned to WiX v5 to avoid the v6+/v7 Open Source Maintenance Fee EULA requirement."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# --- Requirement 3.4: deterministic, exact output filename ---
$outFile = Join-Path $OutDir "qbit-cli-$Version-windows-$Arch.msi"
$absBinaryPath = (Resolve-Path $BinaryPath).Path

wix build $wxsPath `
    -d "ProductVersion=$Version" `
    -d "QbitBinaryPath=$absBinaryPath" `
    -d "IconPath=$iconPath" `
    -arch $Arch `
    -out $outFile

# --- Requirement 3.6: WiX tool failure must fail the build ---
if ($LASTEXITCODE -ne 0) {
    throw "wix build failed with exit code $LASTEXITCODE"
}

# --- Requirement 3.5: verify the MSI exists and is non-zero size ---
if (-not (Test-Path -LiteralPath $outFile)) {
    throw "Expected MSI was not produced at $outFile"
}
$msiSize = (Get-Item -LiteralPath $outFile).Length
if ($msiSize -le 0) {
    throw "MSI at $outFile has zero size - build likely failed silently."
}

Write-Host "Built: $outFile ($msiSize bytes)"
