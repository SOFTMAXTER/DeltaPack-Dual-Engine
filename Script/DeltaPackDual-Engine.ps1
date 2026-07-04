<#
.SYNOPSIS
    DeltaPack Dual-Engine: Generador de Paquetes de Despliegue Offline (WIM + REG) con Auditoria Automatica.

.DESCRIPTION
    Esta suite de ingenieria inversa automatizada realiza capturas diferenciales (Snapshots) del sistema
    para empaquetar aplicaciones en formatos portables y desplegables.
    
    CARACTERISTICAS PRINCIPALES:
    1. Arquitectura Hibrida (C# + PowerShell): Utiliza un nucleo C# compilado en tiempo de ejecucion para
       escaneo de alto rendimiento y saneamiento inteligente con Regex.
    2. Formato WIM (.wim): Genera contenedores WIM optimizados con maxima compresion.
    3. Abstraccion de Usuario: Detecta y neutraliza rutas absolutas (%USERPROFILE%) -> Users\Default.
    4. Sistema de Logging: Traza detallada con niveles de severidad y persistencia en disco.
    5. Robustez Windows 10/11: Exclusiones de telemetria, gestion de memoria GC y manejo de archivos bloqueados.
    6. Compatibilidad: PowerShell 5.1 y superior (PS7+ incluido). CIM nativo, sin dependencias WMI obsoletas.

.NOTES
    Version:        1.0.0
    Author:         SOFTMAXTER
    Engine:         Dual-Engine
    Compatibility:  PowerShell 5.1+, Windows 10/11

# ==============================================================================
# Copyright (C) 2026 SOFTMAXTER
#
# DUAL LICENSING NOTICE:
# This software is dual-licensed. By default, DeltaPack Dual-Engine is 
# distributed under the GNU General Public License v3.0 (GPLv3).
# 
# 1. OPEN SOURCE (GPLv3):
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details: <https://www.gnu.org/licenses/>.
#
# 2. COMMERCIAL LICENSE:
# If you wish to integrate this software into a proprietary/commercial product, 
# distribute it without revealing your source code, or require commercial 
# support, you must obtain a commercial license from the original author.
#
# Please contact softmaxter@hotmail.com for commercial licensing inquiries.
# ==============================================================================

#>

# =================================================================
#  Version del Script
# =================================================================
$script:Version = "1.0.0"

# =================================================================
#  Pre-Checks del Sistema
# =================================================================

# [FIX ISSUE #PS_VER] Verificar version minima de PowerShell
if ($PSVersionTable.PSVersion.Major -lt 5 -or
    ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Write-Warning "DeltaPack requiere PowerShell 5.1 o superior. Version actual: $($PSVersionTable.PSVersion)"
    Read-Host "Presiona Enter para salir."
    exit
}

# [FIX ISSUE #7] Verificar privilegios de Administrador - eliminado el Start-Sleep redundante post Read-Host
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Este script requiere privilegios de Administrador. Ejecute desde DeltaPackDual-Engine.exe."
    Read-Host "Presiona Enter para salir."
    exit
}

# [FIX ISSUE #13] Verificar que DISM.exe existe en el sistema antes de continuar
if (-not (Get-Command "dism.exe" -ErrorAction SilentlyContinue)) {
    Write-Warning "dism.exe no encontrado en el PATH del sistema. Este script requiere DISM (incluido en Windows 10/11)."
    Read-Host "Presiona Enter para salir."
    exit
}

try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
    $name    = "LongPathsEnabled"
    
    $regItem = Get-ItemProperty -Path $regPath -Name $name -ErrorAction SilentlyContinue
    
    if ($null -ne $regItem -and $regItem.$name -eq 1) {
        # Soporte de rutas largas ya habilitado - no se requiere accion.
    } else {
        Write-Host " -> [-] Habilitando soporte para rutas largas en el Registro..." -ForegroundColor Yellow
        Set-ItemProperty -Path $regPath -Name $name -Value 1 -Type DWord -Force -ErrorAction Stop
        Write-Host " -> [OK] Soporte habilitado exitosamente." -ForegroundColor Green
    }
} catch {
    Write-Warning "No se pudo comprobar o habilitar el soporte para rutas largas de forma automatica."
    Write-Host "Asegurate de que tu directorio temporal (Scratch_DIR) tenga una ruta muy corta (ej. C:\S) para evitar errores de extraccion con DISM." -ForegroundColor Yellow
}

# =================================================================
#  Motor Diferencial Dual C#
# =================================================================

$diffEngineCsPath = Join-Path $PSScriptRoot "DiffEngine.cs"
if (-not (Test-Path $diffEngineCsPath)) {
    Write-Warning "No se encontro DiffEngine.cs en: $diffEngineCsPath"
    Write-Warning "Este archivo contiene el motor diferencial y es obligatorio. Restauralo junto al script."
    Read-Host "Presiona Enter para salir."
    exit
}
Add-Type -Path $diffEngineCsPath

# =================================================================
#  SISTEMA DE LOGGING
# =================================================================
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','STEP')][string]$Level = 'INFO',
        [switch]$NoFile,
        [switch]$NoConsole
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # <-- NUEVO CONDICIONAL: Solo imprime si NO pasamos -NoConsole
    if (-not $NoConsole) { 
        $consoleColor = switch ($Level) {
            'INFO'    { 'Gray'   }
            'WARN'    { 'Yellow' }
            'ERROR'   { 'Red'    }
            'SUCCESS' { 'Green'  }
            'STEP'    { 'Cyan'   }
        }

        if ($Level -eq 'STEP') {
            Write-Host "`n[$timestamp] $Message" -ForegroundColor $consoleColor
        } else {
            Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $consoleColor
        }
    }

    # La escritura al archivo de texto se mantiene intacta
    if (-not $NoFile -and $script:LogPath -and (Test-Path (Split-Path $script:LogPath -Parent))) {
        $logLine = "[$timestamp] [$Level] $Message"
        $logLine | Out-File -FilePath $script:LogPath -Append -Encoding utf8
    }
}

# [MEJORA #4] Helper de espacio libre en disco (usado antes de invocar DISM, ver Fase 4).
function Get-FreeSpaceBytes {
    param([string]$Path)
    try {
        $qualifier = Split-Path -Path $Path -Qualifier -ErrorAction Stop
        $drive     = [System.IO.DriveInfo]::new($qualifier)
        return $drive.AvailableFreeSpace
    } catch {
        return -1
    }
}


