#requires -Version 7.0
param(
    [string]$FlutterSdk,
    [string]$ToolsRoot = 'D:\learning-planet-tools',
    [string]$DartDefinesFile,
    [switch]$NoPub,
    [switch]$VerboseBuild,
    [switch]$UseChinaMirror
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = $projectRoot
# Use the same workspace spelling as Android JVM tests. Switching between a
# junction and its target can make Flutter delete assets as stale outputs.
$workspaceLink = Join-Path $ToolsRoot 'learning_planet'
if (Test-Path -LiteralPath $workspaceLink -PathType Container) {
    $link = Get-Item -LiteralPath $workspaceLink
    if ($link.LinkType -eq 'Junction' -and
        [IO.Path]::GetFullPath([string]$link.Target).TrimEnd('\') -eq [IO.Path]::GetFullPath($projectRoot).TrimEnd('\')) {
        $buildRoot = $workspaceLink
    }
}
if (-not $FlutterSdk) { $FlutterSdk = Join-Path $ToolsRoot 'flutter' }
$toolchain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'android_toolchain.json') -Raw | ConvertFrom-Json
$javaRoot = Join-Path $ToolsRoot ('jdk/jdk-' + $toolchain.jdk.version)
$sdkRoot = Join-Path $ToolsRoot 'android-sdk'
$flutterCommand = Join-Path $FlutterSdk 'bin/flutter.bat'
foreach ($requiredPath in @(
    $flutterCommand,
    (Join-Path $javaRoot 'bin/java.exe'),
    (Join-Path $sdkRoot 'platform-tools/adb.exe'),
    (Join-Path $sdkRoot 'platforms/android-36/android.jar'),
    (Join-Path $sdkRoot 'build-tools/36.0.0/aapt2.exe'),
    (Join-Path $sdkRoot 'ndk/28.2.13676358/source.properties')
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Missing build dependency: $requiredPath. See docs/ANDROID_BUILD.md."
    }
}

# Kotlin's relative incremental-cache paths cannot cross Windows drives.
# Pass the option explicitly through Flutter to Gradle for this build only.
$buildArguments = @('build', 'apk', '--debug', '--android-project-arg=kotlin.incremental=false')
if ($NoPub) { $buildArguments += '--no-pub' }
if ($VerboseBuild) { $buildArguments += '--verbose' }
if ($DartDefinesFile) {
    $definesPath = (Resolve-Path -LiteralPath $DartDefinesFile).Path
    $buildArguments += "--dart-define-from-file=$definesPath"
}

# Keep the SDK/JDK and Gradle cache isolated; never write user or machine PATH.
$previousEnvironment = @{}
foreach ($name in @('JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'GRADLE_USER_HOME', 'FLUTTER_STORAGE_BASE_URL', 'PATH')) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
Push-Location -LiteralPath $buildRoot
try {
    $env:JAVA_HOME = $javaRoot
    $env:ANDROID_HOME = $sdkRoot
    $env:ANDROID_SDK_ROOT = $sdkRoot
    $env:GRADLE_USER_HOME = Join-Path $ToolsRoot 'gradle-cache'
    if ($UseChinaMirror) { $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn' }
    $env:PATH = (Join-Path $javaRoot 'bin') + ';' + (Join-Path $sdkRoot 'platform-tools') + ';' + $env:PATH
    & $flutterCommand @buildArguments
    $buildExitCode = $LASTEXITCODE
    if ($buildExitCode -eq 0) {
        & (Join-Path $PSScriptRoot 'verify_android_apk.ps1') -ApkPath (Join-Path $buildRoot 'build/app/outputs/flutter-apk/app-debug.apk')
    }
} finally {
    Pop-Location
    foreach ($name in $previousEnvironment.Keys) {
        # PowerShell can coerce null to an empty string in the .NET call. Flutter
        # treats an empty storage URL as a relative Maven repository on the next build.
        if ($null -eq $previousEnvironment[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
}
exit $buildExitCode
