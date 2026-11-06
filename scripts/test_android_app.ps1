#requires -Version 7.0
param(
    [string]$DeviceId = 'emulator-5580',
    [string]$DeviceLabel = 'AOSP API36 x86_64 emulator; WHPX; SwiftShader',
    [ValidateSet('TaskFlow', 'NotificationsGranted', 'NotificationsDenied', 'NativeOcr', 'NativeImages')]
    [string]$Scenario = 'TaskFlow',
    [string]$ToolsRoot = 'D:\learning-planet-tools',
    [ValidateRange(30, 1800)][int]$TestTimeoutSeconds = 180,
    [string]$ImageImportRun,
    [switch]$KeepAlarmsForReboot,
    [switch]$UseChinaMirror
)
$ErrorActionPreference = 'Stop'
if ($KeepAlarmsForReboot -and ($Scenario -ne 'NotificationsGranted' -or $DeviceId -ne 'emulator-5580')) {
    throw 'Reboot fixtures require NotificationsGranted on dedicated emulator-5580.'
}
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
$javaRoot = Join-Path $ToolsRoot ('jdk/jdk-' + $toolchain.jdk.version)
$sdkRoot = Join-Path $ToolsRoot 'android-sdk'
$flutter = Join-Path $ToolsRoot 'flutter/bin/flutter.bat'
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
    # Installs an integration-test entrypoint with the app's package ID. Use an
    # emulator or dedicated test device; it is not the distributable debug APK.
    $driver = 'test_driver/task_flow_driver.dart'
    $target = 'integration_test/task_flow_test.dart'
    $binaryArguments = @()
    $defines = @("--dart-define=TEST_DEVICE_LABEL=$DeviceLabel")
    if ($Scenario -eq 'NativeOcr') {
        $driver = 'test_driver/ocr_native_driver.dart'
        $target = 'integration_test/ocr_native_test.dart'
    }
    if ($Scenario -eq 'NativeImages') {
        if ($DeviceId -ne 'emulator-5582' -or $ImageImportRun -notmatch '^[0-9a-f-]{36}$') {
            throw 'NativeImages requires dedicated emulator-5582 and a unique -ImageImportRun matching its prepared fixtures.'
        }
        $driver = 'test_driver/image_import_native_driver.dart'
        $target = 'integration_test/image_import_native_test.dart'
        $defines += "--dart-define=TEST_IMAGE_IMPORT_RUN=$ImageImportRun"
        Write-Output "NativeImages fixture run: $ImageImportRun"
    }
    if ($Scenario -in @('NotificationsGranted', 'NotificationsDenied')) {
        # Permission mutation and global notification cleanup are restricted to
        # the dedicated emulator. Never change a connected user's phone here.
        if ($DeviceId -ne 'emulator-5580') { throw 'Notification scenarios require the dedicated emulator-5580.' }
        $driver = 'test_driver/notifications_driver.dart'
        $target = 'integration_test/notifications_test.dart'
        $permission = if ($Scenario -eq 'NotificationsGranted') { 'true' } else { 'false' }
        $defines += "--dart-define=TEST_NOTIFICATIONS_GRANTED=$permission"
        if ($KeepAlarmsForReboot) { $defines += '--dart-define=TEST_KEEP_ALARMS_FOR_REBOOT=true' }
        & $flutter build apk --profile --no-pub "--target=$target" --android-project-arg=kotlin.incremental=false @defines
        if ($LASTEXITCODE -ne 0) { throw 'Integration APK build failed.' }
        $binary = Join-Path $buildRoot 'build/app/outputs/flutter-apk/app-profile.apk'
        $adb = Join-Path $sdkRoot 'platform-tools/adb.exe'
        & $adb -s $DeviceId install -r $binary
        if ($LASTEXITCODE -ne 0) { throw 'Integration APK install failed.' }
        $operation = if ($permission -eq 'true') { 'grant' } else { 'revoke' }
        & $adb -s $DeviceId shell pm $operation com.learningplanet.learning_planet android.permission.POST_NOTIFICATIONS
        if ($LASTEXITCODE -ne 0) { throw 'Could not set emulator notification permission.' }
        $binaryArguments = @("--use-application-binary=$binary")
        # flutter drive normally uninstalls the app, removing persisted alarms.
        if ($KeepAlarmsForReboot) { $binaryArguments += '--keep-app-running' }
    }
    # Flutter's driver timeout is enabled together with failure screenshots.
    # It bounds the driver phase after app launch, not Gradle compilation.
    $failureScreens = Join-Path $buildRoot ('build/integration_results/driver-failures/' + $Scenario + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
    [IO.Directory]::CreateDirectory($failureScreens) | Out-Null
    & $flutter drive --no-dds --profile --no-pub "--device-id=$DeviceId" `
        "--timeout=$TestTimeoutSeconds" "--screenshot=$failureScreens" `
        "--driver=$driver" "--target=$target" @binaryArguments `
        --android-project-arg=kotlin.incremental=false @defines
    $result = $LASTEXITCODE
} finally {
    Pop-Location
    foreach ($name in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
    }
}
exit $result