# [PASO 3] Formatea bytes para resumenes visibles en consola/reporte.
function Format-ByteSize {
    param([Int64]$Bytes)

    if ($Bytes -lt 1KB) { return ("{0:N0} B" -f $Bytes) }
    if ($Bytes -lt 1MB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    return ("{0:N2} GB" -f ($Bytes / 1GB))
}

function Write-FileCopyProgress {
    param(
        [Parameter(Mandatory=$true)][int]$Processed,
        [Parameter(Mandatory=$true)][int]$Total,
        [Parameter(Mandatory=$true)][int]$Copied,
        [Parameter(Mandatory=$true)][Int64]$Bytes,
        [AllowNull()][string]$CurrentFile,
        [switch]$Completed
    )

    if ($Total -le 0) { return }

    if ($Completed) {
        Write-Progress -Activity "Copiando archivos al Staging" -Completed
        Write-Host (" -> Copia finalizada: {0:N0}/{1:N0} archivo(s) copiado(s) | {2}" -f `
            $Copied, $Total, (Format-ByteSize -Bytes $Bytes)) -ForegroundColor DarkGray
        return
    }

    $safeProcessed = [math]::Max(0, [math]::Min($Processed, $Total))
    $percent       = [math]::Min(100, [math]::Round(($safeProcessed / [double]$Total) * 100, 1))
    $leaf          = if ([string]::IsNullOrWhiteSpace($CurrentFile)) { "Preparando..." } else { Split-Path $CurrentFile -Leaf }
    $status        = "{0:N0}/{1:N0} ({2:N1}%) | Copiados: {3:N0} | {4}" -f `
        $safeProcessed, $Total, $percent, $Copied, (Format-ByteSize -Bytes $Bytes)

    Write-Progress -Activity "Copiando archivos al Staging" -Status "$status | $leaf" -PercentComplete $percent
}

function Get-RegFileMetrics {
    param([Parameter(Mandatory=$true)][string]$Path)

    [int]$keySections   = 0
    [int]$valueEntries  = 0
    [int]$deletedKeys   = 0
    [int]$deletedValues = 0

    if (Test-Path -LiteralPath $Path) {
        $stream = $null
        try {
            $stream = [System.IO.StreamReader]::new($Path, [System.Text.Encoding]::Unicode)
            while ($null -ne ($line = $stream.ReadLine())) {
                $line = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($line)) { continue }

                if ($line.StartsWith("[-")) {
                    $deletedKeys++
                } elseif ($line.StartsWith("[")) {
                    $keySections++
                } elseif ($line -match '^(".*"|@)=-$') {
                    $deletedValues++
                } elseif ($line -match '^(".*"|@)=') {
                    $valueEntries++
                }
            }
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }

    return [pscustomobject][ordered]@{
        KeySections   = $keySections
        ValueEntries  = $valueEntries
        DeletedKeys   = $deletedKeys
        DeletedValues = $deletedValues
        TotalEntries  = ($keySections + $valueEntries + $deletedKeys + $deletedValues)
    }
}

function Get-FileScanMetricsSnapshot {
    param(
        [AllowNull()]$Engine,
        [string]$Phase = ""
    )

    $m = $null
    if ($null -ne $Engine -and $null -ne $Engine.ScanMetrics) {
        $m = $Engine.ScanMetrics
    }

    if ($null -eq $m) {
        return [pscustomobject][ordered]@{
            phase = $Phase
            filesDiscovered = 0
            filesIndexed = 0
            filesHashed = 0
            filesByMetadata = 0
            filesLegacy = 0
            filesFallbackSize = 0
            filesSkipped = 0
            filesSkippedByExclusion = 0
            filesSkippedByReparsePoint = 0
            filesSkippedByAccessDenied = 0
            filesSkippedByIoError = 0
            filesSkippedByOtherError = 0
            directoriesDiscovered = 0
            directoriesScanned = 0
            directoriesSkipped = 0
            directoriesSkippedByExclusion = 0
            directoriesSkippedByReparsePoint = 0
            directoriesSkippedByAccessDenied = 0
            directoriesSkippedByIoError = 0
            directoriesSkippedByOtherError = 0
            hashBytesRead = 0
            hashBytesReadLabel = (Format-ByteSize -Bytes 0)
            elapsedMilliseconds = 0
            elapsed = "00:00:00.000"
        }
    }

    $elapsedMs = [int64]$m.ElapsedMilliseconds
    $elapsedTs = [TimeSpan]::FromMilliseconds([double]$elapsedMs)
    return [pscustomobject][ordered]@{
        phase = $Phase
        filesDiscovered = [int64]$m.FilesDiscovered
        filesIndexed = [int64]$m.FilesIndexed
        filesHashed = [int64]$m.FilesHashed
        filesByMetadata = [int64]$m.FilesByMetadata
        filesLegacy = [int64]$m.FilesLegacy
        filesFallbackSize = [int64]$m.FilesFallbackSize
        filesSkipped = [int64]$m.FilesSkipped
        filesSkippedByExclusion = [int64]$m.FilesSkippedByExclusion
        filesSkippedByReparsePoint = [int64]$m.FilesSkippedByReparsePoint
        filesSkippedByAccessDenied = [int64]$m.FilesSkippedByAccessDenied
        filesSkippedByIoError = [int64]$m.FilesSkippedByIoError
        filesSkippedByOtherError = [int64]$m.FilesSkippedByOtherError
        directoriesDiscovered = [int64]$m.DirectoriesDiscovered
        directoriesScanned = [int64]$m.DirectoriesScanned
        directoriesSkipped = [int64]$m.DirectoriesSkipped
        directoriesSkippedByExclusion = [int64]$m.DirectoriesSkippedByExclusion
        directoriesSkippedByReparsePoint = [int64]$m.DirectoriesSkippedByReparsePoint
        directoriesSkippedByAccessDenied = [int64]$m.DirectoriesSkippedByAccessDenied
        directoriesSkippedByIoError = [int64]$m.DirectoriesSkippedByIoError
        directoriesSkippedByOtherError = [int64]$m.DirectoriesSkippedByOtherError
        hashBytesRead = [int64]$m.HashBytesRead
        hashBytesReadLabel = (Format-ByteSize -Bytes ([int64]$m.HashBytesRead))
        elapsedMilliseconds = $elapsedMs
        elapsed = ("{0:hh\:mm\:ss\.fff}" -f $elapsedTs)
    }
}

function Write-FileScanMetricsSummary {
    param(
        [Parameter(Mandatory=$true)]$Metrics,
        [string]$Label = "Escaneo"
    )

    Write-Log ("Metricas de {0}: {1:N0} archivo(s) indexado(s) | SHA256: {2:N0} | META: {3:N0} | legado: {4:N0} | fallback: {5:N0} | omitidos: {6:N0} | directorios: {7:N0} | tiempo: {8}." -f `
        $Label,
        $Metrics.filesIndexed,
        $Metrics.filesHashed,
        $Metrics.filesByMetadata,
        $Metrics.filesLegacy,
        $Metrics.filesFallbackSize,
        $Metrics.filesSkipped,
        $Metrics.directoriesScanned,
        $Metrics.elapsed) -Level INFO

    if (($Metrics.filesSkipped -gt 0) -or ($Metrics.directoriesSkipped -gt 0)) {
        Write-Log ("Omisiones de {0}: archivos omitidos {1:N0} (exclusion {2:N0}, reparse {3:N0}, acceso denegado {4:N0}, I/O {5:N0}, otros {6:N0}); directorios omitidos {7:N0} (exclusion {8:N0}, reparse {9:N0}, acceso denegado {10:N0}, I/O {11:N0}, otros {12:N0})." -f `
            $Label,
            $Metrics.filesSkipped,
            $Metrics.filesSkippedByExclusion,
            $Metrics.filesSkippedByReparsePoint,
            $Metrics.filesSkippedByAccessDenied,
            $Metrics.filesSkippedByIoError,
            $Metrics.filesSkippedByOtherError,
            $Metrics.directoriesSkipped,
            $Metrics.directoriesSkippedByExclusion,
            $Metrics.directoriesSkippedByReparsePoint,
            $Metrics.directoriesSkippedByAccessDenied,
            $Metrics.directoriesSkippedByIoError,
            $Metrics.directoriesSkippedByOtherError) -Level INFO
    }
}


function Get-PercentValue {
    param(
        [double]$Numerator,
        [double]$Denominator
    )

    if ($Denominator -le 0) { return 0.0 }
    return [math]::Round(($Numerator / $Denominator) * 100.0, 1)
}

function Add-ScanDiagnosticFinding {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyCollection()]
        [ValidateNotNull()]
        [System.Collections.Generic.List[object]]$Findings,

        [ValidateSet("OK", "INFO", "WARN")]
        [string]$Level,

        [Parameter(Mandatory=$true)]
        [string]$Title,

        [Parameter(Mandatory=$true)]
        [string]$Detail,

        [string]$Recommendation = ""
    )

    $Findings.Add([pscustomobject][ordered]@{
        level          = $Level
        title          = $Title
        detail         = $Detail
        recommendation = $Recommendation
    }) | Out-Null
}

