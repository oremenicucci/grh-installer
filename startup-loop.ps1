#Requires -Version 5.0
<#
.SYNOPSIS
  Loop de sincronizacion que corre en la sesion interactiva de la usuaria
  (via Startup folder shortcut). Reemplaza a los Scheduled Tasks que
  fallaban por S4U sin credenciales de red.

.DESCRIPTION
  Arranca al login. Mutex global evita duplicados. Cada 30 min invoca
  sync-bak.ps1; cada 6h invoca update.ps1. Silencioso.

  Como corre en contexto INTERACTIVO del usuario, tiene acceso a:
    - UNC shares (\\Dataserver\...)
    - Credenciales de red cacheadas
    - SQL Server via Integrated Security

  Sobrevive: bloqueo de pantalla, cambio de red, sleep/wake.
  Muere al: logoff, shutdown, kill manual.
#>

$ErrorActionPreference = 'Continue'

$InstallDir   = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDriveSync'
$SyncScript   = Join-Path $InstallDir 'sync-bak.ps1'
$UpdateScript = Join-Path $InstallDir 'update.ps1'
$LogDir       = Join-Path $InstallDir 'logs'
$LogFile      = Join-Path $LogDir 'startup-loop.log'

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "[$ts] [$Level] $Message" -Encoding UTF8
}

# Rotacion log
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Move-Item $LogFile (Join-Path $LogDir "startup-loop-$stamp.log")
}

# Mutex global para prevenir duplicados (si el usuario logea rapido / shortcut doble)
$mutex = New-Object System.Threading.Mutex($false, 'Global\GRH_OneDriveSync_Loop')
$acquired = $false
try {
    $acquired = $mutex.WaitOne(0)
} catch {}
if (-not $acquired) {
    Write-Log 'INFO' 'Ya corre otra instancia, saliendo'
    exit 0
}

Write-Log 'INFO' "=== startup-loop start (user=$env:USERNAME pc=$env:COMPUTERNAME) ==="

try {
    $lastUpdate = [datetime]::MinValue

    while ($true) {
        # --- Sync cada iteracion ---
        if (Test-Path $SyncScript) {
            try {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $SyncScript 2>&1 |
                    ForEach-Object { Write-Log 'SYNC' $_ }
            } catch {
                Write-Log 'ERROR' "sync crashed: $($_.Exception.Message)"
            }
        } else {
            Write-Log 'WARN' "sync-bak.ps1 no existe aun en $SyncScript"
        }

        # --- Update check cada 6h ---
        if ((Get-Date) - $lastUpdate -gt (New-TimeSpan -Hours 6)) {
            if (Test-Path $UpdateScript) {
                try {
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $UpdateScript 2>&1 |
                        ForEach-Object { Write-Log 'UPDATE' $_ }
                } catch {
                    Write-Log 'ERROR' "update crashed: $($_.Exception.Message)"
                }
            }
            $lastUpdate = Get-Date
        }

        # Sleep 30 min
        Start-Sleep -Seconds 1800
    }
}
finally {
    if ($acquired) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    $mutex.Dispose()
    Write-Log 'INFO' '=== startup-loop end ==='
}
