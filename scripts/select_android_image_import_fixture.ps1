#requires -Version 7.0
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')][string]$RunId,
    [Parameter(Mandatory)][string]$DriverLog,
    [string]$ToolsRoot = 'D:\learning-planet-tools'
)
$ErrorActionPreference = 'Stop'
# This controller only touches two generated images on our dedicated API29 AVD.
$adb = Join-Path $ToolsRoot 'android-sdk/platform-tools/adb.exe'
$serial = 'emulator-5582'
$root = Split-Path -Parent $PSScriptRoot
$xmlPath = "/data/local/tmp/lp-image-import-$RunId.xml"
$folder = "lp-import-$RunId"
$reportPath = Join-Path $root "build/integration_results/image-import-controller-$RunId.json"
$report = [ordered]@{ run = $RunId; completed = $false; selected_count = 0; cancel_observed = $false; steps = @() }
function Adb([string[]]$Arguments) {
    $output = & $adb -s $serial @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ADB failed: $($Arguments[0])" }
    return ($output -join "`n").Trim()
}
function Read-Ui {
    # Remove the exact previous dump first: uiautomator can fail with null root.
    Adb @('shell', 'rm', '-f', $xmlPath) | Out-Null
    $dump = Adb @('shell', 'uiautomator', 'dump', $xmlPath)
    if ($dump -notmatch 'dumped to:') { return $null }
    return [xml](Adb @('shell', 'cat', $xmlPath))
}
function Wait-Ui([string]$XPath, [int]$Seconds = 30) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $doc = Read-Ui
        if ($null -ne $doc -and $null -ne $doc.SelectSingleNode($XPath)) { return $doc }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $until)
    throw "System picker did not reach expected state: $XPath"
}
function Tap-Node($Node, [switch]$Hold) {
    if ($null -eq $Node -or $Node.package -ne 'com.android.documentsui') { throw 'Refusing to interact outside the system picker.' }
    $bounds = [regex]::Match([string]$Node.bounds, '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
    if (-not $bounds.Success) { throw 'Missing picker bounds.' }
    $x = [int](([int]$bounds.Groups[1].Value + [int]$bounds.Groups[3].Value) / 2)
    $y = [int](([int]$bounds.Groups[2].Value + [int]$bounds.Groups[4].Value) / 2)
    if ($Hold) { Adb @('shell', 'input', 'swipe', "$x", "$y", "$x", "$y", '700') | Out-Null }
    else { Adb @('shell', 'input', 'tap', "$x", "$y") | Out-Null }
}
try {
    if ((Adb @('shell', 'getprop', 'ro.kernel.qemu')) -ne '1' -or
        (Adb @('shell', 'getprop', 'ro.build.version.sdk')) -ne '29' -or
        (Adb @('shell', 'getprop', 'ro.kernel.qemu.avd_name')) -ne 'learning_planet_api29' -or
        (Adb @('shell', 'getprop', 'sys.boot_completed')) -ne '1') {
        throw 'Controller requires the booted learning_planet_api29 AVD on emulator-5582.'
    }
    $until = [DateTime]::UtcNow.AddSeconds(300)
    do {
        $log = if (Test-Path -LiteralPath $DriverLog) { Get-Content -LiteralPath $DriverLog -Raw } else { '' }
        if ($log.Contains("NativeImages fixture run: $RunId") -and $log.Contains('LP_IMAGE_IMPORT_SELECT_TWO')) { break }
        Start-Sleep -Milliseconds 400
    } while ([DateTime]::UtcNow -lt $until)
    if (-not $log.Contains("NativeImages fixture run: $RunId") -or -not $log.Contains('LP_IMAGE_IMPORT_SELECT_TWO')) { throw 'Current fixture run did not request image selection.' }
    $doc = Wait-Ui "//node[@package='com.android.documentsui']"
    $folderTitle = "//node[@resource-id='android:id/title' and @text='$folder']"
    $first = "//node[starts-with(@content-desc,'LP_IMPORT_1.png,')]"
    $second = "//node[starts-with(@content-desc,'LP_IMPORT_2.png,')]"
    if ($null -eq $doc.SelectSingleNode($folderTitle) -or $null -eq $doc.SelectSingleNode($first)) {
        $doc = Wait-Ui "//node[@content-desc='Show roots']"
        Tap-Node $doc.SelectSingleNode("//node[@content-desc='Show roots']")
        $downloads = "//node[@resource-id='android:id/title' and @text='Downloads']"
        $doc = Wait-Ui $downloads
        Tap-Node $doc.SelectSingleNode($downloads)
        $doc = Wait-Ui $folderTitle
        Tap-Node $doc.SelectSingleNode($folderTitle)
    }
    $doc = Wait-Ui $first
    if ($null -eq $doc.SelectSingleNode($folderTitle) -or $null -eq $doc.SelectSingleNode($second)) { throw 'Expected fixture folder and both synthetic images.' }
    Tap-Node $doc.SelectSingleNode($first) -Hold
    $doc = Wait-Ui $second
    Tap-Node $doc.SelectSingleNode($second)
    $doc = Wait-Ui "//node[@resource-id='com.android.documentsui:id/action_bar_title' and @text='2 selected']"
    Tap-Node $doc.SelectSingleNode("//node[@resource-id='com.android.documentsui:id/action_menu_select']")
    $report.selected_count = 2
    $report.steps += 'Selected both synthetic images using DocumentsUI.'
    $until = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $log = Get-Content -LiteralPath $DriverLog -Raw
        if ($log.Contains('LP_IMAGE_IMPORT_CANCEL')) { break }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $until)
    if (-not $log.Contains('LP_IMAGE_IMPORT_CANCEL')) { throw 'App did not request cancellation verification.' }
    $doc = Wait-Ui "//node[@package='com.android.documentsui']"
    # Back is sent only while the picker owns the visible hierarchy.
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        if ($null -eq $doc.SelectSingleNode("//node[@package='com.android.documentsui']")) { break }
        Adb @('shell', 'input', 'keyevent', '4') | Out-Null
        $report.cancel_observed = $true
        $doc = Wait-Ui '//node[@package]'
    }
    if ($null -ne $doc.SelectSingleNode("//node[@package='com.android.documentsui']")) { throw 'Picker remained open after cancellation.' }
    $report.steps += 'Observed the second native picker and cancelled it.'
    $report.completed = $true
} finally {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $reportPath)) | Out-Null
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding utf8
    Adb @('shell', 'rm', '-f', $xmlPath) | Out-Null
}
Write-Output "Native image controller completed: $reportPath"