function Get-ScanHealthDiagnostic {
    param(
        [Parameter(Mandatory=$true)]$PreMetrics,
        [Parameter(Mandatory=$true)]$PostMetrics,
        [int64]$HashThresholdBytes = 0,
        [int]$EffectiveParallelism = 1
    )

    $findings = New-Object 'System.Collections.Generic.List[object]'

    $postObservedFiles = [int64]($PostMetrics.filesIndexed + $PostMetrics.filesSkipped)
    $postIndexed       = [int64]$PostMetrics.filesIndexed
    $postSkipped       = [int64]$PostMetrics.filesSkipped
    $postHashed        = [int64]$PostMetrics.filesHashed
    $postMetadata      = [int64]$PostMetrics.filesByMetadata
    $postLegacy        = [int64]$PostMetrics.filesLegacy
    $postFallback      = [int64]$PostMetrics.filesFallbackSize
    $postHashBytes     = [int64]$PostMetrics.hashBytesRead

    $hashedPct   = Get-PercentValue -Numerator $postHashed   -Denominator $postIndexed
    $metadataPct = Get-PercentValue -Numerator $postMetadata -Denominator $postIndexed
    $skippedPct  = Get-PercentValue -Numerator $postSkipped  -Denominator $postObservedFiles

    $fileAccessDenied  = [int64]$PostMetrics.filesSkippedByAccessDenied
    $dirAccessDenied   = [int64]$PostMetrics.directoriesSkippedByAccessDenied
    $accessDeniedTotal = $fileAccessDenied + $dirAccessDenied

    $fileIoErrors      = [int64]$PostMetrics.filesSkippedByIoError
    $dirIoErrors       = [int64]$PostMetrics.directoriesSkippedByIoError
    $ioErrorTotal      = $fileIoErrors + $dirIoErrors

    $fileOtherErrors   = [int64]$PostMetrics.filesSkippedByOtherError
    $dirOtherErrors    = [int64]$PostMetrics.directoriesSkippedByOtherError
    $otherErrorTotal   = $fileOtherErrors + $dirOtherErrors

    $fileReparse       = [int64]$PostMetrics.filesSkippedByReparsePoint
    $dirReparse        = [int64]$PostMetrics.directoriesSkippedByReparsePoint
    $reparseTotal      = $fileReparse + $dirReparse

    if ($HashThresholdBytes -le 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "Modo legado activo" `
            -Detail "El snapshot de archivos esta usando LastWriteTimeUtc-Length. Este modo es rapido, pero puede producir falsos positivos cuando Windows toca timestamps sin cambiar contenido." `
            -Recommendation "Usa un umbral SHA256 hibrido, por ejemplo 512 KB o 1 MB, para reducir ruido del sistema operativo."
    } elseif ($postIndexed -eq 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "No se indexaron archivos" `
            -Detail "El snapshot final no contiene archivos indexados. Puede indicar rutas de monitoreo vacias, permisos insuficientes o exclusiones demasiado agresivas." `
            -Recommendation "Revisa DirsToMonitor, la matriz DeltaPack.Exclusions.json y los permisos de lectura."
    } elseif ($hashedPct -ge 70) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "OK" `
            -Title "Cobertura SHA256 alta" `
            -Detail ("{0:N1}% de los archivos indexados fueron firmados por contenido. La deteccion es resistente a ruido de timestamps." -f $hashedPct) `
            -Recommendation "Mantener el umbral actual salvo que el escaneo sea demasiado lento."
    } elseif ($hashedPct -ge 25) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Cobertura SHA256 mixta" `
            -Detail ("{0:N1}% de archivos por SHA256 y {1:N1}% por metadata. Es un balance razonable entre precision y velocidad." -f $hashedPct, $metadataPct) `
            -Recommendation "Mantener el umbral actual. Si observas falsos positivos en Program Files, prueba subirlo a 1 MB."
    } else {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "Cobertura SHA256 baja" `
            -Detail ("Solo {0:N1}% de los archivos indexados fueron firmados por contenido; la mayoria depende de metadata." -f $hashedPct) `
            -Recommendation "Si el delta incluye demasiado ruido por timestamps, sube el umbral a 1 MB o 2 MB."
    }

    if ($skippedPct -gt 15) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "Alto porcentaje de omisiones" `
            -Detail ("Se omitio {0:N1}% de los archivos observados durante el snapshot final." -f $skippedPct) `
            -Recommendation "Revisa exclusiones y permisos; si son carpetas de sistema esperadas, documentalo como ruido normal."
    } elseif ($skippedPct -gt 5) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Omisiones moderadas" `
            -Detail ("Se omitio {0:N1}% de los archivos observados. Puede ser normal si hay muchas rutas excluidas." -f $skippedPct) `
            -Recommendation "Verifica el detalle de omisiones en el manifest JSON."
    } else {
        Add-ScanDiagnosticFinding -Findings $findings -Level "OK" `
            -Title "Omisiones bajas" `
            -Detail ("Solo {0:N1}% de los archivos observados fue omitido." -f $skippedPct) `
            -Recommendation "Sin accion necesaria."
    }

    if ($accessDeniedTotal -gt 0) {
        $accessLevel = "WARN"
        $accessTitle = "Acceso denegado durante el escaneo"
        $accessRecommendation = "Ejecuta como Administrador y revisa si antivirus, servicios o ACLs bloquean rutas relevantes."

        if ($fileAccessDenied -gt 0 -and $dirAccessDenied -gt 0) {
            $accessDetail = ("{0:N0} archivo(s) y {1:N0} directorio(s) fueron omitidos por permisos." -f $fileAccessDenied, $dirAccessDenied)
        } elseif ($fileAccessDenied -gt 0) {
            $accessTitle = "Archivos con acceso denegado"
            $accessDetail = ("{0:N0} archivo(s) fueron omitidos por permisos." -f $fileAccessDenied)
        } else {
            $accessLevel = "INFO"
            $accessTitle = "Directorios con acceso denegado"
            $accessDetail = ("{0:N0} directorio(s) fueron omitidos por permisos; 0 archivos fueron omitidos por acceso denegado." -f $dirAccessDenied)
            $accessRecommendation = "Normal en algunas rutas protegidas de Windows. Revisa solo si esperabas capturar contenido dentro de esos directorios."
        }

        Add-ScanDiagnosticFinding -Findings $findings -Level $accessLevel `
            -Title $accessTitle `
            -Detail $accessDetail `
            -Recommendation $accessRecommendation
    }

    if ($postFallback -gt 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "Fallback por tamano usado" `
            -Detail ("{0:N0} archivo(s) no pudieron leerse completamente y se firmaron solo por tamano." -f $postFallback) `
            -Recommendation "Revisa si esos archivos estaban bloqueados durante la captura; considera cerrar la app o usar VSS para esa ruta."
    }

    if (($ioErrorTotal + $otherErrorTotal) -gt 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "Errores de lectura detectados" `
            -Detail ("I/O: {0:N0} total (archivos {1:N0}, directorios {2:N0}); otros errores: {3:N0} total (archivos {4:N0}, directorios {5:N0})." -f $ioErrorTotal, $fileIoErrors, $dirIoErrors, $otherErrorTotal, $fileOtherErrors, $dirOtherErrors) `
            -Recommendation "Revisa disco, rutas largas, archivos bloqueados y permisos antes de confiar en el delta."
    }

    if ($reparseTotal -gt 0) {
        if ($fileReparse -gt 0 -and $dirReparse -gt 0) {
            $reparseDetail = ("{0:N0} archivo(s) y {1:N0} directorio(s)/junction(s) fueron omitidos para evitar duplicados o recursion fuera del arbol." -f $fileReparse, $dirReparse)
        } elseif ($fileReparse -gt 0) {
            $reparseDetail = ("{0:N0} archivo(s) con reparse point fueron omitidos para evitar contenido indirecto o no estable." -f $fileReparse)
        } else {
            $reparseDetail = ("{0:N0} directorio(s)/junction(s) fueron omitidos para evitar duplicados o recursion fuera del arbol." -f $dirReparse)
        }

        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Reparse points omitidos" `
            -Detail $reparseDetail `
            -Recommendation "Normal en Windows; no requiere accion salvo que esperabas capturar el destino real del enlace."
    }

    if ([int64]$PostMetrics.elapsedMilliseconds -gt 600000) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "Escaneo lento" `
            -Detail ("El snapshot final tardo {0}." -f $PostMetrics.elapsed) `
            -Recommendation "Baja el umbral SHA256 a 256 KB, reduce rutas monitoreadas o usa un paralelismo mayor si el disco es SSD."
    } elseif ([int64]$PostMetrics.elapsedMilliseconds -gt 180000) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Escaneo moderadamente largo" `
            -Detail ("El snapshot final tardo {0}." -f $PostMetrics.elapsed) `
            -Recommendation "Si el tiempo es aceptable, mantener. Si no, baja el umbral SHA256 o acota DirsToMonitor."
    }

    if ($postHashBytes -gt 5GB) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Lectura SHA256 intensiva" `
            -Detail ("Se leyeron {0} para calcular hashes." -f $PostMetrics.hashBytesReadLabel) `
            -Recommendation "Si el escaneo tarda demasiado, baja el umbral a 256 KB o 512 KB."
    }

    $preIndexed = [int64]$PreMetrics.filesIndexed
    if ($preIndexed -gt 0 -and $postIndexed -gt 0) {
        $deltaIndexed = $postIndexed - $preIndexed
        $deltaPct = Get-PercentValue -Numerator ([math]::Abs($deltaIndexed)) -Denominator $preIndexed
        if ($deltaPct -gt 50) {
            Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
                -Title "Cambio grande en volumen indexado" `
                -Detail ("El snapshot final tiene {0:N0} archivo(s) indexados vs {1:N0} iniciales ({2:N1}% de diferencia)." -f $postIndexed, $preIndexed, $deltaPct) `
                -Recommendation "Puede ser normal en instalaciones grandes; revisa que el delta no incluya caches o rutas no deseadas."
        }
    }

    $warnCount = @($findings | Where-Object { $_.level -eq "WARN" }).Count
    $infoCount = @($findings | Where-Object { $_.level -eq "INFO" }).Count
    $okCount   = @($findings | Where-Object { $_.level -eq "OK" }).Count

    $overallLevel = "OK"
    $overallText  = "Sano"
    if ($warnCount -gt 0) {
        $overallLevel = "WARN"
        $overallText  = "Revisar"
    } elseif ($infoCount -gt 0) {
        $overallLevel = "INFO"
        $overallText  = "Aceptable con observaciones"
    }

    $thresholdLabel = if ($HashThresholdBytes -le 0) { "Legado LastWriteTimeUtc-Length" } else { "SHA256 < $(Format-ByteSize -Bytes $HashThresholdBytes)" }

    $findingsArray = @()
    if ($findings.Count -gt 0) {
        $findingsArray = @($findings.ToArray())
    }

    $diagnosticResult = [ordered]@{
        status                = $overallText
        level                 = $overallLevel
        okCount               = $okCount
        infoCount             = $infoCount
        warnCount             = $warnCount
        hashedPercent         = $hashedPct
        metadataPercent       = $metadataPct
        skippedPercent        = $skippedPct
        postFilesIndexed                    = $postIndexed
        postFilesSkipped                    = $postSkipped
        postHashBytesRead                   = $postHashBytes
        postFilesSkippedByAccessDenied      = $fileAccessDenied
        postDirectoriesSkippedByAccessDenied = $dirAccessDenied
        postFilesSkippedByReparsePoint      = $fileReparse
        postDirectoriesSkippedByReparsePoint = $dirReparse
        postFilesSkippedByIoError           = $fileIoErrors
        postDirectoriesSkippedByIoError     = $dirIoErrors
        hashThresholdLabel                  = $thresholdLabel
        effectiveParallelism                = $EffectiveParallelism
        findings                            = $findingsArray
    }

    return [pscustomobject]$diagnosticResult
}

function Write-ScanHealthDiagnosticSummary {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Diagnostic
    )

    $level = "INFO"
    if ($Diagnostic.level -eq "OK") { $level = "SUCCESS" }
    elseif ($Diagnostic.level -eq "WARN") { $level = "WARN" }

    Write-Log ("Diagnostico automatico del escaneo: {0} ({1:N0} advertencia(s), {2:N0} observacion(es))." -f `
        $Diagnostic.status, $Diagnostic.warnCount, $Diagnostic.infoCount) -Level $level

    $diagnosticFindings = @($Diagnostic.findings)
    foreach ($finding in $diagnosticFindings) {
        $itemLevel = "INFO"
        if ($finding.level -eq "OK") { $itemLevel = "SUCCESS" }
        elseif ($finding.level -eq "WARN") { $itemLevel = "WARN" }
        Write-Log (" - [{0}] {1}: {2}" -f $finding.level, $finding.title, $finding.detail) -Level $itemLevel
        if (-not [string]::IsNullOrWhiteSpace($finding.recommendation)) {
            Write-Log ("   Recomendacion: {0}" -f $finding.recommendation) -Level INFO
        }
    }
}

function Convert-ScanDiagnosticToMarkdown {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Diagnostic
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("## Diagnostico Automatico del Escaneo")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine(("**Estado:** {0}  " -f $Diagnostic.status))
    [void]$sb.AppendLine(("**Umbral:** {0}  " -f $Diagnostic.hashThresholdLabel))
    [void]$sb.AppendLine(("**Paralelismo efectivo:** {0}  " -f $Diagnostic.effectiveParallelism))
    [void]$sb.AppendLine(("**Cobertura SHA256:** {0:N1}%  " -f $Diagnostic.hashedPercent))
    [void]$sb.AppendLine(("**Omisiones:** {0:N1}%  " -f $Diagnostic.skippedPercent))
    [void]$sb.AppendLine(("**Acceso denegado:** archivos {0:N0}; directorios {1:N0}  " -f $Diagnostic.postFilesSkippedByAccessDenied, $Diagnostic.postDirectoriesSkippedByAccessDenied))
    [void]$sb.AppendLine(("**Reparse points:** archivos {0:N0}; directorios {1:N0}" -f $Diagnostic.postFilesSkippedByReparsePoint, $Diagnostic.postDirectoriesSkippedByReparsePoint))
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Nivel | Hallazgo | Detalle | Recomendacion |")
    [void]$sb.AppendLine("|---|---|---|---|")

    $diagnosticFindings = @($Diagnostic.findings)
    foreach ($finding in $diagnosticFindings) {
        $detail = ([string]$finding.detail).Replace("|", "\\|")
        $recommendation = ([string]$finding.recommendation).Replace("|", "\\|")
        [void]$sb.AppendLine(("| {0} | {1} | {2} | {3} |" -f $finding.level, $finding.title, $detail, $recommendation))
    }
    [void]$sb.AppendLine("")
    return $sb.ToString()
}

