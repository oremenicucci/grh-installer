#Requires -Version 5.0
<#
.SYNOPSIS
  Auto-update remoto sin git. Re-descarga sync-bak.ps1, install.ps1 y
  update.ps1 desde GitHub raw. Si hash cambio, los reemplaza.
  Reporta heartbeat update_ok / update_error.
#>

$ErrorActionPreference = 'Stop'

$GITHUB_RAW = 'https://raw.githubusercontent.com/oremenicucci/grh-installer/main'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDriveSync'
$LogDir     = Join-Path $InstallDir 'logs'
$LogFile    = Join-Path $LogDir 'update.log'
$ConfigPath = Join-Path $InstallDir 'config.json'

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "[$ts] [$Level] $Message" -Encoding UTF8
}

function Send-Heartbeat {
    param(
        [Parameter(Mandatory)][string]$Event,
        [string]$Status = 'ok',
        [hashtable]$Details = @{}
    )
    try {
        if (-not (Test-Path $ConfigPath)) { return }
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if (-not $cfg.heartbeat -or -not $cfg.heartbeat.url) { return }
        $body = @{
            client_id = $env:COMPUTERNAME
            event     = $Event
            status    = $Status
            details   = $Details
        } | ConvertTo-Json -Depth 5
        Invoke-WebRequest -Uri $cfg.heartbeat.url `
            -Method Post `
            -Headers @{ Authorization = "Bearer $($cfg.heartbeat.secret)" } `
            -ContentType 'application/json' `
            -Body $body `
            -TimeoutSec 10 `
            -UseBasicParsing | Out-Null
    } catch {
        Write-Log 'WARN' "heartbeat fail: $($_.Exception.Message)"
    }
}

# Log rotation
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Move-Item $LogFile (Join-Path $LogDir "update-$stamp.log")
}
Get-ChildItem -Path $LogDir -Filter 'update-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Log 'INFO' '=== update start ==='

$files = @(
    @{ name = 'sync-bak.ps1'; path = (Join-Path $InstallDir 'sync-bak.ps1') }
    @{ name = 'update.ps1';   path = (Join-Path $InstallDir 'update.ps1') }
    @{ name = 'install.ps1';  path = (Join-Path $InstallDir 'install.ps1') }
)

$changed = @()
$installChanged = $false

try {
    foreach ($f in $files) {
        $url = "$GITHUB_RAW/$($f.name)"
        try {
            $remote = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30).Content

            $localHash = $null
            if (Test-Path $f.path) {
                $localHash = (Get-FileHash -Path $f.path -Algorithm SHA256).Hash
            }

            $tmpPath = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $tmpPath -Value $remote -NoNewline -Encoding UTF8
            $remoteHash = (Get-FileHash -Path $tmpPath -Algorithm SHA256).Hash

            if ($localHash -eq $remoteHash) {
                Write-Log 'INFO' "$($f.name): sin cambios"
                Remove-Item $tmpPath -Force
                continue
            }

            Move-Item -Path $tmpPath -Destination $f.path -Force
            Write-Log 'INFO' "$($f.name): actualizado"
            $changed += $f.name
            if ($f.name -eq 'install.ps1') { $installChanged = $true }
        } catch {
            Write-Log 'WARN' "$($f.name): fallo download ($($_.Exception.Message))"
        }
    }

    if ($installChanged) {
        Write-Log 'INFO' 'install.ps1 cambio -> re-ejecutando'
        $installPath = Join-Path $InstallDir 'install.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installPath *>&1 |
            ForEach-Object { Write-Log 'INFO' "install-rerun: $_" }
    }

    Send-Heartbeat -Event 'update_ok' -Details @{
        changed          = $changed
        install_rerun    = $installChanged
    }
    Write-Log 'INFO' '=== update OK ==='
    exit 0
}
catch {
    Write-Log 'ERROR' $_.Exception.Message
    Send-Heartbeat -Event 'update_error' -Status 'error' -Details @{
        error = $_.Exception.Message
    }
    exit 1
}
