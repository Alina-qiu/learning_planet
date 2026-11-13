#requires -Version 7.0
param([string]$ApkPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build/app/outputs/flutter-apk/app-debug.apk'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$apk = Get-Item -LiteralPath $ApkPath
$archive = [IO.Compression.ZipFile]::OpenRead($apk.FullName)
try {
    $required = @(
        'assets/flutter_assets/kernel_blob.bin',
        'assets/flutter_assets/AssetManifest.bin',
        'assets/flutter_assets/FontManifest.json',
        'assets/flutter_assets/NativeAssetsManifest.json',
        'assets/flutter_assets/NOTICES.Z',
        'assets/flutter_assets/fonts/MaterialIcons-Regular.otf',
        'assets/flutter_assets/shaders/ink_sparkle.frag',
        'assets/flutter_assets/shaders/stretch_effect.frag'
    )
    foreach ($abi in @('arm64-v8a', 'armeabi-v7a', 'x86_64')) {
        $required += "lib/$abi/libsqlite3mc.so"
        $required += "lib/$abi/libflutter.so"
    }
    foreach ($entryName in $required) {
        $entry = $archive.GetEntry($entryName)
        if ($null -eq $entry -or $entry.Length -eq 0) {
            throw "APK is incomplete: missing $entryName. Rebuild Flutter generated outputs before delivery."
        }
    }
    $kernelReader = [IO.StreamReader]::new($archive.GetEntry('assets/flutter_assets/kernel_blob.bin').Open())
    try { $kernel = $kernelReader.ReadToEnd() }
    finally { $kernelReader.Dispose() }
    foreach ($testMarker in @('integration_test/notifications_test.dart', 'integration_test/task_flow_test.dart', 'integration_test/ocr_native_test.dart', 'integration_test/native_crash_test.dart', 'SYNTHETIC_PRIVATE_TASK_DO_NOT_SHOW', 'synthetic-held-remote', 'synthetic-printed-chinese-and-digits', 'integration_crash_phase')) {
        if ($kernel.Contains($testMarker)) { throw "Refusing to deliver an integration test APK: $testMarker" }
    }
    if (-not $kernel.Contains('initializeApp')) { throw 'Production initialization is missing from the debug APK.' }
    if ($kernel.Contains('integration_test/image_import_native_test.dart') -or $kernel.Contains('synthetic-native-gallery')) {
        throw 'Refusing to deliver the native gallery integration APK.'
    }
    if ($kernel.Contains('integration_test/native_anr_fixture.dart')) {
        throw 'Refusing to deliver the native ANR fixture APK.'
    }
    if ($kernel.Contains('integration_test/native_exit_fixture.dart')) {
        throw 'Refusing to deliver the native exit history fixture APK.'
    }
    $kernel = $null
    foreach ($dex in $archive.Entries | Where-Object { $_.FullName -match '^classes\d*\.dex$' }) {
        $dexReader = [IO.StreamReader]::new($dex.Open())
        try {
            $dexText = $dexReader.ReadToEnd()
            if ($dexText.Contains('LegacyAnrInstrumentation') -or $dexText.Contains('LegacyAnrFixtureActivity')) {
                throw 'Refusing to deliver an APK containing the ANR test instrumentation.'
            }
            if ($dexText.Contains('ExitHistoryFixtureActivity')) {
                throw 'Refusing to deliver an APK containing the exit history fault fixture.'
            }
        } finally { $dexReader.Dispose() }
    }
    $reader = [IO.StreamReader]::new($archive.GetEntry('assets/flutter_assets/NativeAssetsManifest.json').Open())
    try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable }
    finally { $reader.Dispose() }
    foreach ($target in @('android_arm', 'android_arm64', 'android_x64')) {
        $asset = $manifest['native-assets'][$target]['package:sqlite3/src/ffi/libsqlite3.g.dart']
        if ($asset.Count -ne 2 -or $asset[0] -ne 'absolute' -or $asset[1] -ne 'libsqlite3mc.so') {
            throw "APK native asset mapping is invalid for $target."
        }
    }
} finally {
    $archive.Dispose()
}
$digest = (Get-FileHash -LiteralPath $apk.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($apk.FullName + '.sha256'), ($digest + '  ' + $apk.Name + [Environment]::NewLine))
Write-Output "APK contents verified: three encrypted SQLite ABIs, Flutter assets, fonts and shaders; $($apk.Length) bytes; SHA-256 $digest"