# =================================================================
#  [REFACTOR FASE1/3] Funcion auxiliar de escaneo compartida
# =================================================================

function Invoke-ScanEngine {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Engine,

        [AllowNull()]
        [string[]]$Dirs,

        [ValidateNotNullOrEmpty()]
        [string]$FileVerb = "Indexando"
    )

    if ($null -eq $script:RegTargets -or $script:RegTargets.Count -eq 0) {
        throw "RegTargets no esta inicializado. Define `$script:RegTargets antes de invocar el motor de escaneo."
    }

    [DiffEngine]::KeysScanned = 0

    foreach ($target in $script:RegTargets) {
        $label = [string]$target.Label
        if ([string]::IsNullOrWhiteSpace($label)) { $label = "$($target.Root)\$($target.Path)" }

        Write-Log -Message "Escaneando registro: $label" -Level INFO -NoConsole
        Write-Host " -> Registro $label " -NoNewline -ForegroundColor DarkGray

        try {
            if ($null -eq $target.Root -or [string]::IsNullOrWhiteSpace([string]$target.Path)) {
                throw "Entrada RegTargets invalida: falta Root o Path para '$label'."
            }

            $Engine.ScanRegistryTree($target.Root, [string]$target.Path)
            Write-Host "[OK]" -ForegroundColor Green
        } catch {
            Write-Host "[ERROR]" -ForegroundColor Red
            Write-Log -Message "Error escaneando registro $label : $($_.Exception.Message)" -Level ERROR
            throw
        }
    }

    Write-Host ""

    $dirsToScan = @($Dirs) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique

    foreach ($dir in $dirsToScan) {
        if (-not (Test-Path -LiteralPath $dir)) {
            Write-Log -Message "Ruta omitida porque no existe: $dir" -Level INFO -NoConsole
            continue
        }

        Write-Log -Message "${FileVerb}: $dir" -Level INFO -NoConsole
        Write-Host " -> $FileVerb $dir " -NoNewline -ForegroundColor DarkGray

        try {
            $Engine.ScanDirectory($dir)
            Write-Host "[OK]" -ForegroundColor Green
        } catch {
            Write-Host "[ERROR]" -ForegroundColor Red
            Write-Log -Message "Error durante '$FileVerb' en $dir : $($_.Exception.Message)" -Level ERROR
            throw
        }
    }

    $scanMetrics = Get-FileScanMetricsSnapshot -Engine $Engine -Phase $FileVerb
    Write-FileScanMetricsSummary -Metrics $scanMetrics -Label $FileVerb
    return $scanMetrics
}


$exclusionsPath = Join-Path $PSScriptRoot "DeltaPack.Exclusions.json"

if (-not (Test-Path $exclusionsPath)) {
    Write-Warning "No se encontro DeltaPack.Exclusions.json en: $exclusionsPath"
    Write-Warning "Este archivo es obligatorio: contiene la matriz de exclusiones 'Cero Ruido'. Restauralo junto al script antes de continuar."
    Read-Host "Presiona Enter para salir."
    exit
}

try {
    $exclusionsConfig = Get-Content -LiteralPath $exclusionsPath -Raw -Encoding UTF8 | ConvertFrom-Json

    foreach ($group in $exclusionsConfig.registryExclusions) {
        foreach ($p in $group.paths) { [DiffEngine]::RegExclusions.Add($p) | Out-Null }
    }
    foreach ($group in $exclusionsConfig.fileExclusions) {
        foreach ($p in $group.paths) { [DiffEngine]::FileExclusions.Add($p) | Out-Null }
    }

    if ([DiffEngine]::RegExclusions.Count -eq 0 -or [DiffEngine]::FileExclusions.Count -eq 0) {
        Write-Warning "DeltaPack.Exclusions.json se leyo pero no contiene reglas validas (listas vacias)."
        Read-Host "Presiona Enter para salir."
        exit
    }

    Write-Log "Matriz de exclusiones cargada: $([DiffEngine]::RegExclusions.Count) reglas de registro, $([DiffEngine]::FileExclusions.Count) reglas de archivos." -Level INFO

    [DiffEngine]::HashThresholdBytes = 512KB  # 512 KB = 524 288 bytes
} catch {
    Write-Warning "DeltaPack.Exclusions.json esta corrupto o mal formado: $($_.Exception.Message)"
    Read-Host "Presiona Enter para salir."
    exit
}

# =================================================================
#  Configuracion y Rutas
# =================================================================
Clear-Host
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "     DeltaPack Dual-Engine v$($script:Version) by SOFTMAXTER" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan

$workspaceDir   = Join-Path $env:LOCALAPPDATA "DeltaPack_Workspace"
$stateBinFile   = Join-Path $workspaceDir "snapshot_pre.bin"
$configJsonFile = Join-Path $workspaceDir "config.json"

$isResumeMode = $false
$preScanMetrics = $null
$postScanMetrics = $null
$scanDiagnostic = $null

