#requires -Version 7.0
param(
    [ValidateSet('emulator-5582')][string]$DeviceId = 'emulator-5582',
    [string]$ToolsRoot = 'D:\learning-planet-tools',
    [switch]$UseChinaMirror
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = $projectRoot
$linkPath = Join-Path $ToolsRoot 'learning_planet'
if (Test-Path -LiteralPath $linkPath -PathType Container) {
    $link = Get-Item -LiteralPath $linkPath
    if ($link.LinkType -eq 'Junction' -and
        [IO.Path]::GetFullPath([string]$link.Target).TrimEnd('\') -eq [IO.Path]::GetFullPath($projectRoot).TrimEnd('\')) {
        $buildRoot = $linkPath
    }
}
$toolchain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'android_toolchain.json') -Raw | ConvertFrom-Json
$sdk = Join-Path $ToolsRoot 'android-sdk'
$adb = Join-Path $sdk 'platform-tools/adb.exe'
$flutter = Join-Path $ToolsRoot 'flutter/bin/flutter.bat'
$package = 'com.learningplanet.learning_planet'
function Invoke-Adb([string[]]$Arguments) {
    $value = & $adb -s $DeviceId @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ADB operation failed: $($Arguments[0])" }
    return ($value -join "`n").Trim()
}
function Close-FixtureCrashDialog([string]$RemoteXml) {
    $dump = Invoke-Adb @('shell', 'uiautomator', 'dump', $RemoteXml)
    if ($dump -notmatch 'dumped to:') { return $false }
    try {
        [xml]$tree = Invoke-Adb @('shell', 'cat', $RemoteXml)
        $title = $tree.SelectSingleNode('//node[@package="android" and @resource-id="android:id/alertTitle"]')
        $close = $tree.SelectSingleNode('//node[@package="android" and @resource-id="android:id/aerr_close" and @enabled="true" and @clickable="true"]')
        if ($null -eq $title -or $title.GetAttribute('text') -notlike '*学习星球*' -or $null -eq $close) { return $false }
        $bounds = [regex]::Match($close.GetAttribute('bounds'), '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
        if (-not $bounds.Success) { return $false }
        $x = [int](([int]$bounds.Groups[1].Value + [int]$bounds.Groups[3].Value) / 2)
        $y = [int](([int]$bounds.Groups[2].Value + [int]$bounds.Groups[4].Value) / 2)
        Invoke-Adb @('shell', 'input', 'tap', [string]$x, [string]$y) | Out-Null
        return $true
    } finally { Invoke-Adb @('shell', 'rm', '-f', $RemoteXml) | Out-Null }
}
# Never crash or overwrite a connected user's phone, another emulator, or an
# unknown AVD. This installation contains only generated diagnostic fixtures.
if ((Invoke-Adb @('get-state')) -ne 'device' -or
    (Invoke-Adb @('shell', 'getprop', 'ro.kernel.qemu')) -ne '1' -or
    (Invoke-Adb @('shell', 'getprop', 'ro.build.version.sdk')) -ne '29' -or
    (Invoke-Adb @('shell', 'getprop', 'sys.boot_completed')) -ne '1' -or
    ((Invoke-Adb @('emu', 'avd', 'name')) -split "`n")[0].Trim() -ne 'learning_planet_api29') {
    throw 'Start the dedicated learning_planet_api29 emulator on port 5582 first.'
}
$previous = @{}
foreach ($name in @('JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'GRADLE_USER_HOME', 'FLUTTER_STORAGE_BASE_URL', 'PATH')) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
Push-Location -LiteralPath $buildRoot
try {
    $env:JAVA_HOME = Join-Path $ToolsRoot ('jdk/jdk-' + $toolchain.jdk.version)
    $env:ANDROID_HOME = $sdk
    $env:ANDROID_SDK_ROOT = $sdk
    $env:GRADLE_USER_HOME = Join-Path $ToolsRoot 'gradle-cache'
    $env:PATH = (Join-Path $env:JAVA_HOME 'bin') + ';' + (Join-Path $sdk 'platform-tools') + ';' + $env:PATH
    if ($UseChinaMirror) { $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn' }
    $run = [Guid]::NewGuid().ToString('D')
    $target = 'integration_test/native_crash_test.dart'
    & $flutter build apk --profile --no-pub "--target=$target" --android-project-arg=kotlin.incremental=false "--dart-define=TEST_CRASH_RUN=$run"
    if ($LASTEXITCODE -ne 0) { throw 'Native crash integration APK build failed.' }
    $binary = Join-Path $buildRoot 'build/app/outputs/flutter-apk/app-profile.apk'
    $crashedPids = @()
    $dialogDismissals = 0
    foreach ($phase in 0..2) {
        & $flutter drive --no-dds --profile --no-pub "--device-id=$DeviceId" `
            --driver=test_driver/native_crash_driver.dart "--target=$target" `
            "--use-application-binary=$binary" --keep-app-running "--dart-define=TEST_CRASH_RUN=$run"
        if ($LASTEXITCODE -ne 0) { throw "Native crash phase $phase failed." }
        $reportFile = Join-Path $buildRoot "build/integration_results/native-crash-phase-$phase.json"
        $report = Get-Content -LiteralPath $reportFile -Raw | ConvertFrom-Json
        if ($report.run -ne $run -or $report.phase -ne $phase -or $report.completed -ne $true) {
            throw 'Missing or stale native crash phase report.'
        }
        if ($phase -lt 2) {
            $processId = Invoke-Adb @('shell', 'pidof', $package)
            if ($processId -notmatch '^\d+$') { throw 'Expected one running fixture process.' }
            Invoke-Adb @('shell', 'am', 'crash', $processId) | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            do {
                Start-Sleep -Milliseconds 250
                $remaining = ((& $adb -s $DeviceId shell pidof $package 2>$null) -join '').Trim()
                if ($remaining -eq $processId) {
                    # The OS handler can wait for its repeated-crash dialog.
                    # Dismiss only this fixture app's verified Close app button;
                    # let Android finish its normal crash termination itself.
                    if (Close-FixtureCrashDialog "/data/local/tmp/lp-native-crash-$run-$phase.xml") { $dialogDismissals++ }
                }
            } while ($remaining -eq $processId -and [DateTime]::UtcNow -lt $deadline)
            if ($remaining -eq $processId) { throw 'Android did not terminate the crashed fixture process.' }
            $crashedPids += [int]$processId
        }
    }
    [ordered]@{
        run = $run
        backend = 'none'
        device = 'learning_planet_api29; AOSP API29 x86_64'
        # Do not infer the renderer from the AVD name or command-line request.
        surfaceflinger_gles = [regex]::Match(
            (Invoke-Adb @('shell', 'dumpsys', 'SurfaceFlinger')),
            '(?m)^GLES:[^\r\n]*').Value
        apk_sha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
        actual_process_deaths = $crashedPids
        system_crash_dialogs_closed = $dialogDismissals
        phases_passed = 3
        qualifies_for_device_acceptance = $false
        completed = $true
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $buildRoot 'build/integration_results/native-crash-android29.json') -Encoding utf8
    Write-Output 'PASS: two actual Java process crashes; durable replay, acknowledgement and account isolation verified.'
} finally {
    Pop-Location
    foreach ($name in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
    }
}
