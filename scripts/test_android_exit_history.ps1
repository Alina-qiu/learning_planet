#requires -Version 7.0
param(
    [ValidateSet('emulator-5580')][string]$DeviceId = 'emulator-5580',
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
$package = 'com.learningplanet.learning_planet.exitfixture'
function Invoke-Adb([string[]]$Arguments) {
    $value = & $adb -s $DeviceId @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ADB operation failed: $($Arguments[0])" }
    return ($value -join "`n").Trim()
}
function Close-FixtureDialog {
    $remote = '/data/local/tmp/lp-exit-fixture.xml'
    $dump = Invoke-Adb @('shell', 'uiautomator', 'dump', $remote)
    if ($dump -notmatch 'dumped to:') { return }
    [xml]$tree = Invoke-Adb @('shell', 'cat', $remote)
    $title = $tree.SelectSingleNode('//node[@package="android" and @resource-id="android:id/alertTitle"]')
    $button = $tree.SelectSingleNode('//node[@package="android" and @resource-id="android:id/aerr_close" and @enabled="true" and @clickable="true"]')
    if ($null -eq $title -or $title.GetAttribute('text') -notlike '*学习星球退出记录测试*' -or $null -eq $button) { return }
    $bounds = [regex]::Match($button.GetAttribute('bounds'), '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
    if (-not $bounds.Success) { return }
    $x = [int](([int]$bounds.Groups[1].Value + [int]$bounds.Groups[3].Value) / 2)
    $y = [int](([int]$bounds.Groups[2].Value + [int]$bounds.Groups[4].Value) / 2)
    Invoke-Adb @('shell', 'input', 'tap', [string]$x, [string]$y) | Out-Null
}
# Fail before installation unless this is the dedicated disposable emulator.
if ((Invoke-Adb @('get-state')) -ne 'device' -or
    (Invoke-Adb @('shell', 'getprop', 'ro.kernel.qemu')) -ne '1' -or
    (Invoke-Adb @('shell', 'getprop', 'ro.build.version.sdk')) -ne '36' -or
    (Invoke-Adb @('shell', 'getprop', 'sys.boot_completed')) -ne '1' -or
    ((Invoke-Adb @('emu', 'avd', 'name')) -split "`n")[0].Trim() -ne 'learning_planet_api36') {
    throw 'Start the dedicated learning_planet_api36 emulator on port 5580 first.'
}
$previous = @{}
foreach ($name in @('JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'GRADLE_USER_HOME', 'FLUTTER_STORAGE_BASE_URL', 'PATH')) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$results = Join-Path $buildRoot 'build/integration_results'
New-Item -ItemType Directory -Path $results -Force | Out-Null
$run = [Guid]::NewGuid().ToString('D')
$summary = [ordered]@{run=$run; completed=$false; status='running'; backend='none'; package=$package;
    device='learning_planet_api36; AOSP API36 x86_64'; qualifies_for_device_acceptance=$false; phases=@()}
$summaryPath = Join-Path $results 'native-exit-android36.json'
function Save-Summary { $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8 }
Save-Summary
Push-Location -LiteralPath $buildRoot
try {
    $toolchain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'android_toolchain.json') -Raw | ConvertFrom-Json
    $env:JAVA_HOME = Join-Path $ToolsRoot ('jdk/jdk-' + $toolchain.jdk.version)
    $env:ANDROID_HOME = $sdk
    $env:ANDROID_SDK_ROOT = $sdk
    $env:GRADLE_USER_HOME = Join-Path $ToolsRoot 'gradle-cache'
    $env:PATH = (Join-Path $env:JAVA_HOME 'bin') + ';' + $env:PATH
    if ($UseChinaMirror) { $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn' }
    $binary = Join-Path $results 'native-exit-fixture.apk'
    if (-not $SkipBuild) {
        & (Join-Path $ToolsRoot 'flutter/bin/flutter.bat') build apk --debug --no-pub --target=integration_test/native_exit_fixture.dart `
            '--android-project-arg=kotlin.incremental=false' '--android-project-arg=exitHistoryFixture=true'
        if ($LASTEXITCODE -ne 0) { throw 'Exit history fixture APK build failed.' }
        Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-debug.apk' -Destination $binary
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($binary)
    try {
        $reader = [IO.StreamReader]::new($archive.GetEntry('assets/flutter_assets/kernel_blob.bin').Open())
        try {
            if (-not $reader.ReadToEnd().Contains('integration_test/native_exit_fixture.dart')) {
                throw 'Expected the dedicated exit history test entry point.'
            }
        } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
    $buildTools = @($toolchain.packages | Where-Object { $_ -like 'build-tools;*' })
    if ($buildTools.Count -ne 1) { throw 'Expected one pinned Android Build Tools version.' }
    $aapt = Join-Path $sdk ('build-tools/' + $buildTools[0].Split(';')[1] + '/aapt2.exe')
    $badging = (& $aapt dump badging $binary) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $badging -notmatch "package: name='$([regex]::Escape($package))'") {
        throw 'The exit history fixture must have its own application ID.'
    }
    $summary.apk_sha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
    Invoke-Adb @('install', '-r', $binary) | Out-Null
    foreach ($phase in @('java', 'native', 'collect', 'verify')) {
        Invoke-Adb @('shell', 'am', 'force-stop', $package) | Out-Null
        Invoke-Adb @('shell', 'am', 'start', '-W', '-n', "$package/com.learningplanet.learning_planet.ExitHistoryFixtureActivity",
            '--es', 'scope', $run, '--es', 'phase', $phase) | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds(50)
        $report = $null
        do {
            $raw = & $adb -s $DeviceId exec-out run-as $package cat "files/native-exit-$run-$phase.json" 2>$null
            if ($LASTEXITCODE -eq 0) {
                try { $report = ($raw -join "`n") | ConvertFrom-Json } catch { $report = $null }
            }
            if ($null -eq $report) { Start-Sleep -Milliseconds 500 }
        } while ($null -eq $report -and [DateTime]::UtcNow -lt $deadline)
        if ($null -eq $report) { throw "Exit history $phase phase timed out." }
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $results "native-exit-$run-$phase.json") -Encoding utf8
        if ($report.run -ne $run -or $report.phase -ne $phase -or $report.completed -ne $true) {
            throw "Exit history $phase phase failed; see run-specific report."
        }
        $summary.phases += $report
        Save-Summary
        if ($phase -in @('java', 'native')) {
            $deadline = [DateTime]::UtcNow.AddSeconds(35)
            $exited = $false
            $dialogChecked = $false
            do {
                $running = (& $adb -s $DeviceId shell pidof $package 2>$null) -join ' '
                if ($running -notmatch "\b$($report.pid)\b") { $exited = $true; break }
                Start-Sleep -Milliseconds 500
                if (-not $dialogChecked -and [DateTime]::UtcNow -gt $deadline.AddSeconds(-25)) {
                    Close-FixtureDialog
                    $dialogChecked = $true
                }
            } while ([DateTime]::UtcNow -lt $deadline)
            if (-not $exited) { throw "The expected $phase crash process did not exit." }
        }
        Write-Output "PASS exit history phase: $phase"
    }
    if (@($summary.phases.pid | Select-Object -Unique).Count -ne 4) { throw 'Expected four distinct fixture processes.' }
    $summary.status = 'validated'
} catch {
    $summary.status = 'failed'
    throw
} finally {
    try {
        Invoke-Adb @('shell', 'am', 'force-stop', $package) | Out-Null
        $summary.fixture_stopped = $true
    } finally {
        Save-Summary
        Pop-Location
        foreach ($name in $previous.Keys) {
            if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
        }
    }
}
$summary.completed = $true
$summary.status = 'complete'
Save-Summary
Write-Output 'PASS: real Java/native exit reasons; disk replay, acknowledgement, scope isolation and force-stop exclusion.'
Write-Output 'Rebuild the ordinary debug APK before delivery: scripts/build_android.ps1 -NoPub -UseChinaMirror'
