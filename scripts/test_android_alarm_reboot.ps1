#requires -Version 7.0
param(
    [ValidateSet('emulator-5580')][string]$DeviceId = 'emulator-5580',
    [string]$ToolsRoot = 'D:\learning-planet-tools'
)
$ErrorActionPreference = 'Stop'
$adb = Join-Path $ToolsRoot 'android-sdk/platform-tools/adb.exe'
$projectRoot = Split-Path -Parent $PSScriptRoot
$output = Join-Path $projectRoot 'build/integration_results'
function Read-AlarmInstants {
    $dump = (& $adb -s $DeviceId shell dumpsys alarm 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { return @() }
    # Match pending alarms only, excluding cancellation history and wakeup stats.
    $pattern = '(?m)^\s*RTC_WAKEUP #\d+: Alarm\{[^\r\n]*origWhen (\d+)[^\r\n]*com\.learningplanet\.learning_planet\}\r?\n\s*tag=\*walarm\*:com\.learningplanet\.learning_planet/\.TaskAlarmReceiver\b'
    return @([regex]::Matches($dump, $pattern) | ForEach-Object { [long]$_.Groups[1].Value } | Sort-Object)
}
$before = @(Read-AlarmInstants)
if ($before.Count -ne 2) {
    throw 'Seed exactly two future alarms with test_android_app.ps1 -Scenario NotificationsGranted -KeepAlarmsForReboot first.'
}
$bootBefore = (& $adb -s $DeviceId shell settings get global boot_count).Trim()
if ($bootBefore -notmatch '^\d+$') { throw 'Could not read emulator boot count.' }
Write-Output "Rebooting dedicated $DeviceId with two future alarms."
& $adb -s $DeviceId reboot
if ($LASTEXITCODE -ne 0) { throw 'Emulator reboot failed.' }
$deadline = [DateTime]::UtcNow.AddMinutes(3)
$after = @()
$bootAfter = ''
do {
    Start-Sleep -Seconds 2
    $bootAfter = ((& $adb -s $DeviceId shell settings get global boot_count 2>$null) -join '').Trim()
    $completed = ((& $adb -s $DeviceId shell getprop sys.boot_completed 2>$null) -join '').Trim()
    if ($completed -eq '1' -and $bootAfter -match '^\d+$' -and [int]$bootAfter -gt [int]$bootBefore) {
        $after = @(Read-AlarmInstants)
        if (($after -join ',') -eq ($before -join ',')) { break }
    }
} while ([DateTime]::UtcNow -lt $deadline)
if (($after -join ',') -ne ($before -join ',')) { throw 'Future alarms were not restored with identical instants after a real reboot.' }
New-Item -ItemType Directory -Path $output -Force | Out-Null
@{
    platform = 'Android API36 AOSP emulator'
    backend = 'none'
    qualifies_for_device_acceptance = $false
    boot_count_before = [int]$bootBefore
    boot_count_after = [int]$bootAfter
    before = $before
    after = $after
    same_future_alarms_restored_without_opening_app = $true
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'notifications-reboot.json') -Encoding utf8
Write-Output 'PASS: two future alarms restored at identical instants without reopening the app.'
