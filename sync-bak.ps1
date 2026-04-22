#Requires -Version 5.0
<#
.SYNOPSIS
  Sube el .zip/.bak mas reciente de la carpeta source a Cloudflare R2.
  Corre cada 30 min via Task Scheduler, silencioso.

.DESCRIPTION
  - Lee config.json (source + R2 creds).
  - Encuentra el archivo .zip/.bak mas reciente en source.
  - Hash SHA256 contra last-uploaded.json para idempotencia.
  - aws s3 cp directo desde source (no copia local intermedia).
  - Limpia objetos R2 >7 dias post-upload.
  - Logs rotativos en %LOCALAPPDATA%\Microsoft\OneDriveSync\logs\sync.log.
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

# Rotacion: >1MB renombra con timestamp
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Move-Item $LogFile (Join-Path $LogDir "sync-$stamp.log")
}
Get-ChildItem -Path $LogDir -Filter 'sync-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Log 'INFO' '=== sync start ==='

try {
    if (-not (Test-Path $ConfigPath)) { throw "No existe config: $ConfigPath" }
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $source = $cfg.source
    $r2 = $cfg.r2
    if (-not $source) { throw 'config.json: falta source' }
    if (-not $r2 -or -not $r2.endpoint -or -not $r2.bucket -or -not $r2.access_key_id -or -not $r2.secret_access_key) {
        throw 'config.json: falta config r2.*'
    }

    Write-Log 'INFO' "source=$source bucket=$($r2.bucket)"

    if (-not (Test-Path $source)) { throw "source no existe: $source" }

    # Resolver aws.exe
    $awsExe = (Get-Command aws -ErrorAction SilentlyContinue).Source
    if (-not $awsExe -and (Test-Path 'C:\Program Files\Amazon\AWSCLIV2\aws.exe')) {
        $awsExe = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
    }
    if (-not $awsExe) { throw 'aws-cli no esta en PATH' }

    # Encontrar mas reciente
    $latest = Get-ChildItem -Path $source -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.zip','.bak') } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        Write-Log 'WARN' "No .zip/.bak en $source"
        exit 0
    }

    Write-Log 'INFO' "file=$($latest.Name) mod=$($latest.LastWriteTime) size_mb=$([math]::Round($latest.Length / 1MB, 1))"

    $sourceHash = (Get-FileHash -Path $latest.FullName -Algorithm SHA256).Hash

    # Idempotencia
    if (Test-Path $LastUploadedFile) {
        $last = Get-Content $LastUploadedFile -Raw | ConvertFrom-Json
        if ($last.hash -eq $sourceHash -and $last.name -eq $latest.Name) {
            Write-Log 'INFO' 'same hash, skip'
            exit 0
        }
    }

    $s3Uri = "s3://$($r2.bucket)/$($latest.Name)"
    Write-Log 'INFO' "uploading to $s3Uri"

    $env:AWS_ACCESS_KEY_ID     = $r2.access_key_id
    $env:AWS_SECRET_ACCESS_KEY = $r2.secret_access_key
    $env:AWS_DEFAULT_REGION    = 'auto'

    try {
        & $awsExe s3 cp $latest.FullName $s3Uri --endpoint-url $r2.endpoint --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "aws s3 cp exit=$LASTEXITCODE" }

        Write-Log 'INFO' "uploaded OK ($([math]::Round($latest.Length / 1MB, 1)) MB)"

        # Guardar estado
        $state = @{
            name     = $latest.Name
            hash     = $sourceHash
            uploaded = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
            size_mb  = [math]::Round($latest.Length / 1MB, 1)
        }
        $state | ConvertTo-Json | Set-Content $LastUploadedFile -Encoding UTF8

        # Rotacion R2: borrar >7 dias (excepto el actual)
        try {
            $cutoff = (Get-Date).AddDays(-7).ToString('yyyy-MM-ddTHH:mm:ssZ')
            $jsonOut = & $awsExe s3api list-objects-v2 --bucket $r2.bucket --endpoint-url $r2.endpoint --output json 2>$null
            if ($LASTEXITCODE -eq 0 -and $jsonOut) {
                $objects = ($jsonOut | ConvertFrom-Json).Contents
                foreach ($obj in $objects) {
                    if ($obj.Key -eq $latest.Name) { continue }
                    if ($obj.LastModified -lt $cutoff) {
                        Write-Log 'INFO' "rotate del: $($obj.Key)"
                        & $awsExe s3 rm "s3://$($r2.bucket)/$($obj.Key)" --endpoint-url $r2.endpoint --only-show-errors
                    }
                }
            }
        } catch {
            Write-Log 'WARN' "rotation fail (no critico): $($_.Exception.Message)"
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
    exit 1
}
