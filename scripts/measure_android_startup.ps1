#requires -Version 7.0
param(
    [string]$DeviceId = 'emulator-5580',
    [ValidateSet('profile', 'debug')][string]$Mode = 'profile',
    [ValidateRange(1, 10)][int]$Samples = 5,
    [string]$ToolsRoot = 'D:\learning-planet-tools',
    [switch]$UseExistingApk,
    [switch]$TraceStartup,
    [switch]$UseChinaMirror
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = $projectRoot
$workspaceLink = Join-Path $ToolsRoot 'learning_planet'
if (Test-Path -LiteralPath $workspaceLink -PathType Container) {
    $link = Get-Item -LiteralPath $workspaceLink
    if ($link.LinkType -eq 'Junction' -and
        [IO.Path]::GetFullPath([string]$link.Target).TrimEnd('\') -eq [IO.Path]::GetFullPath($projectRoot).TrimEnd('\')) {
        $buildRoot = $workspaceLink
    }
}
$sdkRoot = Join-Path $ToolsRoot 'android-sdk'
$adb = Join-Path $sdkRoot 'platform-tools/adb.exe'
$flutter = Join-Path $ToolsRoot 'flutter/bin/flutter.bat'
$toolchain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'android_toolchain.json') -Raw | ConvertFrom-Json
$javaRoot = Join-Path $ToolsRoot ('jdk/jdk-' + $toolchain.jdk.version)
$package = 'com.learningplanet.learning_planet'
$apkPath = Join-Path $buildRoot "build/app/outputs/flutter-apk/app-$Mode.apk"
$outputRoot = Join-Path $projectRoot 'build/startup_results'
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$reportPath = Join-Path $outputRoot "startup-$Mode-$runId.json"

function Invoke-Adb([string[]]$Arguments) {
    $output = & $adb -s $DeviceId @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ADB operation failed: $($Arguments[0])" }
    return ($output -join "`n").Trim()
}
function Property([string]$Name) { Invoke-Adb @('shell', 'getprop', $Name) }
function Field([string]$Output, [string]$Name) {
    $match = [regex]::Match($Output, '(?m)^' + [regex]::Escape($Name) + ':\s*([^\r\n]+)')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

$previous = @{}
foreach ($name in @('JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'GRADLE_USER_HOME', 'FLUTTER_STORAGE_BASE_URL', 'PATH')) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
Push-Location -LiteralPath $buildRoot
try {
    $env:JAVA_HOME = $javaRoot
    $env:ANDROID_HOME = $sdkRoot
    $env:ANDROID_SDK_ROOT = $sdkRoot
    $env:GRADLE_USER_HOME = Join-Path $ToolsRoot 'gradle-cache'
    $env:PATH = (Join-Path $javaRoot 'bin') + ';' + (Join-Path $sdkRoot 'platform-tools') + ';' + $env:PATH
    if ($UseChinaMirror) { $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn' }
    if ((Invoke-Adb @('get-state')) -ne 'device' -or (Property 'sys.boot_completed') -ne '1') {
        throw 'The selected test device must be connected and fully booted.'
    }
    if (-not $UseExistingApk) {
        # No backend definitions and no integration entrypoint: measure the same
        # production initialization used by the unconfigured debug delivery.
        $definitions = @()
        if ($TraceStartup) { $definitions += '--dart-define=MEASURE_STARTUP=true' }
        & $flutter build apk "--$Mode" --target=lib/main.dart --no-pub --android-project-arg=kotlin.incremental=false @definitions
        if ($LASTEXITCODE -ne 0) { throw 'Production startup APK build failed.' }
    }
    $apk = Get-Item -LiteralPath $apkPath
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($apk.FullName)
    try {
        $kernel = $archive.GetEntry('assets/flutter_assets/kernel_blob.bin')
        if (($Mode -eq 'debug') -ne ($null -ne $kernel)) { throw 'APK build mode does not match the measurement mode.' }
        if ($Mode -eq 'profile' -and $null -eq $archive.GetEntry('lib/arm64-v8a/libapp.so')) {
            throw 'Profile APK is missing its AOT application library.'
        }
    } finally { $archive.Dispose() }
    $install = Invoke-Adb @('install', '-r', $apk.FullName)
    if ($install -notmatch '(?m)^Success\s*$') { throw 'APK installation did not report success.' }
    $report = [ordered]@{
        version = 1
        created_at_utc = [DateTime]::UtcNow.ToString('o')
        package = $package
        mode = $Mode
        intended_entrypoint = 'lib/main.dart'
        entrypoint_built_this_run = -not [bool]$UseExistingApk
        backend = 'none'
        startup_trace_requested = [bool]$TraceStartup
        screen = 'unconfigured_service'
        apk_sha256 = (Get-FileHash -LiteralPath $apk.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        apk_bytes = $apk.Length
        device = [ordered]@{
            api = Property 'ro.build.version.sdk'
            manufacturer = Property 'ro.product.manufacturer'
            model = Property 'ro.product.model'
            abi = Property 'ro.product.cpu.abi'
            emulator = (Property 'ro.kernel.qemu') -eq '1'
            # SurfaceFlinger's GLES context is environment evidence, not proof
            # of Flutter's selected backend or its own EGL configuration.
            advertised_gles_version = Property 'ro.opengles.version'
            surfaceflinger_gles = [regex]::Match(
                (Invoke-Adb @('shell', 'dumpsys', 'SurfaceFlinger')),
                '(?m)^GLES:[^\r\n]*').Value
        }
        requested_samples = $Samples
        samples = @()
        collection_complete = $false
        qualifies_for_prd_acceptance = $false
    }
    function Save-Report { [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8)) }
    Save-Report
    for ($i = 1; $i -le $Samples; $i++) {
        $null = Invoke-Adb @('shell', 'am', 'force-stop', $package)
        $oldPid = & $adb -s $DeviceId shell pidof $package 2>$null
        if ($oldPid) { throw 'App process is still running after force-stop; refusing to label this a cold start.' }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $start = Invoke-Adb @('shell', 'am', 'start', '-W', '-n', "$package/.MainActivity")
        $entry = [ordered]@{
            index = $i
            first_after_install = $i -eq 1
            previous_process_absent = $true
            status = Field $start 'Status'
            launch_state = Field $start 'LaunchState'
            initial_display_ms = $null
            screen_verified = $false
            screen_verified_at_ms = $null
            phases = @()
        }
        $total = Field $start 'TotalTime'
        if ($entry.status -eq 'ok' -and $entry.launch_state -eq 'COLD' -and $total -match '^\d+$') {
            $entry.initial_display_ms = [int]$total
        }
        [IO.File]::WriteAllText((Join-Path $outputRoot "startup-$Mode-$runId-$i.txt"), $start)
        # A hierarchy read occurs after TTID measurement. It confirms the screen
        # but includes ADB/UIAutomator overhead, so it is NOT a TTFD metric.
        $remoteXml = "/sdcard/learning-planet-startup-$runId-$i.xml"
        try {
            while ($watch.Elapsed.TotalSeconds -lt 30 -and -not $entry.screen_verified) {
                $dump = & $adb -s $DeviceId shell uiautomator dump $remoteXml 2>&1
                if ($LASTEXITCODE -eq 0 -and ($dump -join "`n") -match 'dumped to:') {
                    $xml = Invoke-Adb @('shell', 'cat', $remoteXml)
                    $entry.screen_verified = $xml.Contains('调试版本尚未连接服务')
                    if ($entry.screen_verified) { $entry.screen_verified_at_ms = $watch.ElapsedMilliseconds }
                }
                if (-not $entry.screen_verified) { Start-Sleep -Milliseconds 500 }
            }
        } finally {
            # This exact temporary name is generated here; no app data is removed.
            $null = & $adb -s $DeviceId shell rm -f $remoteXml 2>&1
        }
        $watch.Stop()
        if ($TraceStartup) {
            $appPid = (& $adb -s $DeviceId shell pidof $package 2>$null) -join ''
            if ($appPid -match '^\d+$') {
                $logs = Invoke-Adb @('logcat', '-d', "--pid=$appPid", '-s', 'LP_STARTUP:I', 'flutter:I')
                # Retain only fixed phase names and durations, never log messages,
                # exception text, VM-service URLs, tokens or account data.
                $pattern = 'source=(dart|android) stage=(binding|notifications|timezone|notificationPlugin|taskAlarmClear|notificationClear|database|credentials|supabase|push|initialization|first_frame|activity_create|activity_first_frame|plugins|channels) elapsed_us=(\d+) outcome=(ok|error)'
                $entry.phases = @([regex]::Matches($logs, $pattern) | ForEach-Object {
                    [ordered]@{ source = $_.Groups[1].Value; stage = $_.Groups[2].Value; elapsed_us = [long]$_.Groups[3].Value; outcome = $_.Groups[4].Value }
                })
            }
        }
        $report.samples += $entry
        Save-Report
        Write-Output "Sample $i/$Samples : status=$($entry.status), launch=$($entry.launch_state), TTID=$($entry.initial_display_ms) ms, screen_verified=$($entry.screen_verified)"
    }
    $valid = @($report.samples | Where-Object { $null -ne $_.initial_display_ms } | ForEach-Object { $_.initial_display_ms } | Sort-Object)
    $report['valid_ttid_samples'] = $valid.Count
    $report['timeout_samples'] = @($report.samples | Where-Object status -eq 'timeout').Count
    $report['ttid_median_ms'] = if ($valid.Count -eq 0) { $null } elseif ($valid.Count % 2) { $valid[[int][Math]::Floor($valid.Count / 2)] } else { ($valid[$valid.Count / 2 - 1] + $valid[$valid.Count / 2]) / 2 }
    $report['ttid_min_ms'] = if ($valid.Count) { $valid[0] } else { $null }
    $report['ttid_max_ms'] = if ($valid.Count) { $valid[-1] } else { $null }
    $report.collection_complete = $true
    Save-Report
    Write-Output "Startup observations saved: $reportPath"
    if (@($report.samples | Where-Object { -not $_.screen_verified }).Count) {
        throw 'At least one sample did not reach the expected configuration screen; see the retained report.'
    }
    if ($TraceStartup -and @($report.samples | Where-Object { $_.phases.Count -eq 0 }).Count) {
        throw 'Startup trace was requested but missing from at least one sample; rebuild with -TraceStartup.'
    }
} finally {
    Pop-Location
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}
