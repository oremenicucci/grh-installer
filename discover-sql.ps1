#Requires -Version 5.0
<#
.SYNOPSIS
  Descubre la instancia SQL Server de Sigma en la PC / red. Reporta hallazgos
  via heartbeat para que decidamos remotamente cómo seguir.

.DESCRIPTION
  Corre una vez por sync-bak.ps1 mientras config.json no tenga 'sql' configurado.
  Una vez que discover encuentra una instancia alcanzable, la guarda en
  config.sql y futuras corridas hacen la extracción directa.

  Lo que busca:
    1. Servicios Windows *SQL* locales (Get-Service)
    2. Puertos TCP 1433 o 1434 locales (listen)
    3. Prueba conexión a decenas de nombres posibles de instancia
    4. Archivos config de Sigma en Program Files / C:\Sigma (busca strings
       tipo 'DataSource=', 'Server=', 'ServerName=')

  Todo hallazgo se POSTea via heartbeat con event='discover_*'.
#>

param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDriveSync\config.json')
)

$ErrorActionPreference = 'Continue'

$InstallDir = Split-Path $ConfigPath -Parent
$LogDir     = Join-Path $InstallDir 'logs'
$LogFile    = Join-Path $LogDir 'discover.log'

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
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if (-not $cfg.heartbeat -or -not $cfg.heartbeat.url) { return }
        $body = @{
            client_id = $env:COMPUTERNAME
            event     = $Event
            status    = $Status
            details   = $Details
        } | ConvertTo-Json -Depth 8
        Invoke-WebRequest -Uri $cfg.heartbeat.url `
            -Method Post `
            -Headers @{ Authorization = "Bearer $($cfg.heartbeat.secret)" } `
            -ContentType 'application/json' `
            -Body $body -TimeoutSec 10 -UseBasicParsing | Out-Null
    } catch {
        Write-Log 'WARN' "hb fail: $($_.Exception.Message)"
    }
}

Write-Log 'INFO' '=== discover start ==='

# -----------------------------------------------------------------------------
# 1. Servicios Windows SQL locales
# -----------------------------------------------------------------------------
$sqlServices = @()
try {
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*SQL*' -or $_.DisplayName -like '*SQL Server*' } |
        ForEach-Object {
            $sqlServices += @{
                name        = $_.Name
                displayName = $_.DisplayName
                status      = "$($_.Status)"
            }
        }
} catch {}
Write-Log 'INFO' "services_sql=$($sqlServices.Count)"

# -----------------------------------------------------------------------------
# 2. Puertos TCP listening
# -----------------------------------------------------------------------------
$listenPorts = @()
try {
    $c = Get-NetTCPConnection -State Listen -LocalPort 1433 -ErrorAction SilentlyContinue
    if ($c) { $listenPorts += @{ port = 1433; local = $true } }
    $c = Get-NetTCPConnection -State Listen -LocalPort 1434 -ErrorAction SilentlyContinue
    if ($c) { $listenPorts += @{ port = 1434; local = $true } }
} catch {}

# -----------------------------------------------------------------------------
# 3. Nombres candidatos — intento de conexion
# -----------------------------------------------------------------------------
$candidates = @(
    'localhost', 'localhost\SQLEXPRESS', 'localhost\SIGMA', 'localhost\ZIGMA',
    '(local)', '.', '.\SQLEXPRESS',
    'Dataserver', 'Dataserver\SQLEXPRESS', 'Dataserver\SIGMA', 'Dataserver\ZIGMA',
    'Dataserver,1433', 'Dataserver\MSSQLSERVER',
    "$env:COMPUTERNAME", "$env:COMPUTERNAME\SQLEXPRESS", "$env:COMPUTERNAME\SIGMA"
)
# Sumar nombres de los servicios SQL descubiertos
foreach ($s in $sqlServices) {
    $n = $s.name
    if ($n -match '^MSSQL\$(.+)$') {
        $inst = $Matches[1]
        $candidates += "localhost\$inst"
        $candidates += "Dataserver\$inst"
        $candidates += "$env:COMPUTERNAME\$inst"
    }
}
$candidates = $candidates | Select-Object -Unique

$tried = @()
$working = $null
foreach ($srv in $candidates) {
    $result = @{ server = $srv; ok = $false; error = $null; version = $null }
    try {
        $c = New-Object System.Data.SqlClient.SqlConnection("Server=$srv;Integrated Security=true;Connection Timeout=3")
        $c.Open()
        $q = $c.CreateCommand()
        $q.CommandText = "SELECT @@VERSION"
        $ver = $q.ExecuteScalar()
        $c.Close()
        $result.ok = $true
        $result.version = ($ver -split "`n")[0]
        if (-not $working) { $working = $srv }
    } catch {
        $result.error = $_.Exception.Message.Split([char]10)[0].Trim()
    }
    $tried += $result
}

Write-Log 'INFO' "working_server=$working"

# -----------------------------------------------------------------------------
# 4. Buscar config files de Sigma con hints del server
# -----------------------------------------------------------------------------
$sigmaHints = @()
$searchDirs = @(
    'C:\Sigma', 'C:\ProgramData\Sigma',
    'C:\Program Files\Sigma', 'C:\Program Files (x86)\Sigma',
    'C:\Zigma', 'C:\Program Files\Zigma', 'C:\Program Files (x86)\Zigma'
)
foreach ($d in $searchDirs) {
    if (-not (Test-Path $d)) { continue }
    $configFiles = Get-ChildItem -Path $d -Recurse -File `
        -Include @('*.ini','*.cfg','*.config','*.xml','*.conf') -ErrorAction SilentlyContinue |
        Select-Object -First 30
    foreach ($f in $configFiles) {
        try {
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            foreach ($pattern in @(
                '(?i)(Server|DataSource|Data Source|ServerName)\s*=\s*([^\s;"''\n\r]+)',
                '(?i)SQL_?Server\s*=\s*([^\s;"''\n\r]+)'
            )) {
                foreach ($m in [regex]::Matches($content, $pattern)) {
                    $val = $m.Groups[$m.Groups.Count - 1].Value
                    if ($val -and $val.Length -lt 80 -and $val -notmatch '^\s*$') {
                        $sigmaHints += @{
                            file    = $f.FullName
                            match   = $val
                            context = $m.Value.Substring(0, [Math]::Min($m.Value.Length, 100))
                        }
                    }
                }
            }
        } catch {}
    }
}
$sigmaHints = $sigmaHints | Select-Object -Unique -Property match,file | Select-Object -First 20

# -----------------------------------------------------------------------------
# Reportar todo via heartbeat
# -----------------------------------------------------------------------------
$discoverStatus = if ($working) { 'ok' } else { 'warn' }
Send-Heartbeat -Event 'discover_done' -Status $discoverStatus -Details @{
    services_sql = $sqlServices
    listen_ports = $listenPorts
    tried_count  = $tried.Count
    working      = $working
    tried        = $tried
    sigma_hints  = $sigmaHints
    computername = $env:COMPUTERNAME
}

# Si encontramos uno que conecta, guardar en config.json
if ($working) {
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if (-not $cfg.sql) {
            $cfg | Add-Member -NotePropertyName sql -NotePropertyValue (@{
                server   = $working
                database = 'Zigma'
            })
        } else {
            $cfg.sql.server = $working
        }
        $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
        Write-Log 'INFO' "saved sql.server=$working a config.json"
    } catch {
        Write-Log 'WARN' "no pude guardar config: $($_.Exception.Message)"
    }
}

Write-Log 'INFO' '=== discover OK ==='