# --- DETECCION DE REINICIO ---
if (Test-Path $stateBinFile) {
    Write-Host "`n[!] SE HA DETECTADO UNA CAPTURA EN PAUSA (Posible Reinicio)" -ForegroundColor Yellow
    $resp = Read-Host "Deseas reanudar la instalacion anterior? (S/N)"
    
    if ($resp -match '^(s|S)$') {
        $isResumeMode = $true
    } else {
        Remove-Item -Path $workspaceDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Declaracion Global de Directorios a Monitorear
$DirsToMonitor = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:CommonProgramFiles,
    ${env:CommonProgramFiles(x86)},
    $env:ProgramData,
    "$env:PUBLIC\Desktop",
    $env:APPDATA,
    $env:LOCALAPPDATA,
    "$env:windir\System32",
    "$env:windir\SysWOW64",
    "$env:windir\System32\Tasks",
    "$env:windir\SysWOW64\Tasks",
    "$env:windir\Installer",
    "$env:windir\Fonts"
)

$script:RegTargets = @(
    @{ Root = [Microsoft.Win32.Registry]::LocalMachine; Path = "SOFTWARE";                          Label = "HKLM\SOFTWARE" },
    @{ Root = [Microsoft.Win32.Registry]::CurrentUser;  Path = "Software";                          Label = "HKCU\Software" },
    @{ Root = [Microsoft.Win32.Registry]::LocalMachine; Path = "SYSTEM\CurrentControlSet\Services"; Label = "HKLM\SYSTEM\CurrentControlSet\Services" },
    @{ Root = [Microsoft.Win32.Registry]::ClassesRoot;  Path = "CLSID";                             Label = "HKCR\CLSID" },
    @{ Root = [Microsoft.Win32.Registry]::ClassesRoot;  Path = "Interface";                         Label = "HKCR\Interface" },
    @{ Root = [Microsoft.Win32.Registry]::ClassesRoot;  Path = "TypeLib";                           Label = "HKCR\TypeLib" },
    @{ Root = [Microsoft.Win32.Registry]::ClassesRoot;  Path = "AppID";                             Label = "HKCR\AppID" }
)

if ($isResumeMode) {
    # --- RUTA DE REANUDACION (POST-REINICIO) ---
    try {
        $config = Get-Content $configJsonFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "El archivo de configuracion '$configJsonFile' esta corrupto o no se puede leer."
        Write-Warning "Error: $($_.Exception.Message)"
        Write-Warning "Iniciando nueva captura desde cero..."
        Remove-Item -Path $workspaceDir -Recurse -Force -ErrorAction SilentlyContinue
        $isResumeMode = $false
$preScanMetrics = $null
$postScanMetrics = $null
$scanDiagnostic = $null
    }

    if ($isResumeMode) {
        $pkgName        = $config.pkgName
        $finalPkgName   = $config.finalPkgName
        $archTag        = $config.archTag
        $sufijo         = $config.sufijo
        $outDir         = $config.outDir
        $stagingDir     = $config.stagingDir
        $script:LogPath = $config.LogPath
        $isDryRun       = [bool]$config.isDryRun
        if ($null -ne $config.preScanMetrics) { $preScanMetrics = $config.preScanMetrics }

        Write-Log -Message "Reanudando paquete: $finalPkgName" -Level INFO
        Write-Log -Message "Cargando Snapshot base desde el disco duro (Des-serializacion Binaria)..." -Level STEP
        
        $enginePre = [DiffEngine]::LoadState($stateBinFile)
        if ($null -eq $preScanMetrics) {
            $preScanMetrics = Get-FileScanMetricsSnapshot -Engine $enginePre -Phase "Pre-Resume"
        }
        
        Write-Log -Message "Estado base restaurado en memoria." -Level SUCCESS
    }
}

# El bloque 'if (-not $isResumeMode)' cubre tanto la ruta normal como la ruta donde
# el modo resume fue abortado por config.json corrupto.
if (-not $isResumeMode) {
    # --- RUTA NORMAL (NUEVA CAPTURA) ---
    do {
        $pkgName = Read-Host "`n1. Ingresa el nombre base del software (Ej: Office_24)"
        
        if ([string]::IsNullOrWhiteSpace($pkgName)) {
            Write-Warning "El nombre no puede estar vacio."
            $pkgName = $null
        } elseif ($pkgName -match '[\\/:*?"<>|]') {
            Write-Warning "Caracteres prohibidos en nombre de archivo detectados ( \ / : * ? `" < > | )."
            $pkgName = $null
        }
    } until ($null -ne $pkgName)

    $sysArch = $env:PROCESSOR_ARCHITECTURE
    if (-not [string]::IsNullOrEmpty($env:PROCESSOR_ARCHITEW6432)) {
        $sysArch = $env:PROCESSOR_ARCHITEW6432
    }
    $archTag = switch -Regex ($sysArch) {
        "AMD64" { "x64"   }
        "ARM64" { "arm64" }
        default { "x86"   }
    }

    Write-Host "`n2. Selecciona la Categoria del Paquete:" -ForegroundColor Yellow
    Write-Host "   [1] Paquete Principal (Sufijo '_main')"
    Write-Host "   [2] Complemento / Idioma / Update"
    $tipoPaquete = Read-Host "Opcion"

    if ($tipoPaquete -eq '1') {
        $sufijo = "main"
    } else {
        # Validacion de caracteres prohibidos en el sufijo, igual que en pkgName.
        do {
            $sufijo = Read-Host "Ingresa el sufijo"
            
            if ([string]::IsNullOrWhiteSpace($sufijo)) {
                $sufijo = "extra"
                break
            } elseif ($sufijo -match '[\\/:*?"<>|]') {
                Write-Warning "Caracteres prohibidos en sufijo detectados ( \ / : * ? `" < > | )."
                $sufijo = $null
            }
        } until ($null -ne $sufijo)
    }

    Write-Host "`n3. Modo de Ejecucion:" -ForegroundColor Yellow
    Write-Host "   [1] Captura Completa (genera .wim + .reg + reporte)"
    Write-Host "   [2] Dry Run / Vista Previa (solo calcula y reporta; NO copia archivos ni genera .wim)"
    $modoEjecucion = Read-Host "Opcion"

    $isDryRun = ($modoEjecucion -eq '2')

    $finalPkgName = "${pkgName}_${archTag}_${sufijo}"
    Write-Host "`n[OK] El paquete se generara como: $finalPkgName" -ForegroundColor Green
    if ($isDryRun) {
        Write-Host "[INFO] Modo Dry Run activo: no se copiaran archivos ni se generara el .wim." -ForegroundColor Cyan
    }

    $outDir     = Join-Path $env:USERPROFILE "Desktop\DeltaPack_$finalPkgName"
    $stagingDir = Join-Path $outDir "Staging"

    if (Test-Path $outDir) {
        Remove-Item -Path $outDir -Recurse -Force
    }
    
    New-Item -Path $outDir     -ItemType Directory -Force | Out-Null
    New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null

    $script:LogPath = Join-Path $outDir "Install_Log.txt"
    Write-Log -Message "Entorno preparado. Log iniciado en: $script:LogPath" -Level SUCCESS

    # --- FASE 1: SNAPSHOT INICIAL ---
    Write-Log -Message "Fase 1/4: Mapeando el estado base (Registro + Archivos)..." -Level STEP
    $enginePre = New-Object DiffEngine
    $preScanMetrics = Invoke-ScanEngine -Engine $enginePre -Dirs $DirsToMonitor -FileVerb "Indexando"

    # --- SALVAGUARDAR ESTADO ---
    Write-Log -Message "Serializando estado y guardando en disco (Proteccion contra reinicios)..." -Level INFO
    
    if (-not (Test-Path $workspaceDir)) {
        New-Item -Path $workspaceDir -ItemType Directory -Force | Out-Null
    }
    
    $configData = @{
        pkgName      = $pkgName
        finalPkgName = $finalPkgName
        archTag      = $archTag
        sufijo       = $sufijo
        outDir       = $outDir
        stagingDir   = $stagingDir
        LogPath         = $script:LogPath
        isDryRun        = $isDryRun
        preScanMetrics  = $preScanMetrics
    }
    
    $configData | ConvertTo-Json -Depth 5 | Set-Content $configJsonFile -Encoding utf8
    $enginePre.SaveState($stateBinFile)

    Write-Log -Message "Estado base asegurado. La herramienta sobrevivira a un reinicio." -Level SUCCESS
    [System.GC]::Collect()

    # --- AUTO-ARRANQUE (RESILIENCIA POST-REINICIO) ---
    Write-Log "Configurando Auto-Reanudacion (RunOnce)..." -Level INFO
    if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
        $launcherPath = Join-Path (Split-Path $PSScriptRoot -Parent) "DeltaPackDual-Engine.exe"

        if (Test-Path $launcherPath) {
            $runOnceKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
            Set-ItemProperty -Path $runOnceKey -Name "DeltaPackResume" -Value "`"$launcherPath`"" -Force
            Write-Log "El ancla de auto-arranque esta lista." -Level SUCCESS
        } else {
            Write-Warning "No se encontro DeltaPackDual-Engine.exe en: $launcherPath"
            Write-Log "Auto-arranque post-reinicio deshabilitado (DeltaPackDual-Engine.exe no encontrado)." -Level WARN
        }
    } else {
        Write-Log "PSScriptRoot no disponible (ejecucion interactiva / dot-sourcing). Auto-arranque deshabilitado." -Level WARN
    }
}

# --- FASE 2: INSTALACION / VERIFICACION POST-REINICIO ---
Write-Host "`n=======================================================" -ForegroundColor Magenta
if ($isResumeMode) {
    Write-Host "         REANUDACION TRAS REINICIO DETECTADA          " -ForegroundColor Magenta
} else {
    Write-Host "                 PAUSA DE INSTALACION                  " -ForegroundColor Magenta
}
Write-Host "=======================================================" -ForegroundColor Magenta
if ($isResumeMode) {
    Write-Host "1. El equipo se reinicio durante la instalacion/configuracion."
    Write-Host "2. Verifica que el instalador haya finalizado por completo (wizards, drivers, primer arranque)."
    Write-Host "3. Cierra el programa por completo antes de continuar." -ForegroundColor Yellow
    Write-Host "   Presiona ENTER cuando la instalacion/configuracion haya terminado."
} else {
    Write-Host "1. Instala tu programa ahora."
    Write-Host "2. Configura la aplicacion a tu gusto y cierrala por completo."
    Write-Host "3. EL PROGRAMA TE PIDE REINICIAR EL EQUIPO?" -ForegroundColor Yellow
    Write-Host "   - SI: Reinicia el PC tranquilamente. Al volver a Windows, ejecuta DeltaPackDual-Engine.exe de nuevo."
    Write-Host "   - NO: Simplemente presiona ENTER aqui abajo para continuar."
}
Write-Host "=======================================================" -ForegroundColor Magenta
Write-Host ""
Pause

Write-Host ""
# --- DESACTIVAR AUTO-ARRANQUE ---
$runOnceKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
if ($null -ne (Get-ItemProperty -Path $runOnceKey -Name "DeltaPackResume" -ErrorAction SilentlyContinue)) {
    Remove-ItemProperty -Path $runOnceKey -Name "DeltaPackResume" -Force -ErrorAction SilentlyContinue
    Write-Log "Ancla de auto-arranque removida." -Level INFO
}

# --- FASE 3: SNAPSHOT FINAL Y DIFF ---
Write-Log "Fase 3/4: Mapeando estado post-instalacion..." -Level STEP
$enginePost = New-Object DiffEngine
$postScanMetrics = Invoke-ScanEngine -Engine $enginePost -Dirs $DirsToMonitor -FileVerb "Verificando"

$hashThresholdBytesForDiagnostic = [int64][DiffEngine]::HashThresholdBytes
$maxScanParallelismForDiagnostic = [int][DiffEngine]::MaxScanParallelism
$effectiveParallelismForDiagnostic = if ($maxScanParallelismForDiagnostic -gt 0) { $maxScanParallelismForDiagnostic } else { [math]::Min(4, [Environment]::ProcessorCount) }
$scanDiagnostic = Get-ScanHealthDiagnostic -PreMetrics $preScanMetrics -PostMetrics $postScanMetrics -HashThresholdBytes $hashThresholdBytesForDiagnostic -EffectiveParallelism $effectiveParallelismForDiagnostic
Write-ScanHealthDiagnosticSummary -Diagnostic $scanDiagnostic

Write-Log "Calculando diferencias de Registro..." -Level INFO
$regOutputFile = Join-Path $outDir "${finalPkgName}.reg"
[DiffEngine]::GenerateRegFile($enginePre, $enginePost, $regOutputFile)
$regMetrics = Get-RegFileMetrics -Path $regOutputFile
Write-Log ("Registro exportado: {0:N0} entrada(s) en .reg ({1:N0} seccion(es)/clave(s), {2:N0} valor(es), {3:N0} clave(s) eliminada(s), {4:N0} valor(es) eliminado(s))." -f `
    $regMetrics.TotalEntries, $regMetrics.KeySections, $regMetrics.ValueEntries, $regMetrics.DeletedKeys, $regMetrics.DeletedValues) -Level SUCCESS

Write-Log "Calculando diferencias de Archivos..." -Level INFO
$changedFiles = [DiffEngine]::GetFileDifferences($enginePre, $enginePost)
Write-Log ("Delta: {0:N0} archivo(s) nuevo(s), {1:N0} modificado(s), {2:N0} carpeta(s) nueva(s)." -f `
    $changedFiles.NewFiles.Count, $changedFiles.ModifiedFiles.Count, $changedFiles.NewDirs.Count) -Level INFO

$changedFileOnlyPaths = @($changedFiles.NewFiles) + @($changedFiles.ModifiedFiles)
if ($changedFiles.NewDirs.Count -gt 0) {
    Write-Log ("Directorios nuevos detectados: {0:N0}. No se empaquetan como carpetas vacias; solo se crean carpetas padre necesarias para archivos." -f $changedFiles.NewDirs.Count) -Level INFO
}

$deletedFiles         = [DiffEngine]::GetDeletedFiles($enginePre, $enginePost)
$deletedListForReport = New-Object System.Collections.Generic.List[string]
foreach ($delPath in $deletedFiles) {
    $isDelDir = ($enginePre.FileSnapshot.ContainsKey($delPath) -and $enginePre.FileSnapshot[$delPath] -eq "DIR")
    $delRel   = Split-Path $delPath -NoQualifier
    $delRel   = $delRel.TrimStart('\', '/')
    if ($isDelDir) { $delRel = "$delRel\ (carpeta)" }
    $deletedListForReport.Add($delRel)
}
if ($deletedListForReport.Count -gt 0) {
    Write-Log "$($deletedListForReport.Count) archivo(s)/carpeta(s) eliminados por el instalador (no incluidos en el WIM; documentados en el reporte)." -Level WARN
}

# Liberar memoria del Snapshot 'Pre' que ya no se necesita
$enginePre = $null
[System.GC]::Collect()

$osInfo    = Get-CimInstance Win32_OperatingSystem
$osVersion = "$($osInfo.Caption) (Build $($osInfo.BuildNumber))"

# --- FASE 4: STAGING Y EMPAQUETADO (VSS INTEGRATED) ---
Write-Log "Fase 4/4: Extrayendo archivos (Soporte VSS para archivos bloqueados)..." -Level STEP
$fileCount         = 0
$totalSizeBytes    = 0
$fileListForReport = New-Object System.Collections.Generic.List[string]

$checksumLines     = New-Object System.Collections.Generic.List[string]

# Abstraccion segura del perfil de usuario
$currentUserProfile = Split-Path $env:USERPROFILE -NoQualifier
$currentUserProfile = $currentUserProfile.TrimStart('\', '/')

if ($isDryRun) { 
    Write-Log "Modo Dry Run activo: se omite la copia de archivos, VSS y la creacion del WIM." -Level WARN

    foreach ($file in $changedFileOnlyPaths) {
        if ($file.StartsWith($workspaceDir, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        $relPath = Split-Path $file -NoQualifier
        $relPath = $relPath.TrimStart('\', '/')
        if ($relPath.StartsWith($currentUserProfile, [StringComparison]::OrdinalIgnoreCase)) {
            $relPath = $relPath -replace [regex]::Escape($currentUserProfile), "Users\Default"
        }

        try {
            $fi = [System.IO.FileInfo]::new($file)
            if ($fi.Exists) {
                $fileCount++
                $totalSizeBytes += $fi.Length
                $fileListForReport.Add($relPath)
            }
        } catch { }
    }

    $wimOutputFile = $null
    Write-Log ("Archivos detectados: {0:N0} archivo(s), {1} estimados. Dry Run activo: no se copio ningun archivo." -f $fileCount, (Format-ByteSize -Bytes $totalSizeBytes)) -Level SUCCESS
} else {
# --- 1. INICIALIZACION VSS ---
$systemDrive    = $env:SystemDrive + "\"
$vssDeviceObject = $null
$vssShadowID     = $null

$script:VssShadowIdForCleanup = $null
try {
    [Console]::add_CancelKeyPress({
        if ($script:VssShadowIdForCleanup) {
            try {
                Start-Process -FilePath "vssadmin.exe" -ArgumentList "delete shadows /shadow=$($script:VssShadowIdForCleanup) /quiet" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            } catch { }
        }
    })
} catch { }

Write-Log "Solicitando Instantanea VSS para la unidad $systemDrive..." -Level INFO
try {
    $vssClass  = Get-CimClass -ClassName Win32_ShadowCopy -Namespace "root/cimv2" -ErrorAction Stop
    $vssResult = Invoke-CimMethod -CimClass $vssClass -MethodName "Create" -Arguments @{
        Volume  = $systemDrive
        Context = "ClientAccessible"
    } -ErrorAction Stop

    if ($vssResult.ReturnValue -eq 0) {
        $vssShadowID = $vssResult.ShadowID
        $script:VssShadowIdForCleanup = $vssShadowID
        Start-Sleep -Seconds 2
        $vssSnapshot     = Get-CimInstance -ClassName Win32_ShadowCopy -Filter "ID = '$vssShadowID'" -ErrorAction SilentlyContinue
        $vssDeviceObject = $vssSnapshot.DeviceObject
        Write-Log "Instantanea VSS creada con exito: $vssDeviceObject" -Level SUCCESS
    } else {
        Write-Log "ADVERTENCIA: No se pudo crear la instantanea VSS (Codigo: $($vssResult.ReturnValue)). Se continuara en modo estandar." -Level WARN
    }
} catch {
    Write-Log "ADVERTENCIA: Fallo al inicializar VSS via CIM. Se continuara sin extraccion de nivel de bloque. ($($_.Exception.Message))" -Level WARN
}

# --- 2. BUCLE DE EXTRACCION ---
$filesToCopy = @($changedFileOnlyPaths | Where-Object {
    -not $_.StartsWith($workspaceDir, [System.StringComparison]::OrdinalIgnoreCase)
})
$copyTotal     = $filesToCopy.Count
$copyProcessed = 0

if ($copyTotal -gt 0) {
    Write-Log ("Preparando copia: {0:N0} archivo(s) candidato(s) al Staging." -f $copyTotal) -Level INFO
    Write-FileCopyProgress -Processed 0 -Total $copyTotal -Copied 0 -Bytes 0 -CurrentFile $null
} else {
    Write-Log "No hay archivos candidatos para copiar al Staging." -Level INFO
}

$sha256Algo = [System.Security.Cryptography.SHA256]::Create()
foreach ($file in $filesToCopy) {

    if ($file.StartsWith($workspaceDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Log "Auto-exclusion: Ignorando archivo interno del workspace: $(Split-Path $file -Leaf)" -Level INFO
        continue
    }

    $isDir = ($enginePost.FileSnapshot.ContainsKey($file) -and $enginePost.FileSnapshot[$file] -eq "DIR")
    if ($isDir) { 
        continue
    }

    $relPath = Split-Path $file -NoQualifier
    $relPath = $relPath.TrimStart('\', '/')

    if ($relPath.StartsWith($currentUserProfile, [StringComparison]::OrdinalIgnoreCase)) {
        $oldPath = $relPath
        $relPath = $relPath -replace [regex]::Escape($currentUserProfile), "Users\Default"
        Write-Log "Redirigiendo perfil: $oldPath -> $relPath" -Level INFO -NoConsole
    }

    $destPath = Join-Path $stagingDir $relPath
    
    $copyProcessed++
    Write-FileCopyProgress -Processed $copyProcessed -Total $copyTotal -Copied $fileCount -Bytes $totalSizeBytes -CurrentFile $file
    
    $destFolder  = Split-Path $destPath -Parent
    $fileCopied  = $false
    $hashHex     = $null

    try {
        if (-not [System.IO.Directory]::Exists($destFolder)) {
            [System.IO.Directory]::CreateDirectory($destFolder) | Out-Null
        }

        # Intento 1: Copia + Hash en pasada unica (single-pass I/O)
        $hashHex    = [DiffEngine]::CopyAndHash($file, $destPath)
        $fileCopied = $true
        
    } catch [System.IO.IOException] {
        # Intento 2: Copia VSS (Rescate de archivo en uso/bloqueado)
        if ($null -ne $vssDeviceObject) {
            Write-Log "Archivo bloqueado detectado. Rescatando desde VSS: $file" -Level WARN
            try {
                $vssFilePath = $file -replace "^$([regex]::Escape($env:SystemDrive))", $vssDeviceObject
                Copy-Item -LiteralPath $vssFilePath -Destination $destPath -Force -ErrorAction Stop
                $fileCopied = $true
                Write-Log "Rescate VSS exitoso para: $relPath" -Level SUCCESS
            } catch {
                Write-Log "ERROR CRITICO: El archivo resistio incluso a VSS: $file -> $($_.Exception.Message)" -Level ERROR
            }
        } else {
            Write-Log "ADVERTENCIA: Archivo en uso omitido (VSS no disponible): $file" -Level WARN
        }
    } catch [System.UnauthorizedAccessException] {
        Write-Log "ADVERTENCIA: Acceso denegado (Permisos insuficientes): $file" -Level WARN
    } catch {
        Write-Log "ERROR: Fallo inesperado al copiar $file -> $($_.Exception.Message)" -Level ERROR
    }

    if ($fileCopied) {
        $fileInfo = [System.IO.FileInfo]::new($destPath)
        if ($fileInfo.Exists) {
            $fileCount++
            $totalSizeBytes += $fileInfo.Length
            $fileListForReport.Add($relPath)

            if ([string]::IsNullOrEmpty($hashHex)) {
                try {
                    $fileStream = [System.IO.File]::OpenRead($destPath)
                    try   { $hashBytes = $sha256Algo.ComputeHash($fileStream) }
                    finally { $fileStream.Dispose() }
                    $hashHex = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
                } catch {
                    Write-Log "ADVERTENCIA: No se pudo calcular SHA256 de $relPath : $($_.Exception.Message)" -Level WARN
                }
            }
            if (-not [string]::IsNullOrEmpty($hashHex)) {
                $checksumLines.Add("$hashHex  $relPath")
            }

            Write-FileCopyProgress -Processed $copyProcessed -Total $copyTotal -Copied $fileCount -Bytes $totalSizeBytes -CurrentFile $file
        }
    }
}
$sha256Algo.Dispose()
if ($copyTotal -gt 0) {
    Write-FileCopyProgress -Processed $copyTotal -Total $copyTotal -Copied $fileCount -Bytes $totalSizeBytes -Completed
}

# --- 3. LIMPIEZA VSS ---
if ($null -ne $vssShadowID) {
    Write-Log "Limpiando Instantanea VSS del sistema..." -Level INFO
    try {
        # Metodo 1: vssadmin (mas confiable en Win10/11 modernos)
        $vssClean = Start-Process -FilePath "vssadmin.exe" `
            -ArgumentList "delete shadows /shadow=$vssShadowID /quiet" `
            -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        
        if ($vssClean.ExitCode -eq 0) {
            Write-Log "Instantanea VSS eliminada correctamente (vssadmin)." -Level SUCCESS
        } else {
            # Metodo 2: Fallback CIM (reemplaza el Get-WmiObject obsoleto)
            $snap = Get-CimInstance -ClassName Win32_ShadowCopy | 
                    Where-Object { $_.ID -eq $vssShadowID }
            if ($snap) {
                Invoke-CimMethod -InputObject $snap -MethodName "Delete" | Out-Null
                Write-Log "Instantanea VSS eliminada (CIM fallback)." -Level SUCCESS
            }
        }
    } catch {
        Write-Log "ADVERTENCIA: Snapshot VSS $vssShadowID requiere limpieza manual. Ejecuta: vssadmin delete shadows /shadow=$vssShadowID /quiet" -Level WARN
    }
    $script:VssShadowIdForCleanup = $null
}

Write-Log ("Archivos copiados a Staging: {0:N0} archivo(s), {1} total." -f $fileCount, (Format-ByteSize -Bytes $totalSizeBytes)) -Level SUCCESS

# --- 4. CREACION DEL WIM ---
if ($fileCount -gt 0) {
    $wimOutputFile = Join-Path $outDir "${finalPkgName}.wim"
    $dismLog       = Join-Path $outDir "dism.log"
    $scratchDir    = Join-Path $env:SystemDrive "S"

    $freeAtOutDir     = Get-FreeSpaceBytes -Path $outDir
    $freeAtScratch    = Get-FreeSpaceBytes -Path $scratchDir
    $requiredAtOutDir = [int64]($totalSizeBytes * 1.1)
    $requiredAtScratch = [Math]::Max(500MB, [int64]($totalSizeBytes * 0.15))

    $spaceOk = $true
    if ($freeAtOutDir -ge 0 -and $freeAtOutDir -lt $requiredAtOutDir) {
        Write-Log "ESPACIO INSUFICIENTE en $(Split-Path $outDir -Qualifier) (destino del .wim): disponible $([math]::Round($freeAtOutDir/1MB,0)) MB, se requieren ~$([math]::Round($requiredAtOutDir/1MB,0)) MB." -Level ERROR
        $spaceOk = $false
    }
    if ($freeAtScratch -ge 0 -and $freeAtScratch -lt $requiredAtScratch) {
        Write-Log "ESPACIO INSUFICIENTE en $(Split-Path $scratchDir -Qualifier) (Scratch de DISM): disponible $([math]::Round($freeAtScratch/1MB,0)) MB, se requieren ~$([math]::Round($requiredAtScratch/1MB,0)) MB." -Level ERROR
        $spaceOk = $false
    }

    if ($spaceOk) {
        # 1. Crear directorio Scratch ultra-corto y aislado
        if (-not (Test-Path $scratchDir)) {
            New-Item -Path $scratchDir -ItemType Directory -Force | Out-Null
        }

        # $osInfo y $osVersion ya estan declarados antes de este bloque.
        $dateStr  = Get-Date -Format "yyyy-MM-dd HH:mm"
        $nameMeta = "$finalPkgName [DeltaPack]"
        $descMeta = "App: $pkgName | Modulo: $sufijo | Arch: $archTag | SO Captura: $osVersion | Fecha: $dateStr"

        Write-Log "Comprimiendo contenedor (Max Compression) usando Scratch aislado en $scratchDir..." -Level INFO
        Write-Host "`nIniciando captura WIM. Por favor espera, esto puede tomar varios minutos..." -ForegroundColor Yellow

        # 2. Invocar DISM via cmdlet nativo de PowerShell (New-WindowsImage)
        try {
            Import-Module Dism -ErrorAction Stop
            New-WindowsImage `
                -ImagePath        $wimOutputFile `
                -CapturePath      $stagingDir `
                -Name             $nameMeta `
                -Description      $descMeta `
                -CompressionType  "Max" `
                -Verify `
                -NoRpFix `
                -LogPath          $dismLog `
                -LogLevel         1 `
                -ScratchDirectory $scratchDir `
                -ErrorAction      Stop

            Write-Log "Paquete WIM creado exitosamente." -Level SUCCESS
        } catch {
            Write-Log "Fallo al crear WIM: $($_.Exception.Message)" -Level ERROR
            Write-Log "Log detallado disponible en: $(Split-Path $dismLog -Leaf)" -Level ERROR
            if (Test-Path $wimOutputFile) { Remove-Item $wimOutputFile -Force }
            $wimOutputFile = $null
        }

        # 3. Limpieza del directorio Scratch
        Remove-Item -Path $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log "Empaquetado WIM omitido por falta de espacio. El .reg y el manifiesto ya fueron generados; libera espacio y vuelve a ejecutar para obtener el .wim." -Level WARN
        $wimOutputFile = $null
    }
} else {
    Write-Log "No se detectaron cambios en archivos. No se generara paquete WIM." -Level WARN
    $wimOutputFile = $null
}
}

$checksumsFile = $null
if (-not $isDryRun -and $checksumLines.Count -gt 0) {
    $checksumsFile = Join-Path $outDir "Checksums_$finalPkgName.sha256"
    try {
        [System.IO.File]::WriteAllLines($checksumsFile, [string[]]$checksumLines, [System.Text.Encoding]::UTF8)
        Write-Log "Manifiesto de integridad SHA256 generado: $(Split-Path $checksumsFile -Leaf)" -Level SUCCESS
    } catch {
        Write-Log "ADVERTENCIA: No se pudo escribir el archivo de checksums: $($_.Exception.Message)" -Level WARN
        $checksumsFile = $null
    }
}

# =================================================================
#  GENERACION DEL REPORTE
# =================================================================
Write-Log "Generando documentacion y metricas..." -Level STEP

# 1. Conteo de Registro reutilizado desde el resumen de consola.
if ($null -eq $regMetrics) {
    $regMetrics = Get-RegFileMetrics -Path $regOutputFile
}
$regKeysCount     = $regMetrics.KeySections
$regValuesCount   = $regMetrics.ValueEntries
$regKeysDeleted   = $regMetrics.DeletedKeys
$regValuesDeleted = $regMetrics.DeletedValues

# 2. Formateo de Tamaño Dinamico (Maneja tamanos menores a 1MB)
$sizeDisplay = Format-ByteSize -Bytes $totalSizeBytes

if ($null -eq $preScanMetrics)  { $preScanMetrics  = Get-FileScanMetricsSnapshot -Engine $enginePre  -Phase "Pre" }
if ($null -eq $postScanMetrics) { $postScanMetrics = Get-FileScanMetricsSnapshot -Engine $enginePost -Phase "Post" }
$hashThresholdBytes = [int64][DiffEngine]::HashThresholdBytes
$maxScanParallelism = [int][DiffEngine]::MaxScanParallelism
$effectiveParallelism = if ($maxScanParallelism -gt 0) { $maxScanParallelism } else { [math]::Min(4, [Environment]::ProcessorCount) }
if ($null -eq $scanDiagnostic) {
    $scanDiagnostic = Get-ScanHealthDiagnostic -PreMetrics $preScanMetrics -PostMetrics $postScanMetrics -HashThresholdBytes $hashThresholdBytes -EffectiveParallelism $effectiveParallelism
}
$scanDiagnosticMarkdown = Convert-ScanDiagnosticToMarkdown -Diagnostic $scanDiagnostic

$reportFile = Join-Path $outDir "README_$finalPkgName.md"
$dateStr    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# =================================================================
#  GENERACION DEL MANIFEST JSON
# =================================================================
$manifestFile = Join-Path $outDir "manifest_$finalPkgName.json"
$manifestObj  = [ordered]@{
    schemaVersion    = 1
    generatedBy      = "DeltaPack Dual-Engine v$($script:Version)"
    captureTimestamp = (Get-Date -Format "s")   # ISO 8601 sortable: 2025-06-01T14:30:00
    package          = [ordered]@{
        fullName     = $finalPkgName
        baseName     = $pkgName
        type         = $sufijo
        architecture = $archTag
        sourceOS     = $osVersion
    }
    host             = [ordered]@{
        computerName = $env:COMPUTERNAME
        psVersion    = "$($PSVersionTable.PSVersion)"
    }
    stats            = [ordered]@{
        fileCount               = $fileCount
        newFilesInDelta         = $changedFiles.NewFiles.Count
        modifiedFilesInDelta    = $changedFiles.ModifiedFiles.Count
        newDirectoriesDetected  = $changedFiles.NewDirs.Count
        emptyDirectoriesPackaged = 0
        totalSizeBytes          = $totalSizeBytes
        totalSizeMB             = [math]::Round($totalSizeBytes / 1MB, 2)
        registryTotalEntries    = $regMetrics.TotalEntries
        registryKeysAdded       = $regKeysCount
        registryValuesAdded     = $regValuesCount
        registryKeysDeleted     = $regKeysDeleted
        registryValuesDeleted   = $regValuesDeleted
        filesDeletedByInstaller = $deletedListForReport.Count
    }
    scan             = [ordered]@{
        hashThresholdBytes = $hashThresholdBytes
        hashThresholdLabel = if ($hashThresholdBytes -le 0) { "Legado LastWriteTimeUtc-Length" } else { "SHA256 para archivos menores de $(Format-ByteSize -Bytes $hashThresholdBytes)" }
        maxParallelism     = $maxScanParallelism
        effectiveParallelism = $effectiveParallelism
        diagnostic        = $scanDiagnostic
        pre               = $preScanMetrics
        post              = $postScanMetrics
    }
    outputs          = [ordered]@{
        wimFile       = if ($wimOutputFile -and (Test-Path $wimOutputFile)) { Split-Path $wimOutputFile -Leaf } else { $null }
        regFile       = if (Test-Path $regOutputFile)  { Split-Path $regOutputFile  -Leaf } else { $null }
        checksumsFile = if ($checksumsFile)             { Split-Path $checksumsFile  -Leaf } else { $null }
        readmeFile    = Split-Path $reportFile -Leaf
        manifestFile  = "manifest_$finalPkgName.json"
    }
    flags            = [ordered]@{
        isDryRun   = $isDryRun
        wimCreated = ($null -ne $wimOutputFile -and (Test-Path $wimOutputFile))
    }
}
try {
    $manifestJson = $manifestObj | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($manifestFile, $manifestJson, [System.Text.Encoding]::UTF8)
    Write-Log "Manifesto JSON generado: $(Split-Path $manifestFile -Leaf)" -Level SUCCESS
} catch {
    Write-Log "ADVERTENCIA: No se pudo escribir manifest.json: $($_.Exception.Message)" -Level WARN
    $manifestFile = $null
}

$dryRunBanner   = if ($isDryRun) { "`n> **MODO DRY RUN - VISTA PREVIA.** No se copio ningun archivo ni se genero un paquete `` .wim ``.`n" } else { "" }
$fileCountLabel  = if ($isDryRun) { "Total de Archivos Detectados (Vista Previa, sin .wim)" } else { "Total de Archivos Empaquetados (.wim)" }
$manifestoDescTxt = if ($isDryRun) { "A continuacion, se detalla la ruta relativa de los archivos que se incluirian en el paquete (vista previa; ningun archivo fue copiado)." } else { "A continuacion, se detalla la ruta relativa de los archivos contenidos en el paquete WIM." }

# 3. Generacion del Markdown por Bloques (Evita OutOfMemory en listas inmensas)
$mdHeader = @"
# Reporte de Paquete: $finalPkgName
$dryRunBanner
**Generado automaticamente por DeltaPack Dual-Engine v$($script:Version)**
* **Fecha:** $dateStr
* **Host:** $($env:COMPUTERNAME)
* **SO de Captura:** $($osInfo.Caption) (Build $($osInfo.BuildNumber))

## Resumen Estadistico

| Metrica | Valor |
|---|---|
| $fileCountLabel | $fileCount |
| Archivos Nuevos Detectados | $($changedFiles.NewFiles.Count) |
| Archivos Modificados Detectados | $($changedFiles.ModifiedFiles.Count) |
| Carpetas Nuevas Detectadas | $($changedFiles.NewDirs.Count) |
| Carpetas Vacías Empaquetadas | 0 |
| Tamaño Total Descomprimido | $sizeDisplay |
| Claves de Registro Agregadas/Modificadas (.reg) | $regKeysCount |
| Valores de Registro Agregados/Modificados | $regValuesCount |
| Claves de Registro Eliminadas (.reg) | $regKeysDeleted |
| Valores de Registro Eliminados | $regValuesDeleted |
| Archivos/Carpetas Eliminados por el Instalador | $($deletedListForReport.Count) |
| Manifiesto de Integridad SHA256 | $(if ($checksumsFile) { "Si - $(Split-Path $checksumsFile -Leaf)" } else { "No generado (Dry Run)" }) |

## Metricas Internas de Escaneo de Archivos

| Fase | Indexados | SHA256 | Metadata | Legado | Fallback | Omitidos | Directorios | Hash Leido | Tiempo |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Snapshot Inicial | $($preScanMetrics.filesIndexed) | $($preScanMetrics.filesHashed) | $($preScanMetrics.filesByMetadata) | $($preScanMetrics.filesLegacy) | $($preScanMetrics.filesFallbackSize) | $($preScanMetrics.filesSkipped) | $($preScanMetrics.directoriesScanned) | $($preScanMetrics.hashBytesReadLabel) | $($preScanMetrics.elapsed) |
| Snapshot Final | $($postScanMetrics.filesIndexed) | $($postScanMetrics.filesHashed) | $($postScanMetrics.filesByMetadata) | $($postScanMetrics.filesLegacy) | $($postScanMetrics.filesFallbackSize) | $($postScanMetrics.filesSkipped) | $($postScanMetrics.directoriesScanned) | $($postScanMetrics.hashBytesReadLabel) | $($postScanMetrics.elapsed) |

Detalle de omisiones: excluidos, reparse points, acceso denegado, errores I/O y otros quedan separados por archivos/directorios en el manifest JSON.

$scanDiagnosticMarkdown
## Manifiesto de Archivos
$manifestoDescTxt

<details>
<summary><b>Clic aqui para expandir lista ($fileCount archivos)</b></summary>
<pre><code>
"@

$mdManifestFooter = @"
</code></pre>
</details>
"@

$mdDeletedHeader = @"

## Archivos y Carpetas Eliminados por el Instalador

Estos elementos existian antes de la instalacion y ya no estaban presentes en el snapshot final.
Un WIM es un contenedor aditivo y no puede representar una eliminacion, por lo que no se incluyen
en el paquete; se documentan aqui unicamente para auditoria del proceso de captura.

<details>
<summary><b>Clic aqui para expandir lista ($($deletedListForReport.Count) elemento(s))</b></summary>
<pre><code>
"@

$mdDeletedFooter = @"
</code></pre>
</details>
"@

$dryRunNotaTecnica   = if ($isDryRun) { "`n* **Modo Dry Run:** no se genero el archivo `` .wim `` ni se copio ningun archivo a disco. Vuelve a ejecutar en modo Captura Completa para generar el paquete final." } else { "" }
$checksumNotaTecnica = if ($checksumsFile) { "`n* Verifica la integridad de los archivos extraidos comparando contra `` $(Split-Path $checksumsFile -Leaf) `` (formato `` hash  ruta ``, compatible con herramientas tipo sha256sum)." } else { "" }
$manifestNotaTecnica = if ($manifestFile)  { "`n* Metricas de la captura en formato maquina-legible: ``$(Split-Path $manifestFile -Leaf)`` (JSON, schemaVersion 1)." } else { "" }

$mdNotasTecnicas = @"

## Notas Tecnicas
* El paquete incluye redireccion automatica de ``%USERPROFILE%`` a ``Users\Default``.
* Inyectar el archivo ``.reg`` **despues** de desplegar el ``.wim``.
* El escaneo de archivos usa fingerprint hibrido configurable: $($manifestObj.scan.hashThresholdLabel); paralelismo efectivo: $effectiveParallelism.
* Diagnostico automatico del escaneo: $($scanDiagnostic.status) ($($scanDiagnostic.warnCount) advertencia(s), $($scanDiagnostic.infoCount) observacion(es)).
* Las carpetas nuevas vacias no se empaquetan por defecto; solo se crean carpetas padre necesarias para archivos reales.
* Generado con DeltaPack Dual-Engine v$($script:Version) - PS $($PSVersionTable.PSVersion)$dryRunNotaTecnica$checksumNotaTecnica$manifestNotaTecnica
"@

# 4. Escritura Segura a Disco (Streaming, sin BOM)
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $writer    = New-Object System.IO.StreamWriter($reportFile, $false, $utf8NoBom)
    
    $writer.WriteLine($mdHeader)
    
    foreach ($f in $fileListForReport) {
        $writer.WriteLine($f)
    }
    
    $writer.WriteLine($mdManifestFooter)

    if ($deletedListForReport.Count -gt 0) {
        $writer.WriteLine($mdDeletedHeader)
        foreach ($d in $deletedListForReport) {
            $writer.WriteLine($d)
        }
        $writer.WriteLine($mdDeletedFooter)
    } else {
        $writer.WriteLine("`n## Archivos y Carpetas Eliminados por el Instalador`n`nNo se detectaron eliminaciones durante la captura.")
    }

    $writer.WriteLine($mdNotasTecnicas)
    
} finally {
    if ($null -ne $writer) { $writer.Dispose() }
}

# =================================================================
#  LIMPIEZA Y FINALIZACION
# =================================================================
if (Test-Path $workspaceDir) {
    Remove-Item -Path $workspaceDir -Recurse -Force -ErrorAction SilentlyContinue
}

if (Test-Path $stagingDir) {
    Write-Log "Limpiando directorio de Staging..." -Level INFO
    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n=======================================================" -ForegroundColor Cyan
Write-Log "PROCESO FINALIZADO" -Level SUCCESS
Write-Host "Carpeta de Salida: $outDir" -ForegroundColor Gray

$regName = Split-Path $regOutputFile -Leaf
$mdName  = Split-Path $reportFile   -Leaf

if (Test-Path $regOutputFile) { Write-Host "  [OK] $regName" -ForegroundColor White }

if ($null -ne $checksumsFile -and (Test-Path $checksumsFile)) {
    Write-Host "  [OK] $(Split-Path $checksumsFile -Leaf)" -ForegroundColor White
}

if ($null -ne $wimOutputFile) {
    $wimName = Split-Path $wimOutputFile -Leaf
    if (Test-Path $wimOutputFile) { Write-Host "  [OK] $wimName" -ForegroundColor White }
}

Write-Host "  [OK] $mdName" -ForegroundColor Magenta
if ($null -ne $manifestFile -and (Test-Path $manifestFile)) {
    Write-Host "  [OK] $(Split-Path $manifestFile -Leaf)" -ForegroundColor Cyan
}
Write-Host ""
Write-Host ("Resumen: Registro {0:N0} entrada(s) exportada(s) | Archivos {1:N0} copiado(s) | Tamaño {2}" -f $regMetrics.TotalEntries, $fileCount, $sizeDisplay) -ForegroundColor Cyan
Write-Host ("Diagnostico escaneo: {0} ({1:N0} advertencia(s), {2:N0} observacion(es))" -f $scanDiagnostic.status, $scanDiagnostic.warnCount, $scanDiagnostic.infoCount) -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""
Pause
