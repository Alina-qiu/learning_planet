#requires -Version 7.0
param([string]$ToolsRoot = 'D:\learning-planet-tools', [string]$NodeBinary, [switch]$NoPub, [switch]$UseChinaMirror)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$output = Join-Path $projectRoot 'build/app/outputs/flutter-apk'
$ordinary = Join-Path $output 'app-debug.apk'
$local = Join-Path $output 'app-local-debug.apk'
$backup = Join-Path $projectRoot ('.dart_tool/local-backend/apk-backup-' + [Guid]::NewGuid().ToString('N'))
$hadApk = Test-Path -LiteralPath $ordinary -PathType Leaf
$hadDigest = Test-Path -LiteralPath ($ordinary + '.sha256') -PathType Leaf
$serviceArguments = @{ Command='status'; ToolsRoot=$ToolsRoot }
if ($NodeBinary) { $serviceArguments['NodeBinary']=$NodeBinary }
& (Join-Path $PSScriptRoot 'local_backend.ps1') @serviceArguments
if ($LASTEXITCODE -ne 0) { throw 'Start scripts/local_backend.ps1 before building this session.' }
New-Item -ItemType Directory -Path $backup | Out-Null
if ($hadApk) { Copy-Item -LiteralPath $ordinary -Destination (Join-Path $backup 'app-debug.apk') }
if ($hadDigest) { Copy-Item -LiteralPath ($ordinary + '.sha256') -Destination (Join-Path $backup 'app-debug.apk.sha256') }
try {
    & (Join-Path $PSScriptRoot 'build_android.ps1') -ToolsRoot $ToolsRoot -NoPub:$NoPub -UseChinaMirror:$UseChinaMirror -DartDefinesFile (Join-Path $projectRoot '.dart_tool/local-backend/defines.json')
    if ($LASTEXITCODE -ne 0) { throw 'Local debug APK build failed.' }
    Copy-Item -LiteralPath $ordinary -Destination $local
    & (Join-Path $PSScriptRoot 'verify_android_apk.ps1') -ApkPath $local
    Write-Output "Local debug APK: $local"
} finally {
    if ($hadApk) { Copy-Item -LiteralPath (Join-Path $backup 'app-debug.apk') -Destination $ordinary }
    elseif (Test-Path -LiteralPath $ordinary) { Remove-Item -LiteralPath $ordinary }
    if ($hadDigest) { Copy-Item -LiteralPath (Join-Path $backup 'app-debug.apk.sha256') -Destination ($ordinary + '.sha256') }
    elseif (Test-Path -LiteralPath ($ordinary + '.sha256')) { Remove-Item -LiteralPath ($ordinary + '.sha256') }
    # Only files created above are removed; a failed restore keeps the backup.
    foreach ($name in @('app-debug.apk','app-debug.apk.sha256')) {
        $file = Join-Path $backup $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    Remove-Item -LiteralPath $backup
}
