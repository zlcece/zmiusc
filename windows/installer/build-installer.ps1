[CmdletBinding()]
param(
    [string]$RunnerDirectory,
    [string]$OutputFile,
    [string]$MakeNsisPath = 'D:\Program Files\NSIS\makensis.exe',
    [switch]$TestMode,
    [switch]$KeepPayload
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'build'))
$packageRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot 'package'))
$payloadDirectory = [IO.Path]::GetFullPath((Join-Path $packageRoot 'nsis-payload'))
$scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'ZmusicSetup.nsi'))
$iconPath = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot 'zmusic-installer.ico'))

if ([string]::IsNullOrWhiteSpace($RunnerDirectory)) {
    $RunnerDirectory = Join-Path $buildRoot 'windows\x64-ninja\runner'
}
$RunnerDirectory = [IO.Path]::GetFullPath($RunnerDirectory)

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path $repositoryRoot 'dist\zmusic-windows-x64.exe'
}
$OutputFile = [IO.Path]::GetFullPath($OutputFile)

foreach ($requiredPath in @($MakeNsisPath, $RunnerDirectory, $scriptPath, $iconPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required installer input is missing: $requiredPath"
    }
}

$pubspecPath = Join-Path $repositoryRoot 'pubspec.yaml'
$versionMatch = [regex]::Match(
    [IO.File]::ReadAllText($pubspecPath),
    '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$')
if (-not $versionMatch.Success) {
    throw 'Unable to read the Flutter version from pubspec.yaml.'
}

$semanticVersion = '{0}.{1}.{2}' -f `
    $versionMatch.Groups[1].Value,
    $versionMatch.Groups[2].Value,
    $versionMatch.Groups[3].Value
$fileVersion = '{0}.{1}' -f $semanticVersion, $versionMatch.Groups[4].Value

function Assert-PathWithinPackageRoot([string]$path) {
    $normalizedRoot = $packageRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    $normalizedPath = [IO.Path]::GetFullPath($path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $normalizedPath.StartsWith(
        $normalizedRoot,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe package path: $normalizedPath"
    }
}

Assert-PathWithinPackageRoot $payloadDirectory
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
if (Test-Path -LiteralPath $payloadDirectory) {
    Remove-Item -LiteralPath $payloadDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $payloadDirectory | Out-Null

$excludedNames = @(
    'CMakeFiles',
    'cmake_install.cmake',
    'just_audio_windows_plugin.dll',
    'userdata',
    'zmusic.installed',
    'uninstall.exe'
)

try {
    foreach ($item in Get-ChildItem -LiteralPath $RunnerDirectory -Force) {
        if ($excludedNames -contains $item.Name) {
            continue
        }
        Copy-Item -LiteralPath $item.FullName -Destination $payloadDirectory `
            -Recurse -Force
    }

    $latestAppSo = Join-Path $buildRoot 'windows\app.so'
    if (Test-Path -LiteralPath $latestAppSo) {
        $payloadDataDirectory = Join-Path $payloadDirectory 'data'
        New-Item -ItemType Directory -Path $payloadDataDirectory -Force | Out-Null
        Copy-Item -LiteralPath $latestAppSo `
            -Destination (Join-Path $payloadDataDirectory 'app.so') -Force
    }

    $requiredPayloadFiles = @(
        'zmusic.exe',
        'flutter_windows.dll',
        'libmpv-2.dll',
        'app_icon.ico',
        'data\app.so',
        'data\icudtl.dat'
    )
    foreach ($relativePath in $requiredPayloadFiles) {
        $payloadPath = Join-Path $payloadDirectory $relativePath
        if (-not (Test-Path -LiteralPath $payloadPath)) {
            throw "Required payload file is missing: $relativePath"
        }
    }

    $forbiddenPayloadNames = @(
        'just_audio_windows_plugin.dll',
        'zmusic.installed',
        'uninstall.exe'
    )
    foreach ($name in $forbiddenPayloadNames) {
        if (Get-ChildItem -LiteralPath $payloadDirectory -Recurse -Force `
            -Filter $name -ErrorAction SilentlyContinue) {
            throw "Forbidden payload entry found: $name"
        }
    }

    $payloadStats = Get-ChildItem -LiteralPath $payloadDirectory -Recurse `
        -File | Measure-Object -Property Length -Sum
    $payloadFileCount = $payloadStats.Count
    $payloadBytes = $payloadStats.Sum
    if ($null -eq $payloadBytes) {
        $payloadBytes = 0
    }
    $payloadSizeKb = [Math]::Max(1, [Math]::Ceiling($payloadBytes / 1KB))

    $outputDirectory = Split-Path -Parent $OutputFile
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    $arguments = @(
        '/V3',
        '/INPUTCHARSET',
        'UTF8',
        "/DAPP_VERSION=$semanticVersion",
        "/DFILE_VERSION=$fileVersion",
        "/DPAYLOAD_DIR=$payloadDirectory",
        "/DPAYLOAD_SIZE_KB=$payloadSizeKb",
        "/DOUTPUT_FILE=$OutputFile",
        "/DICON_FILE=$iconPath"
    )
    if ($TestMode) {
        $arguments += '/DTEST_MODE'
    }
    $arguments += $scriptPath

    & $MakeNsisPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "makensis failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $OutputFile)) {
        throw "NSIS did not create the expected installer: $OutputFile"
    }

    $outputItem = Get-Item -LiteralPath $OutputFile
    [pscustomobject]@{
        OutputFile = $outputItem.FullName
        Version = $semanticVersion
        BuildNumber = [int]$versionMatch.Groups[4].Value
        PayloadFiles = [int]$payloadFileCount
        PayloadBytes = [long]$payloadBytes
        InstallerBytes = $outputItem.Length
        TestMode = [bool]$TestMode
    }
}
finally {
    if (-not $KeepPayload -and (Test-Path -LiteralPath $payloadDirectory)) {
        Assert-PathWithinPackageRoot $payloadDirectory
        Remove-Item -LiteralPath $payloadDirectory -Recurse -Force
    }
}
