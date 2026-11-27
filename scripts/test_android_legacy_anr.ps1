#requires -Version 7.0
param(
    [ValidateSet('emulator-5582')][string]$DeviceId = 'emulator-5582',
    [string]$ToolsRoot = 'D:\learning-planet-tools',
    [switch]$UseChinaMirror,
    [switch]$SkipBuild
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
$sdk = Join-Path $ToolsRoot 'android-sdk'
$adb = Join-Path $sdk 'platform-tools/adb.exe'
$flutter = Join-Path $ToolsRoot 'flutter/bin/flutter.bat'
$package = 'com.learningplanet.learning_planet.anrfixture'
function Invoke-Adb([string[]]$Arguments) {
    $value = & $adb -s $DeviceId @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ADB operation failed: $($Arguments[0])" }
    return ($value -join "`n").Trim()
}
# This script installs and intentionally stalls only a generated local fixture.
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
    $toolchain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'android_toolchain.json') -Raw | ConvertFrom-Json
    $env:JAVA_HOME = Join-Path $ToolsRoot ('jdk/jdk-' + $toolchain.jdk.version)
    $env:ANDROID_HOME = $sdk
    $env:ANDROID_SDK_ROOT = $sdk
    $env:GRADLE_USER_HOME = Join-Path $ToolsRoot 'gradle-cache'
    $env:PATH = (Join-Path $env:JAVA_HOME 'bin') + ';' + $env:PATH
    if ($UseChinaMirror) { $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn' }
    if (-not $SkipBuild) {
        & $flutter build apk --debug --no-pub --target=integration_test/native_anr_fixture.dart `
            '--android-project-arg=kotlin.incremental=false' '--android-project-arg=legacyAnrFixture=true'
        if ($LASTEXITCODE -ne 0) { throw 'ANR fixture APK build failed.' }
    }
    $binary = Join-Path $buildRoot 'build/app/outputs/flutter-apk/app-debug.apk'
    # SkipBuild is for local iteration; never run an arbitrary existing app.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($binary)
    try {
        $reader = [IO.StreamReader]::new($archive.GetEntry('assets/flutter_assets/kernel_blob.bin').Open())
        try {
            if (-not $reader.ReadToEnd().Contains('integration_test/native_anr_fixture.dart')) {
                throw 'The installed target must be the generated ANR fixture.'
            }
        } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
    $buildTools = @($toolchain.packages | Where-Object { $_ -like 'build-tools;*' })
    if ($buildTools.Count -ne 1) { throw 'Expected one pinned Android Build Tools version.' }
    $aapt = Join-Path $sdk ('build-tools/' + $buildTools[0].Split(';')[1] + '/aapt2.exe')
    $badging = (& $aapt dump badging $binary) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $badging -notmatch "package: name='$([regex]::Escape($package))'") {
        throw 'The ANR fixture must have its own application ID.'
    }
    Invoke-Adb @('install', '-r', $binary) | Out-Null
    $run = [Guid]::NewGuid().ToString('D')
    $results = Join-Path $buildRoot 'build/integration_results'
    New-Item -ItemType Directory -Path $results -Force | Out-Null
    $event = ''
    $processes = @()
    foreach ($phase in @('capture', 'verify')) {
        # Kill only the verified fixture between phases to prove disk replay.
        Invoke-Adb @('shell', 'am', 'force-stop', $package) | Out-Null
        Invoke-Adb @('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP') | Out-Null
        Invoke-Adb @('shell', 'wm', 'dismiss-keyguard') | Out-Null
        Invoke-Adb @('shell', 'am', 'start', '-W', '-n', "$package/com.learningplanet.learning_planet.LegacyAnrFixtureActivity",
            '--es', 'scope', $run, '--es', 'phase', $phase, '--es', 'event', $(if ($event) { $event } else { 'none' })) | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds(80)
        $report = $null
        do {
            $raw = & $adb -s $DeviceId exec-out run-as $package cat "files/native-anr-$run-$phase.json" 2>$null
            if ($LASTEXITCODE -eq 0) {
                try { $report = ($raw -join "`n") | ConvertFrom-Json } catch { $report = $null }
            }
            if ($null -eq $report) { Start-Sleep -Seconds 1 }
        } while ($null -eq $report -and [DateTime]::UtcNow -lt $deadline)
        if ($null -eq $report) {
            Invoke-Adb @('shell', 'am', 'force-stop', $package) | Out-Null
            throw "ANR $phase phase timed out."
        }
        $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $results "native-anr-$run-$phase.json") -Encoding utf8
        if ($report.run -ne $run -or $report.phase -ne $phase -or $report.completed -ne $true) {
            throw "ANR $phase phase failed. See the run-specific report."
        }
        $processes += [int]$report.pid
        if ($phase -eq 'capture') {
            if ($report.system_confirmed_anr -ne $true) { throw 'No OS-confirmed ANR.' }
            $event = $report.event
            if ($event -notmatch '^[0-9a-f-]{36}$') { throw 'Missing captured event ID.' }
        } elseif ($report.fixed_fields_replay_ack_scope_passed -ne $true) {
            throw 'Disk replay checks were not completed.'
        }
    }
    if ($processes[0] -eq $processes[1]) { throw 'The fixture process did not restart.' }
    [ordered]@{
        run = $run
        backend = 'none'
        device = 'learning_planet_api29; AOSP API29 x86_64'
        surfaceflinger_gles = [regex]::Match((Invoke-Adb @('shell', 'dumpsys', 'SurfaceFlinger')), '(?m)^GLES:[^\r\n]*').Value
        apk_sha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
        package = $package
        process_ids = $processes
        system_confirmed_anrs = 1
        phases_passed = 2
        qualifies_for_device_acceptance = $false
        completed = $true
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $results 'native-anr-android29.json') -Encoding utf8
    Invoke-Adb @('shell', 'am', 'force-stop', $package) | Out-Null
    Write-Output 'PASS: OS-confirmed ANR; process restart, fixed fields, replay, acknowledgement and scope checks.'
} finally {
    Pop-Location
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}
