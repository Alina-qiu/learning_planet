#requires -Version 7.0
param(
    [ValidateSet('start','status','mail','stop')][string]$Command = 'start',
    [string]$Email,
    [string]$ToolsRoot = 'D:\learning-planet-tools',
    [string]$NodeBinary = (Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe')
)
$ErrorActionPreference = 'Stop'
$paths = @{
    POSTGREST_BIN = (Join-Path $ToolsRoot 'postgrest-16.2/postgrest.exe')
    GOTRUE_BIN = (Join-Path $ToolsRoot 'supabase-auth-source/auth-2.196.0/auth.exe')
    STORAGE_SOURCE = (Join-Path $ToolsRoot 'supabase-storage-source/storage-1.72.1')
    MINIO_BIN = (Join-Path $ToolsRoot 'minio-2025-09-07/minio.exe')
}
if (-not (Test-Path -LiteralPath $NodeBinary -PathType Leaf)) { throw 'Set -NodeBinary to Node24 or newer.' }
if ($Command -eq 'mail' -and -not $Email) { throw 'Specify -Email parent@example.test.' }
$previous = @{}
Push-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
try {
    foreach ($name in $paths.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $paths[$name], 'Process')
        if ($Command -eq 'start' -and -not (Test-Path -LiteralPath $paths[$name])) { throw "Missing local service: $name. See docs/STORAGE_INTEGRATION.md." }
    }
    & $NodeBinary scripts/local_backend.mjs $Command $Email
    $resultCode = $LASTEXITCODE
} finally {
    foreach ($name in $previous.Keys) {
        if ($null -eq $previous[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
        }
    }
    Pop-Location
}
exit $resultCode
