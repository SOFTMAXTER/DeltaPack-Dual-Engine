<#
.SYNOPSIS
    DeltaPack Dual-Engine: Generador de Paquetes de Despliegue Offline (WIM + REG) con Auditoria Automatica.

.DESCRIPTION
    Esta suite de ingenieria inversa automatizada realiza capturas diferenciales (Snapshots) del sistema
    para empaquetar aplicaciones en formatos portables y desplegables.

    CARACTERISTICAS PRINCIPALES:
    1. Arquitectura Hibrida (C# + PowerShell): Utiliza un nucleo C# compilado en tiempo de ejecucion para
       escaneo de alto rendimiento, verificacion SafeUSN y saneamiento portable del Registro.
    2. Formato WIM (.wim): Genera contenedores WIM optimizados con maxima compresion.
    3. Abstraccion de Usuario: Detecta y neutraliza rutas absolutas (%USERPROFILE%) -> Users\Default.
    4. Sistema de Logging: Traza detallada con niveles de severidad y persistencia en disco.
    5. Robustez Windows 10/11: Exclusiones de telemetria, gestion de memoria GC y manejo de archivos bloqueados.
    6. Compatibilidad: PowerShell 5.1 y superior (PS7+ incluido). CIM nativo, sin dependencias WMI obsoletas.

.NOTES
    Version:        1.1.0
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
$script:Version = "1.1.0"

# Si el proceso se inicia en 32 bits, antes de tocar Registro o DISM se
# transfiere la ejecucion al Windows PowerShell nativo del sistema operativo.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $nativePowerShell = Join-Path $env:windir "Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or -not (Test-Path -LiteralPath $nativePowerShell -PathType Leaf)) {
        Write-Warning "No se pudo localizar Windows PowerShell nativo de 64 bits. La captura se cancela para evitar una vista parcial del Registro."
        Read-Host "Presiona Enter para salir."
        exit 1
    }

    $nativeArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $nativeProcess = Start-Process -FilePath $nativePowerShell -ArgumentList $nativeArgs -Wait -PassThru
    exit $nativeProcess.ExitCode
}

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

# Impide que dos instancias modifiquen simultaneamente el snapshot, Staging o
# RunOnce del mismo usuario. El mutex se libera automaticamente si el proceso
# termina de forma inesperada.
$currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutexCreated = $false
$mutexName = "Global\DeltaPackDualEngine-$($currentUserSid.Replace('-', '_'))"
try {
    $script:InstanceMutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$mutexCreated)
} catch {
    Write-Warning "No se pudo crear el bloqueo de instancia: $($_.Exception.Message)"
    Read-Host "Presiona Enter para salir."
    exit 1
}
if (-not $mutexCreated) {
    Write-Warning "Ya existe una captura DeltaPack activa para este usuario."
    Read-Host "Presiona Enter para salir."
    exit 1
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
        Write-Host "`n[!] El soporte global de rutas largas no esta habilitado." -ForegroundColor Yellow
        $enableLongPaths = Read-Host "Deseas habilitarlo ahora? (S/N)"
        if ($enableLongPaths -match '^(s|S)$') {
            Write-Host " -> [-] Habilitando soporte para rutas largas en el Registro..." -ForegroundColor Yellow
            Set-ItemProperty -Path $regPath -Name $name -Value 1 -Type DWord -Force -ErrorAction Stop
            Write-Host " -> [OK] Soporte habilitado exitosamente." -ForegroundColor Green
        } else {
            Write-Warning "Se continuara sin modificar LongPathsEnabled. Las rutas extensas pueden quedar como cobertura incompleta."
        }
    }
} catch {
    Write-Warning "No se pudo comprobar o habilitar el soporte para rutas largas de forma automatica."
    Write-Host "DeltaPack usara un directorio temporal corto y exclusivo en la unidad del sistema para reducir errores de DISM." -ForegroundColor Yellow
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

function Write-ValidatedJsonFile {
    param(
        [Parameter(Mandatory=$true)]$InputObject,
        [Parameter(Mandatory=$true)][string]$Path,
        [ValidateRange(2, 100)][int]$Depth = 8,
        [ValidateRange(1, 2147483647)][int]$ExpectedSchemaVersion = 1,
        [string[]]$RequiredProperties = @('schemaVersion')
    )

    $parentPath = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($parentPath) -or -not (Test-Path -LiteralPath $parentPath -PathType Container)) {
        throw "El directorio destino del JSON no existe: $parentPath"
    }

    $tempPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw 'La serializacion JSON produjo contenido vacio.'
        }

        $parsed = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        foreach ($requiredProperty in @($RequiredProperties)) {
            if ([string]::IsNullOrWhiteSpace($requiredProperty)) { continue }
            if ($null -eq $parsed.PSObject.Properties[$requiredProperty]) {
                throw "El JSON no contiene la propiedad obligatoria '$requiredProperty'."
            }
        }
        if ([int]$parsed.schemaVersion -ne $ExpectedSchemaVersion) {
            throw "schemaVersion invalido: se esperaba $ExpectedSchemaVersion y se obtuvo $($parsed.schemaVersion)."
        }

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)
        $writtenJson = [System.IO.File]::ReadAllText($tempPath, $utf8NoBom)
        if ([string]::IsNullOrWhiteSpace($writtenJson)) {
            throw 'El archivo JSON temporal quedo vacio.'
        }
        $null = ConvertFrom-Json -InputObject $writtenJson -ErrorAction Stop

        Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
        $publishedFile = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($publishedFile.Length -le 0) {
            throw 'El archivo JSON publicado quedo vacio.'
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-DeltaPackPackageIdentitySha256 {
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$BaseName,
        [Parameter(Mandatory=$true)][ValidateSet('x86','x64','arm64')][string]$Architecture,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$PackageType,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$FullName
    )

    $identityText = "schema=1`nbase=$BaseName`narchitecture=$Architecture`ntype=$PackageType`nfullName=$FullName"
    $identityBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($identityText)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($identityBytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Initialize-DeltaPackPackageIdentity {
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$BaseName,
        [Parameter(Mandatory=$true)][ValidateSet('x86','x64','arm64')][string]$Architecture,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$PackageType,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$FullName
    )

    foreach ($identityPart in @($BaseName, $PackageType, $FullName)) {
        if ($identityPart -ne $identityPart.Trim() -or
            $identityPart -match '[\\/:*?"<>|]' -or
            $identityPart.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "La identidad del paquete contiene un componente no seguro: '$identityPart'."
        }
    }

    $expectedFullName = "{0}_{1}_{2}" -f $BaseName, $Architecture, $PackageType
    if ($FullName -cne $expectedFullName) {
        throw "La identidad solicitada '$FullName' no coincide exactamente con '$expectedFullName'."
    }

    foreach ($constantName in @('DeltaPackPackageBaseName', 'DeltaPackPackageArchitecture', 'DeltaPackPackageType', 'DeltaPackPackageFullName', 'DeltaPackPackageIdentitySha256')) {
        if ($null -ne (Get-Variable -Name $constantName -Scope Script -ErrorAction SilentlyContinue)) {
            throw "La identidad canónica ya fue inicializada en esta ejecución: $constantName."
        }
    }

    $identitySha256 = Get-DeltaPackPackageIdentitySha256 -BaseName $BaseName -Architecture $Architecture -PackageType $PackageType -FullName $FullName
    Set-Variable -Name DeltaPackPackageBaseName -Scope Script -Value $BaseName -Option Constant
    Set-Variable -Name DeltaPackPackageArchitecture -Scope Script -Value $Architecture -Option Constant
    Set-Variable -Name DeltaPackPackageType -Scope Script -Value $PackageType -Option Constant
    Set-Variable -Name DeltaPackPackageFullName -Scope Script -Value $FullName -Option Constant
    Set-Variable -Name DeltaPackPackageIdentitySha256 -Scope Script -Value $identitySha256 -Option Constant

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        baseName = $script:DeltaPackPackageBaseName
        architecture = $script:DeltaPackPackageArchitecture
        type = $script:DeltaPackPackageType
        fullName = $script:DeltaPackPackageFullName
        sha256 = $script:DeltaPackPackageIdentitySha256
    }
}

function Assert-DeltaPackPackageIdentity {
    param([ValidateNotNullOrEmpty()][string]$Context = 'runtime')

    foreach ($constantName in @('DeltaPackPackageBaseName', 'DeltaPackPackageArchitecture', 'DeltaPackPackageType', 'DeltaPackPackageFullName', 'DeltaPackPackageIdentitySha256')) {
        if ($null -eq (Get-Variable -Name $constantName -Scope Script -ErrorAction SilentlyContinue)) {
            throw "Identidad canónica incompleta durante ${Context}: falta $constantName."
        }
    }

    $expectedFullName = "{0}_{1}_{2}" -f $script:DeltaPackPackageBaseName, $script:DeltaPackPackageArchitecture, $script:DeltaPackPackageType
    if ($script:DeltaPackPackageFullName -cne $expectedFullName) {
        throw "Identidad canónica alterada durante ${Context}: '$($script:DeltaPackPackageFullName)' != '$expectedFullName'."
    }
    $currentIdentityHash = Get-DeltaPackPackageIdentitySha256 -BaseName $script:DeltaPackPackageBaseName `
        -Architecture $script:DeltaPackPackageArchitecture -PackageType $script:DeltaPackPackageType -FullName $script:DeltaPackPackageFullName
    if ($currentIdentityHash -cne $script:DeltaPackPackageIdentitySha256) {
        throw "La huella de identidad del paquete cambió durante $Context."
    }

    return $true
}

function Assert-DeltaPackPackageArtifactSet {
    param(
        [Parameter(Mandatory=$true)][string]$OutputDirectory,
        [Parameter(Mandatory=$true)][string]$ManifestPath,
        [AllowNull()][string]$WimPath,
        [Parameter(Mandatory=$true)][string]$RegPath,
        [AllowNull()][string]$ChecksumsPath,
        [AllowNull()][string]$DeletionsPath,
        [AllowNull()][string]$ActionsPath,
        [Parameter(Mandatory=$true)][string]$ReadmePath,
        [Parameter(Mandatory=$true)][string]$ArtifactChecksumsPath
    )

    Assert-DeltaPackPackageIdentity -Context 'la validación cruzada de artefactos' | Out-Null
    $expectedByRole = [ordered]@{
        wimFile = "$($script:DeltaPackPackageFullName).wim"
        regFile = "$($script:DeltaPackPackageFullName).reg"
        checksumsFile = "Checksums_$($script:DeltaPackPackageFullName).sha256"
        deletionsFile = "Deletions_$($script:DeltaPackPackageFullName).json"
        actionsFile = "Actions_$($script:DeltaPackPackageFullName).json"
        readmeFile = "README_$($script:DeltaPackPackageFullName).md"
        manifestFile = "manifest_$($script:DeltaPackPackageFullName).json"
        artifactChecksumsFile = "Artifacts_$($script:DeltaPackPackageFullName).sha256"
    }
    $pathByRole = [ordered]@{
        wimFile = $WimPath
        regFile = $RegPath
        checksumsFile = $ChecksumsPath
        deletionsFile = $DeletionsPath
        actionsFile = $ActionsPath
        readmeFile = $ReadmePath
        manifestFile = $ManifestPath
        artifactChecksumsFile = $ArtifactChecksumsPath
    }

    foreach ($role in $pathByRole.Keys) {
        $artifactPath = [string]$pathByRole[$role]
        if ([string]::IsNullOrWhiteSpace($artifactPath)) { continue }
        if (-not (Test-PathWithin -Path $artifactPath -Parent $OutputDirectory)) {
            throw "El artefacto '$role' escapa del directorio de salida."
        }
        $actualLeaf = Split-Path $artifactPath -Leaf
        if ($actualLeaf -cne [string]$expectedByRole[$role]) {
            throw "Nombre inconsistente para ${role}: '$actualLeaf'; esperado '$($expectedByRole[$role])'."
        }
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([string]$manifest.package.fullName -cne $script:DeltaPackPackageFullName -or
        [string]$manifest.package.baseName -cne $script:DeltaPackPackageBaseName -or
        [string]$manifest.package.type -cne $script:DeltaPackPackageType -or
        [string]$manifest.package.architecture -cne $script:DeltaPackPackageArchitecture -or
        [string]$manifest.package.identitySha256 -cne $script:DeltaPackPackageIdentitySha256) {
        throw 'La identidad interna del manifest no coincide con la identidad canónica.'
    }

    foreach ($role in $expectedByRole.Keys) {
        $artifactPath = [string]$pathByRole[$role]
        $manifestLeaf = [string]$manifest.outputs.$role
        if ([string]::IsNullOrWhiteSpace($artifactPath)) {
            if (-not [string]::IsNullOrWhiteSpace($manifestLeaf)) {
                throw "El manifest declara '$manifestLeaf' para '$role', pero ese artefacto no existe."
            }
        } elseif ($manifestLeaf -cne [string]$expectedByRole[$role]) {
            throw "El manifest referencia '$manifestLeaf' para '$role'; se esperaba '$($expectedByRole[$role])'."
        }
    }

    foreach ($structuredPath in @($DeletionsPath, $ActionsPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$structuredPath)) { continue }
        $structuredObject = Get-Content -LiteralPath $structuredPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([int]$structuredObject.schemaVersion -ne 2 -or
            [string]$structuredObject.package.fullName -cne $script:DeltaPackPackageFullName -or
            [string]$structuredObject.package.identitySha256 -cne $script:DeltaPackPackageIdentitySha256) {
            throw "El schema o la identidad interna de '$(Split-Path $structuredPath -Leaf)' no coincide con la compilación actual."
        }
    }

    $readmeText = [System.IO.File]::ReadAllText($ReadmePath, [System.Text.Encoding]::UTF8)
    if ($readmeText.IndexOf("# Reporte de Paquete: $($script:DeltaPackPackageFullName)", [System.StringComparison]::Ordinal) -lt 0) {
        throw 'El reporte Markdown no contiene el encabezado de identidad canónico.'
    }
}

function Assert-DeltaPackArtifactChecksumIndex {
    param(
        [Parameter(Mandatory=$true)][string]$IndexPath,
        [Parameter(Mandatory=$true)][string]$OutputDirectory
    )

    $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($IndexPath, [System.Text.Encoding]::UTF8)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s{2}([^\\/:*?"<>|]+)$') {
            throw "Linea inválida en el índice de artefactos: $lineNumber."
        }
        $expectedHash = $Matches[1].ToLowerInvariant()
        $artifactLeaf = $Matches[2]
        if (-not $seenNames.Add($artifactLeaf)) {
            throw "Artefacto duplicado en el índice: $artifactLeaf."
        }
        $artifactPath = Join-Path $OutputDirectory $artifactLeaf
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Falta el artefacto indexado: $artifactLeaf."
        }
        $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actualHash -cne $expectedHash) {
            throw "SHA256 incorrecto para el artefacto: $artifactLeaf."
        }
    }
    if ($seenNames.Count -eq 0) {
        throw 'El índice de artefactos no contiene entradas.'
    }
}

function Enable-DeltaPackCapturePrivileges {
    $results = @([DiffEngine]::EnableRequiredCapturePrivileges())
    $failed = @($results | Where-Object { -not [bool]$_.Enabled })

    foreach ($result in $results) {
        if ([bool]$result.Enabled) {
            Write-Log ("Privilegio de captura habilitado: {0}" -f $result.Name) -Level SUCCESS
        } else {
            Write-Log ("Privilegio de captura no disponible: {0} (Win32={1}) - {2}" -f `
                $result.Name, $result.ErrorCode, $result.Message) -Level ERROR
        }
    }

    if ($failed.Count -gt 0) {
        throw ("La Captura Completa requiere SeBackupPrivilege, SeRestorePrivilege y SeCreateSymbolicLinkPrivilege. Faltan: {0}" -f `
            (($failed | ForEach-Object { [string]$_.Name }) -join ', '))
    }

    return $results
}

function Set-DeltaPackSecureDirectoryAcl {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    $readExecute = [System.Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize'

    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $adminsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($systemSid, $full, $inheritance, $propagation, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($adminsSid, $full, $inheritance, $propagation, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($userSid, $readExecute, $inheritance, $propagation, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Reset-DeltaPackStaging {
    param(
        [Parameter(Mandatory=$true)][string]$StagingPath,
        [Parameter(Mandatory=$true)][string]$WorkspacePath
    )

    $expected = Get-NormalizedFullPath -Path (Join-Path $WorkspacePath 'Staging')
    if ((Get-NormalizedFullPath -Path $StagingPath) -ne $expected) {
        throw "La ruta Staging no coincide con el workspace protegido."
    }
    if (Test-Path -LiteralPath $StagingPath) {
        Remove-Item -LiteralPath $StagingPath -Recurse -Force -ErrorAction Stop
    }
    New-Item -Path $StagingPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
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

function Invoke-DeltaPackWimCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ImagePath,
        [Parameter(Mandatory=$true)][string]$CapturePath,
        [Parameter(Mandatory=$true)][string]$ImageName,
        [Parameter(Mandatory=$true)][string]$ImageDescription,
        [Parameter(Mandatory=$true)][string]$LogPath,
        [Parameter(Mandatory=$true)][string]$ScratchDirectory
    )

    $captureJob = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastHeartbeatUtc = [DateTime]::MinValue

    try {
        # New-WindowsImage solo publica un ProgressRecord 0/100 durante muchas
        # capturas. Se ejecuta en un proceso de trabajo para que ese indicador
        # nativo no congele visualmente la consola principal. El padre informa
        # actividad comprobable (tiempo y bytes escritos), sin inventar un
        # porcentaje que WIMGAPI no expone de forma fiable.
        $captureJob = Start-Job -Name ("DeltaPackWim_" + [Guid]::NewGuid().ToString('N')) -ScriptBlock {
            param($JobImagePath, $JobCapturePath, $JobImageName, $JobDescription, $JobLogPath, $JobScratchDirectory)

            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            Import-Module Dism -ErrorAction Stop
            New-WindowsImage `
                -ImagePath        $JobImagePath `
                -CapturePath      $JobCapturePath `
                -Name             $JobImageName `
                -Description      $JobDescription `
                -CompressionType  'Max' `
                -Verify `
                -NoRpFix `
                -LogPath          $JobLogPath `
                -LogLevel         1 `
                -ScratchDirectory $JobScratchDirectory `
                -ErrorAction      Stop | Out-Null
        } -ArgumentList @($ImagePath, $CapturePath, $ImageName, $ImageDescription, $LogPath, $ScratchDirectory)

        if ($null -eq $captureJob) {
            throw 'No se pudo iniciar el proceso de trabajo para DISM/WIMGAPI.'
        }

        while ([string]$captureJob.State -in @('NotStarted', 'Running')) {
            [int64]$currentWimBytes = 0
            try {
                if (Test-Path -LiteralPath $ImagePath -PathType Leaf) {
                    $currentWimBytes = [int64](Get-Item -LiteralPath $ImagePath -Force -ErrorAction Stop).Length
                }
            } catch { }

            $elapsedLabel = ("{0:hh\:mm\:ss}" -f $stopwatch.Elapsed)
            $sizeLabel = Format-ByteSize -Bytes $currentWimBytes
            $currentOperation = if ($currentWimBytes -gt 0) {
                "Comprimiendo y verificando; WIM escrito: $sizeLabel"
            } else {
                'Inicializando DISM/WIMGAPI y enumerando Staging'
            }
            $status = "En curso | Tiempo: $elapsedLabel | $currentOperation"

            Write-Progress -Activity 'Generando paquete WIM (actividad comprobable)' `
                -Status $status -CurrentOperation 'El porcentaje nativo no es fiable.' `
                -PercentComplete -1

            $nowUtc = [DateTime]::UtcNow
            if (($nowUtc - $lastHeartbeatUtc).TotalSeconds -ge 60) {
                Write-Host (" -> WIM en curso | Tiempo: {0} | Escrito: {1}" -f $elapsedLabel, $sizeLabel) -ForegroundColor DarkGray
                $lastHeartbeatUtc = $nowUtc
            }

            Start-Sleep -Milliseconds 1000
        }

        Write-Progress -Activity 'Generando paquete WIM (actividad comprobable)' -Completed
        $jobState = [string]$captureJob.State
        $jobFailureReason = $captureJob.ChildJobs[0].JobStateInfo.Reason
        $jobErrorText = @($captureJob.ChildJobs[0].Error | ForEach-Object { [string]$_ }) -join ' | '
        Receive-Job -Job $captureJob -ErrorAction SilentlyContinue | Out-Null

        if ($jobState -ne 'Completed') {
            $failureDetail = if (-not [string]::IsNullOrWhiteSpace($jobErrorText)) {
                $jobErrorText
            } elseif ($null -ne $jobFailureReason) {
                [string]$jobFailureReason.Message
            } else {
                "Estado del proceso de trabajo: $jobState"
            }
            throw "DISM/WIMGAPI no completo la captura: $failureDetail"
        }

        if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
            throw 'DISM/WIMGAPI termino sin publicar el archivo WIM esperado.'
        }
        [int64]$finalWimBytes = [int64](Get-Item -LiteralPath $ImagePath -Force -ErrorAction Stop).Length
        if ($finalWimBytes -le 0) {
            throw 'DISM/WIMGAPI publico un archivo WIM vacio.'
        }

        return [pscustomobject]@{
            elapsedMilliseconds = [int64]$stopwatch.ElapsedMilliseconds
            elapsed             = ("{0:hh\:mm\:ss\.fff}" -f $stopwatch.Elapsed)
            finalSizeBytes       = $finalWimBytes
            progressMode        = 'indeterminateHeartbeat'
        }
    } finally {
        Write-Progress -Activity 'Generando paquete WIM (actividad comprobable)' -Completed
        if ($stopwatch.IsRunning) { $stopwatch.Stop() }
        if ($null -ne $captureJob) {
            if ([string]$captureJob.State -in @('NotStarted', 'Running')) {
                Stop-Job -Job $captureJob -ErrorAction SilentlyContinue
            }
            Remove-Job -Job $captureJob -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-PendingRebootIndicators {
    $indicators = New-Object 'System.Collections.Generic.List[string]'

    $pendingKeys = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'; Label = 'Component Based Servicing: RebootPending' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'; Label = 'Windows Update: RebootRequired' }
    )
    foreach ($item in $pendingKeys) {
        try {
            if (Test-Path -LiteralPath $item.Path) { $indicators.Add([string]$item.Label) | Out-Null }
        } catch { }
    }

    try {
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
        foreach ($valueName in @('PendingFileRenameOperations', 'PendingFileRenameOperations2')) {
            $pendingRenames = $sessionManager.$valueName
            if ($null -ne $pendingRenames -and @($pendingRenames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
                $indicators.Add("Session Manager: $valueName") | Out-Null
            }
        }
    } catch { }

    try {
        $updates = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Updates' -Name 'UpdateExeVolatile' -ErrorAction SilentlyContinue
        if ($null -ne $updates -and [int64]$updates.UpdateExeVolatile -ne 0) {
            $indicators.Add('Microsoft Updates: UpdateExeVolatile') | Out-Null
        }
    } catch { }

    return @($indicators | Sort-Object -Unique)
}

function Convert-ToWindowsRelativePathForPolicy {
    param([Parameter(Mandatory=$true)][string]$Path)

    $normalized = $Path.Replace('/', '\')
    $windowsRoot = ([string]$env:windir).TrimEnd('\')
    if (-not [string]::IsNullOrWhiteSpace($windowsRoot) -and
        $normalized.StartsWith($windowsRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'Windows\' + $normalized.Substring($windowsRoot.Length + 1)
    }

    $marker = '\Windows\'
    $markerIndex = $normalized.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
    if ($markerIndex -ge 0) {
        return 'Windows\' + $normalized.Substring($markerIndex + $marker.Length)
    }

    if ($normalized -match '^[A-Za-z]:\\') {
        return $normalized.Substring(3)
    }

    return $normalized.TrimStart('\')
}

function Test-ProtectedSystemMutationPath {
    param([Parameter(Mandatory=$true)][string]$Path)

    $relativePath = Convert-ToWindowsRelativePathForPolicy -Path $Path
    $policyPath = '\' + $relativePath.TrimStart('\')
    foreach ($protectedPrefix in @(
        '\Windows\System32\CatRoot\',
        '\Windows\System32\drivers\wd\',
        '\Windows\System32\Pbr\'
    )) {
        $protectedRoot = $protectedPrefix.TrimEnd('\')
        if ($policyPath.Equals($protectedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $policyPath.StartsWith($protectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }

    if ($policyPath.Equals('\Windows\System32\mstask.dll', [System.StringComparison]::OrdinalIgnoreCase) -or
        $policyPath.Equals('\Windows\System32\ntkrla57.exe', [System.StringComparison]::OrdinalIgnoreCase) -or
        $policyPath.Equals('\Windows\System32\securekernella57.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return ($relativePath -match '(?i)^Windows\\System32\\[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
}

function Get-ProtectedSystemMutationDiagnostic {
    param(
        [AllowNull()][object[]]$Paths = @(),
        [Parameter(Mandatory=$true)]$PreEngine,
        [Parameter(Mandatory=$true)]$PostEngine,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$PackageName
    )

    $blockingPaths = New-Object 'System.Collections.Generic.List[string]'
    $metadataOnlyPaths = New-Object 'System.Collections.Generic.List[string]'
    $metadataOnlySourcePaths = New-Object 'System.Collections.Generic.List[string]'
    $correlatedPaths = New-Object 'System.Collections.Generic.List[string]'
    $specializedActionPaths = New-Object 'System.Collections.Generic.List[string]'
    $evaluations = New-Object 'System.Collections.Generic.List[object]'

    $relativeCandidates = @(@($Paths) | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace([string]$_)) {
            Convert-ToWindowsRelativePathForPolicy -Path ([string]$_)
        }
    })
    $packageTokens = @([regex]::Matches($PackageName, '[A-Za-z0-9]{4,}') | ForEach-Object { $_.Value.ToLowerInvariant() } | Sort-Object -Unique)
    $packageCatalogPaths = @($relativeCandidates | Where-Object {
        $candidateCatalogPath = [string]$_
        if ($candidateCatalogPath -notmatch '(?i)^Windows\\System32\\CatRoot\\\{[0-9A-F-]+\}\\.+\.cat$' -or
            $candidateCatalogPath -match '(?i)\\oem\d+\.cat$') { return $false }
        $catalogLeaf = (Split-Path $candidateCatalogPath -Leaf).ToLowerInvariant()
        foreach ($packageToken in $packageTokens) {
            if ($catalogLeaf.IndexOf($packageToken, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
        return $false
    })
    $hasPackageCatalog = $packageCatalogPaths.Count -gt 0
    $hasDriverInf = @($relativeCandidates | Where-Object {
        $_ -match '(?i)^Windows\\System32\\DriverStore\\FileRepository\\.+\.inf$'
    }).Count -gt 0
    $hasCorrelatedOemCatalog = ($hasDriverInf -and @($relativeCandidates | Where-Object {
        $_ -match '(?i)^Windows\\System32\\CatRoot\\\{[0-9A-F-]+\}\\oem\d+\.cat$'
    }).Count -gt 0)

    foreach ($candidatePath in @($Paths)) {
        $candidate = [string]$candidatePath
        if ([string]::IsNullOrWhiteSpace($candidate) -or
            -not (Test-ProtectedSystemMutationPath -Path $candidate)) { continue }

        $relativePath = Convert-ToWindowsRelativePathForPolicy -Path $candidate
        $changeKind = [DiffEngine]::GetFileMutationKind($PreEngine, $PostEngine, $candidate)
        $metadataOnly = $changeKind -eq 'MetadataOnly'
        $catalogPayloadAvailable = $changeKind -in @('Added', 'ContentChanged')
        $correlationReason = $null
        $requiresSpecializedAction = $false

        if ($catalogPayloadAvailable -and $relativePath -match '(?i)^Windows\\System32\\CatRoot\\\{[0-9A-F-]+\}\\.+\.cat$' -and
            $relativePath -notmatch '(?i)\\oem\d+\.cat$') {
            $catalogLeaf = (Split-Path $relativePath -Leaf).ToLowerInvariant()
            $catalogMatchesPackage = $false
            foreach ($packageToken in $packageTokens) {
                if ($catalogLeaf.IndexOf($packageToken, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $catalogMatchesPackage = $true
                    break
                }
            }
            if ($catalogMatchesPackage) {
                $correlationReason = "Catalogo firmado cuyo nombre contiene un token de la aplicacion capturada: $PackageName."
                $requiresSpecializedAction = $true
            }
        } elseif ($catalogPayloadAvailable -and $relativePath -match '(?i)^Windows\\System32\\CatRoot\\\{[0-9A-F-]+\}\\oem\d+\.cat$' -and $hasDriverInf) {
            $correlationReason = 'Catalogo OEM correlacionado con un INF nuevo o modificado en DriverStore.'
            $requiresSpecializedAction = $true
        } elseif ($changeKind -in @('Added', 'DirectoryMetadataChanged') -and
                  $relativePath -match '(?i)^Windows\\System32\\CatRoot\\\{[0-9A-F-]+\}$' -and
                  ($hasPackageCatalog -or $hasCorrelatedOemCatalog)) {
            $correlationReason = 'Directorio CatRoot modificado como consecuencia de catalogos correlacionados del instalador.'
        }

        if ($metadataOnly) {
            $metadataOnlyPaths.Add($relativePath) | Out-Null
            $metadataOnlySourcePaths.Add($candidate) | Out-Null
        } elseif (-not [string]::IsNullOrWhiteSpace($correlationReason)) {
            $correlatedPaths.Add($relativePath) | Out-Null
            if ($requiresSpecializedAction) {
                $specializedActionPaths.Add($relativePath) | Out-Null
            }
        } else {
            # Added, Deleted, ContentChanged y Unknown permanecen fail-closed.
            $blockingPaths.Add($relativePath) | Out-Null
        }

        $evaluations.Add([pscustomobject][ordered]@{
            path       = $relativePath
            changeKind = $changeKind
            classification = if ($metadataOnly) { 'metadataOnly' } elseif ($correlationReason) { 'installerCorrelated' } else { 'blocking' }
            correlationReason = $correlationReason
            requiresSpecializedAction = $requiresSpecializedAction
            blocking   = (-not $metadataOnly -and [string]::IsNullOrWhiteSpace($correlationReason))
        }) | Out-Null
    }

    return [pscustomobject][ordered]@{
        blockingPaths           = @($blockingPaths | Sort-Object -Unique)
        metadataOnlyPaths       = @($metadataOnlyPaths | Sort-Object -Unique)
        metadataOnlySourcePaths = @($metadataOnlySourcePaths | Sort-Object -Unique)
        correlatedPaths         = @($correlatedPaths | Sort-Object -Unique)
        specializedActionPaths  = @($specializedActionPaths | Sort-Object -Unique)
        evaluations             = @($evaluations | Sort-Object path -Unique)
        policy                  = 'sameSha256MetadataAudit;packageTokenAndDriverCatalogCorrelation;otherwiseFailClosed'
    }
}

function Get-DeltaPackDeletionAuditClassification {
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$RelativePath,
        [Parameter(Mandatory=$true)][ValidateSet('file','directory')][string]$Kind,
        [AllowNull()][object[]]$Rules = @()
    )

    foreach ($ruleGroup in @($Rules)) {
        $category = [string]$ruleGroup.category
        foreach ($pattern in @($ruleGroup.patterns)) {
            $patternText = [string]$pattern
            if ([string]::IsNullOrWhiteSpace($patternText)) { continue }
            if ([regex]::IsMatch($RelativePath, $patternText, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                return [pscustomobject][ordered]@{
                    operation = 'audit'
                    kind = $Kind
                    path = $RelativePath
                    category = $category
                    pattern = $patternText
                    reason = if ([string]::IsNullOrWhiteSpace([string]$ruleGroup.reason)) { 'Cambio de mantenimiento ambiental conocido; no se ejecuta como tombstone del paquete.' } else { [string]$ruleGroup.reason }
                }
            }
        }
    }
    return $null
}

function Get-ManagedRuntimeMaintenanceDiagnostic {
    param(
        [AllowNull()][object[]]$ChangedPaths = @(),
        [AllowNull()][object[]]$DeletedPaths = @(),
        [ValidateSet('failClosed','includeWhenDetected')][string]$Policy = 'failClosed'
    )

    # SetupMetrics se excluye declarativamente antes del diff porque es telemetria
    # de instalacion. Solo una migracion versionada de gran volumen llega aqui y
    # activa el bloqueo fail-closed.
    $minimumVersionedMutations = 100
    $familyStats = [ordered]@{
        Edge         = [ordered]@{ changedCount = 0; deletedCount = 0; versionedMutationCount = 0 }
        EdgeCore     = [ordered]@{ changedCount = 0; deletedCount = 0; versionedMutationCount = 0 }
        EdgeWebView  = [ordered]@{ changedCount = 0; deletedCount = 0; versionedMutationCount = 0 }
    }
    $managedPaths = New-Object 'System.Collections.Generic.List[string]'

    $candidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidatePath in @($ChangedPaths)) {
        $candidates.Add([pscustomobject]@{ path = [string]$candidatePath; operation = "changed" }) | Out-Null
    }
    foreach ($candidatePath in @($DeletedPaths)) {
        $candidates.Add([pscustomobject]@{ path = [string]$candidatePath; operation = "deleted" }) | Out-Null
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.path)) { continue }
        $relativePath = Convert-ToWindowsRelativePathForPolicy -Path $candidate.path
        if ($relativePath -match '(?i)^Program Files(?: \(x86\))?\\Microsoft\\(Edge|EdgeCore|EdgeWebView)\\') {
            $familyToken = $Matches[1]
        } else {
            continue
        }

        $family = switch ($familyToken.ToLowerInvariant()) {
            "edge"        { "Edge" }
            "edgecore"    { "EdgeCore" }
            "edgewebview" { "EdgeWebView" }
        }
        if ([string]::IsNullOrWhiteSpace($family)) { continue }

        $managedPaths.Add($relativePath) | Out-Null
        if ($candidate.operation -eq "deleted") {
            $familyStats[$family].deletedCount = [int]$familyStats[$family].deletedCount + 1
        } else {
            $familyStats[$family].changedCount = [int]$familyStats[$family].changedCount + 1
        }

        if ($relativePath -match '(?i)^Program Files(?: \(x86\))?\\Microsoft\\(?:Edge\\Application|EdgeCore|EdgeWebView\\Application)\\\d+(?:\.\d+){2,3}(?:\\|$)') {
            $familyStats[$family].versionedMutationCount = [int]$familyStats[$family].versionedMutationCount + 1
        }
    }

    $familyResults = @()
    $changedCount = 0
    $deletedCount = 0
    $versionedMutationCount = 0
    foreach ($familyName in $familyStats.Keys) {
        $familyStat = $familyStats[$familyName]
        $changedCount += [int]$familyStat.changedCount
        $deletedCount += [int]$familyStat.deletedCount
        $versionedMutationCount += [int]$familyStat.versionedMutationCount
        if (([int]$familyStat.changedCount + [int]$familyStat.deletedCount) -gt 0) {
            $familyResults += [pscustomobject][ordered]@{
                name                   = $familyName
                changedCount           = [int]$familyStat.changedCount
                deletedCount           = [int]$familyStat.deletedCount
                versionedMutationCount = [int]$familyStat.versionedMutationCount
            }
        }
    }

    $samplePaths = @($managedPaths | Sort-Object -Unique | Select-Object -First 25)
    return [pscustomobject][ordered]@{
        detected                    = ($versionedMutationCount -ge $minimumVersionedMutations)
        blocking                    = (($versionedMutationCount -ge $minimumVersionedMutations) -and $Policy -eq 'failClosed')
        policy                      = $Policy
        thresholdVersionedMutations = $minimumVersionedMutations
        mutationCount               = ($changedCount + $deletedCount)
        versionedMutationCount      = $versionedMutationCount
        changedCount                = $changedCount
        deletedCount                = $deletedCount
        families                    = @($familyResults)
        samplePaths                 = @($samplePaths)
        note                        = if ($Policy -eq 'failClosed') { "SetupMetrics se excluye como telemetria; una migracion versionada masiva de Edge, EdgeCore o WebView2 bloquea Staging, VSS y WIM." } else { "La captura declaro intencionalmente la instalacion o actualizacion de Edge/WebView2; las mutaciones de runtime se incluyen y permanecen auditadas, pero SetupMetrics sigue excluido." }
    }
}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Parent
    )

    $candidate = Get-NormalizedFullPath -Path $Path
    $root      = Get-NormalizedFullPath -Path $Parent
    return $candidate.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Convert-ToPortableRelativePath {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)][string]$CurrentUserProfileRelative
    )

    $sourceFull = Get-NormalizedFullPath -Path $SourcePath
    if (-not [string]::IsNullOrWhiteSpace($script:DesktopRoot)) {
        $desktopFull = Get-NormalizedFullPath -Path $script:DesktopRoot
        if ($sourceFull.Equals($desktopFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return "Users\Default\Desktop"
        }
        if ($sourceFull.StartsWith($desktopFull + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
            return "Users\Default\Desktop" + $sourceFull.Substring($desktopFull.Length)
        }
    }

    $relative = Split-Path $SourcePath -NoQualifier
    $relative = $relative.TrimStart('\', '/')
    $profile  = $CurrentUserProfileRelative.TrimEnd('\', '/')

    if ($relative.Equals($profile, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "Users\Default"
    }
    if ($relative.StartsWith($profile + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "Users\Default" + $relative.Substring($profile.Length)
    }
    return $relative
}

function Get-SnapshotSha256 {
    param(
        [Parameter(Mandatory=$true)]$Engine,
        [Parameter(Mandatory=$true)][string]$Path
    )

    if (-not $Engine.FileSnapshot.ContainsKey($Path)) { return $null }
    return [DiffEngine]::GetSha256FromFingerprint([string]$Engine.FileSnapshot[$Path])
}

function Get-DeltaPackEngineIdentity {
    $scriptPath = [string]$PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = Join-Path $PSScriptRoot 'DeltaPackDual-Engine.ps1'
    }
    $enginePath = Join-Path $PSScriptRoot 'DiffEngine.cs'
    $exclusionsIdentityPath = Join-Path $PSScriptRoot 'DeltaPack.Exclusions.json'
    foreach ($requiredPath in @($scriptPath, $enginePath, $exclusionsIdentityPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "No se puede calcular la identidad del motor porque falta: $requiredPath"
        }
    }

    return [pscustomobject][ordered]@{
        schemaVersion    = 1
        scriptSha256     = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        diffEngineSha256 = (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        exclusionsSha256 = (Get-FileHash -LiteralPath $exclusionsIdentityPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }
}

function Assert-ResumeConfiguration {
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$StatePath
    )

    if ($null -eq $Config) {
        throw "La configuracion de reanudacion esta vacia."
    }

    foreach ($requiredField in @("configSchemaVersion", "pkgName", "finalPkgName", "archTag", "sufijo", "packageIdentitySha256", "outDir", "workspaceDir", "stagingDir", "LogPath", "scriptVersion", "scriptSha256", "stateSha256", "engineSha256", "exclusionsSha256")) {
        if ([string]::IsNullOrWhiteSpace([string]$Config.$requiredField)) {
            throw "La configuracion de reanudacion no contiene el campo obligatorio '$requiredField'."
        }
    }

    try {
        $configSchemaVersion = [int]$Config.configSchemaVersion
    } catch {
        throw "La version del schema de reanudacion no es valida."
    }
    if ($configSchemaVersion -ne 3) {
        throw "La captura guardada no usa el schema de reanudacion requerido por esta compilacion."
    }

    if (([string]$Config.pkgName -match '[\\/:*?"<>|]') -or
        ([string]$Config.sufijo -match '[\\/:*?"<>|]') -or
        ([string]$Config.finalPkgName -match '[\\/:*?"<>|]')) {
        throw "La configuracion de reanudacion contiene caracteres de ruta no permitidos."
    }
    if (([string]$Config.finalPkgName).IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        [string]$Config.finalPkgName -ne ([string]$Config.finalPkgName).Trim()) {
        throw "El nombre final guardado no es un nombre de archivo seguro."
    }

    if ([string]$Config.archTag -notin @("x86", "x64", "arm64")) {
        throw "La arquitectura guardada no es valida."
    }
    $expectedPackageName = "{0}_{1}_{2}" -f ([string]$Config.pkgName), ([string]$Config.archTag), ([string]$Config.sufijo)
    if ([string]$Config.finalPkgName -cne $expectedPackageName) {
        throw "El nombre final guardado no coincide con sus componentes."
    }
    $expectedPackageIdentitySha256 = Get-DeltaPackPackageIdentitySha256 -BaseName ([string]$Config.pkgName) `
        -Architecture ([string]$Config.archTag) -PackageType ([string]$Config.sufijo) -FullName ([string]$Config.finalPkgName)
    if ([string]$Config.packageIdentitySha256 -cne $expectedPackageIdentitySha256) {
        throw "La identidad canónica guardada fue alterada o no corresponde al paquete."
    }
    if ([string]$Config.scriptVersion -ne $script:Version -or
        -not [bool]$Config.hashAllFiles -or
        [bool]$Config.useUsnOptimization -ne [bool][DiffEngine]::UseUsnOptimization) {
        throw "La captura fue creada con una version o politica de verificacion incompatible."
    }
    if ([string]$Config.stateSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
        -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "El snapshot guardado no tiene una referencia de integridad valida."
    }
    $actualStateHash = (Get-FileHash -LiteralPath $StatePath -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actualStateHash -ne [string]$Config.stateSha256) {
        throw "El snapshot guardado esta incompleto o fue modificado."
    }

    $scriptPathForResume = if ([string]::IsNullOrWhiteSpace([string]$PSCommandPath)) { Join-Path $PSScriptRoot 'DeltaPackDual-Engine.ps1' } else { [string]$PSCommandPath }
    $enginePath = Join-Path $PSScriptRoot 'DiffEngine.cs'
    $exclusionsPathForResume = Join-Path $PSScriptRoot 'DeltaPack.Exclusions.json'
    if (-not (Test-Path -LiteralPath $scriptPathForResume -PathType Leaf) -or
        -not (Test-Path -LiteralPath $enginePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $exclusionsPathForResume -PathType Leaf)) {
        throw "Faltan archivos obligatorios del motor para reanudar la captura."
    }
    $currentScriptHash = (Get-FileHash -LiteralPath $scriptPathForResume -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $savedScriptHash = ([string]$Config.scriptSha256).ToLowerInvariant()
    if ($savedScriptHash -notmatch '^[0-9a-f]{64}$') {
        throw "La huella PS1 guardada no es valida."
    }
    if ($savedScriptHash -ne $currentScriptHash) {
        throw "El script PowerShell no coincide exactamente con el que creo el snapshot inicial. Inicia una captura nueva."
    }
    $currentEngineHash = (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $savedEngineHash = ([string]$Config.engineSha256).ToLowerInvariant()
    if ($savedEngineHash -ne $currentEngineHash) {
        throw "DiffEngine.cs no coincide exactamente con el que creo el snapshot inicial. Inicia una captura nueva."
    }
    $currentExclusionsHash = (Get-FileHash -LiteralPath $exclusionsPathForResume -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $savedExclusionsHash = ([string]$Config.exclusionsSha256).ToLowerInvariant()
    if ($savedExclusionsHash -ne $currentExclusionsHash) {
        throw "DeltaPack.Exclusions.json no coincide exactamente con el que creo el snapshot inicial. Inicia una captura nueva."
    }

    $desktop     = Get-NormalizedFullPath -Path $script:DesktopRoot
    $outDirSafe  = Get-NormalizedFullPath -Path ([string]$Config.outDir)
    $outParent   = Get-NormalizedFullPath -Path (Split-Path $outDirSafe -Parent)
    $outLeaf     = Split-Path $outDirSafe -Leaf
    $expected    = "DeltaPack_$([string]$Config.finalPkgName)"
    $validLeaf   = ($outLeaf -eq $expected) -or ($outLeaf -match ('^' + [regex]::Escape($expected) + '_\d{8}_\d{6}(?:_\d+)?$'))

    if ($outParent -ne $desktop -or -not $validLeaf) {
        throw "La ruta de salida guardada no pertenece al Escritorio o no coincide con el paquete."
    }

    $workspaceSafe = Get-NormalizedFullPath -Path ([string]$Config.workspaceDir)
    $stateParent = Get-NormalizedFullPath -Path (Split-Path $StatePath -Parent)
    if ($workspaceSafe -ne $stateParent) {
        throw "La ruta de workspace guardada no coincide con el snapshot."
    }
    $programDataCaptureRoot = Get-NormalizedFullPath -Path (Join-Path $env:ProgramData 'DeltaPack\Captures')
    if (-not (Test-PathWithin -Path $workspaceSafe -Parent $programDataCaptureRoot)) {
        throw "El workspace guardado no pertenece a ProgramData\DeltaPack\Captures."
    }

    $expectedStaging = Get-NormalizedFullPath -Path (Join-Path $workspaceSafe "Staging")
    $expectedLog     = Get-NormalizedFullPath -Path (Join-Path $outDirSafe "Install_Log.txt")
    if ((Get-NormalizedFullPath -Path ([string]$Config.stagingDir)) -ne $expectedStaging) {
        throw "La ruta Staging guardada fue alterada."
    }
    if ((Get-NormalizedFullPath -Path ([string]$Config.LogPath)) -ne $expectedLog) {
        throw "La ruta del log guardada fue alterada."
    }
    if (-not (Test-Path -LiteralPath $outDirSafe -PathType Container) -or
        -not (Test-Path -LiteralPath $workspaceSafe -PathType Container) -or
        -not (Test-Path -LiteralPath $expectedStaging -PathType Container)) {
        throw "La carpeta de salida, workspace o Staging de la captura ya no existe."
    }

    return $true
}

function Write-FileCopyProgress {
    param(
        [Parameter(Mandatory=$true)][int]$Processed,
        [Parameter(Mandatory=$true)][int]$Total,
        [Parameter(Mandatory=$true)][int]$Copied,
        [Parameter(Mandatory=$true)][Int64]$Bytes,
        [AllowNull()][string]$CurrentFile,
        [int]$Failures = 0,
        [int]$ReparseStaged = 0,
        [int]$ReparseTotal = 0,
        [switch]$Completed
    )

    if ($Total -le 0) { return }

    if ($Completed) {
        Write-Progress -Activity "Copiando archivos al Staging" -Completed
        $completionColor = if ($Failures -eq 0 -and $ReparseStaged -eq $ReparseTotal) { 'DarkGray' } else { 'Yellow' }
        Write-Host (" -> Staging: archivos regulares {0:N0}/{1:N0} | reparse {2:N0}/{3:N0} | incidencias {4:N0} | {5}" -f `
            $Copied, $Total, $ReparseStaged, $ReparseTotal, $Failures, (Format-ByteSize -Bytes $Bytes)) -ForegroundColor $completionColor
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

function Get-RegistryCoverageDiagnostic {
    param(
        [AllowNull()][object[]]$PreErrors = @(),
        [AllowNull()][object[]]$PostErrors = @()
    )

    $preSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $postSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($PreErrors))  { if (-not [string]::IsNullOrWhiteSpace([string]$path)) { [void]$preSet.Add([string]$path) } }
    foreach ($path in @($PostErrors)) { if (-not [string]::IsNullOrWhiteSpace([string]$path)) { [void]$postSet.Add([string]$path) } }

    $stableKnownGaps = New-Object 'System.Collections.Generic.List[string]'
    $blockingPaths = New-Object 'System.Collections.Generic.List[string]'
    $allPaths = @(@($preSet) + @($postSet) | Sort-Object -Unique)
    foreach ($path in $allPaths) {
        $presentInBoth = ($preSet.Contains($path) -and $postSet.Contains($path))
        $isStableProtectedDeviceProperty = $path -match '(?i)^HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\Class\\\{[0-9A-F-]+\}\\(?:Properties|Configuration\\Reset\\(?:Properties|Driver|Instance|Device))$'
        if ($presentInBoth -and $isStableProtectedDeviceProperty) {
            $stableKnownGaps.Add($path) | Out-Null
        } else {
            $blockingPaths.Add($path) | Out-Null
        }
    }

    return [pscustomobject][ordered]@{
        coverageComplete = ($blockingPaths.Count -eq 0)
        blockingCount    = $blockingPaths.Count
        blockingPaths    = @($blockingPaths | Sort-Object -Unique)
        stableKnownGapCount = $stableKnownGaps.Count
        stableKnownGaps  = @($stableKnownGaps | Sort-Object -Unique)
        sameErrorSet     = ($preSet.SetEquals($postSet))
        policy           = 'stableProtectedDevicePropertiesAreKnownGaps;unexpectedOrAsymmetricErrorsBlock'
        note             = 'Las ramas Class\\{GUID}\\Properties protegidas e inaccesibles en ambos snapshots se conservan como brecha conocida. Todo error nuevo, desaparecido o fuera de esa forma sigue siendo bloqueante.'
    }
}

function Get-RegPortabilityDiagnostic {
    param([Parameter(Mandatory=$true)][string]$Path)

    $machineName = [string]$env:COMPUTERNAME
    $captureProfile = ([string]$env:USERPROFILE).TrimEnd('\')
    $captureSid = [string]$currentUserSid
    $sourceDrive = ([string]$env:SystemDrive).TrimEnd('\')
    $machineReferences = New-Object 'System.Collections.Generic.List[string]'
    $captureIdentityReferences = New-Object 'System.Collections.Generic.List[string]'
    $absoluteNameReferences = New-Object 'System.Collections.Generic.List[string]'
    $stream = $null
    $currentSection = ''

    try {
        $stream = [System.IO.StreamReader]::new($Path, [System.Text.Encoding]::Unicode)
        while ($null -ne ($line = $stream.ReadLine())) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) {
                $currentSection = $trimmed.Substring(1, $trimmed.Length - 2)
                if (-not [string]::IsNullOrWhiteSpace($machineName) -and $currentSection.IndexOf($machineName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $machineReferences.Add("Clave: $currentSection") | Out-Null
                }
                if ((-not [string]::IsNullOrWhiteSpace($captureProfile) -and $currentSection.IndexOf($captureProfile, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                    (-not [string]::IsNullOrWhiteSpace($captureSid) -and $currentSection.IndexOf($captureSid, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                    $captureIdentityReferences.Add("Clave: $currentSection") | Out-Null
                }
                continue
            }

            $separator = $trimmed.IndexOf('=')
            if ($separator -lt 1) { continue }
            $nameToken = $trimmed.Substring(0, $separator)
            $dataToken = $trimmed.Substring($separator + 1)
            $decodedName = if ($nameToken.StartsWith('"') -and $nameToken.EndsWith('"')) {
                $nameToken.Substring(1, $nameToken.Length - 2).Replace('\\', '\').Replace('\"', '"')
            } else { $nameToken }
            $decodedData = $dataToken

            if ($dataToken.StartsWith('"') -and $dataToken.EndsWith('"')) {
                $decodedData = $dataToken.Substring(1, $dataToken.Length - 2).Replace('\\', '\').Replace('\"', '"')
            } elseif ($dataToken -match '(?i)^hex\((1|2|7)\):(.+)$') {
                try {
                    $bytes = @($Matches[2].Split(',') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [Convert]::ToByte($_.Trim(), 16) })
                    if (($bytes.Count % 2) -eq 0) {
                        $decodedData = [System.Text.Encoding]::Unicode.GetString([byte[]]$bytes).TrimEnd([char]0)
                    }
                } catch { }
            }

            $location = "$currentSection -> $decodedName"
            foreach ($text in @($decodedName, $decodedData)) {
                if (-not [string]::IsNullOrWhiteSpace($machineName) -and $text.IndexOf($machineName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $machineReferences.Add($location) | Out-Null
                    break
                }
            }
            foreach ($text in @($decodedName, $decodedData)) {
                if ((-not [string]::IsNullOrWhiteSpace($captureProfile) -and $text.IndexOf($captureProfile, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                    (-not [string]::IsNullOrWhiteSpace($captureSid) -and $text.IndexOf($captureSid, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                    $captureIdentityReferences.Add($location) | Out-Null
                    break
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($sourceDrive) -and $decodedName.StartsWith($sourceDrive + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                $absoluteNameReferences.Add($location) | Out-Null
            }
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    return [pscustomobject][ordered]@{
        blocking = (($machineReferences.Count + $captureIdentityReferences.Count) -gt 0)
        machineNameReferenceCount = $machineReferences.Count
        machineNameReferences = @($machineReferences | Sort-Object -Unique | Select-Object -First 25)
        captureIdentityReferenceCount = $captureIdentityReferences.Count
        captureIdentityReferences = @($captureIdentityReferences | Sort-Object -Unique | Select-Object -First 25)
        absoluteSourceDriveNameCount = $absoluteNameReferences.Count
        absoluteSourceDriveNameReferences = @($absoluteNameReferences | Sort-Object -Unique | Select-Object -First 25)
        sourceSystemDrive = $sourceDrive
        requiresSameSystemDrive = ($absoluteNameReferences.Count -gt 0)
        binaryValueNote = 'Los valores REG_BINARY opacos no pueden sanearse de forma universal; deben revisarse si contienen identidad o rutas embebidas.'
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
            filesRecoveredByVss = 0
            filesVerifiedByUsn = 0
            filesWithUsn = 0
            filesUsnFallback = 0
            filesByMetadata = 0
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
            hashBytesAvoidedByUsn = 0
            hashBytesAvoidedByUsnLabel = (Format-ByteSize -Bytes 0)
            elapsedMilliseconds = 0
            elapsed = "00:00:00.000"
            uncertainPathCount = 0
            registryKeysIndexed = 0
            registryValuesIndexed = 0
            registryBranchesExcluded = 0
            registryValuesExcluded = 0
            registryScanErrorCount = 0
            registryElapsedMilliseconds = 0
            registryElapsed = "00:00:00.000"
        }
    }

    $elapsedMs = [int64]$m.ElapsedMilliseconds
    $elapsedTs = [TimeSpan]::FromMilliseconds([double]$elapsedMs)
    $registryMetrics = if ($null -ne $Engine) { $Engine.RegistryMetrics } else { $null }
    $registryElapsedMs = if ($null -ne $registryMetrics) { [int64]$registryMetrics.ElapsedMilliseconds } else { 0 }
    $registryElapsedTs = [TimeSpan]::FromMilliseconds([double]$registryElapsedMs)
    return [pscustomobject][ordered]@{
        phase = $Phase
        filesDiscovered = [int64]$m.FilesDiscovered
        filesIndexed = [int64]$m.FilesIndexed
        filesHashed = [int64]$m.FilesHashed
        filesRecoveredByVss = [int64]$m.FilesRecoveredByVss
        filesVerifiedByUsn = [int64]$m.FilesVerifiedByUsn
        filesWithUsn = [int64]$m.FilesWithUsn
        filesUsnFallback = [int64]$m.FilesUsnFallback
        filesByMetadata = [int64]$m.FilesByMetadata
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
        hashBytesAvoidedByUsn = [int64]$m.HashBytesAvoidedByUsn
        hashBytesAvoidedByUsnLabel = (Format-ByteSize -Bytes ([int64]$m.HashBytesAvoidedByUsn))
        elapsedMilliseconds = $elapsedMs
        elapsed = ("{0:hh\:mm\:ss\.fff}" -f $elapsedTs)
        uncertainPathCount = if ($null -ne $Engine.FileScanUncertainPaths) { [int64]$Engine.FileScanUncertainPaths.Count } else { 0 }
        registryKeysIndexed = if ($null -ne $registryMetrics) { [int64]$registryMetrics.KeysScanned } elseif ($null -ne $Engine.RegSnapshot) { [int64]$Engine.RegSnapshot.Count } else { 0 }
        registryValuesIndexed = if ($null -ne $registryMetrics) { [int64]$registryMetrics.ValuesScanned } else { 0 }
        registryBranchesExcluded = if ($null -ne $registryMetrics) { [int64]$registryMetrics.BranchesExcluded } else { 0 }
        registryValuesExcluded = if ($null -ne $registryMetrics) { [int64]$registryMetrics.ValuesExcluded } else { 0 }
        registryScanErrorCount = if ($null -ne $Engine.RegScanErrors) { [int64]$Engine.RegScanErrors.Count } else { 0 }
        registryElapsedMilliseconds = $registryElapsedMs
        registryElapsed = ("{0:hh\:mm\:ss\.fff}" -f $registryElapsedTs)
    }
}

function Get-FileScanFailureDetailList {
    param(
        [AllowNull()]$Engine,
        [string]$Phase = ""
    )

    if ($null -eq $Engine -or $null -eq $Engine.FileScanUncertainPaths) { return @() }
    $details = New-Object System.Collections.Generic.List[object]
    foreach ($path in @($Engine.FileScanUncertainPaths.Keys | Sort-Object -Unique)) {
        $detail = "Detalle de fallo no disponible."
        if ($null -ne $Engine.FileScanFailureDetails -and $Engine.FileScanFailureDetails.ContainsKey([string]$path)) {
            $detail = [string]$Engine.FileScanFailureDetails[[string]$path]
        }
        $details.Add([pscustomobject][ordered]@{
            phase  = $Phase
            path   = [string]$path
            detail = $detail
        }) | Out-Null
    }
    return @($details.ToArray())
}

function Test-PreFileCoverageComplete {
    param(
        [Parameter(Mandatory=$true)]$Engine,
        [string]$Context = 'Snapshot inicial'
    )

    $uncertainCount = if ($null -ne $Engine.FileScanUncertainPaths) { [int]$Engine.FileScanUncertainPaths.Count } else { 0 }
    if ($uncertainCount -eq 0) { return $true }

    Write-Log ("CAPTURA BLOQUEADA ANTES DE LA INSTALACION: {0:N0} archivo(s) del estado base siguen sin contenido verificable tras reintentos y VSS." -f $uncertainCount) -Level ERROR
    foreach ($failure in @(Get-FileScanFailureDetailList -Engine $Engine -Phase $Context)) {
        Write-Log (" - [{0}] {1} :: {2}" -f $failure.phase, $failure.path, $failure.detail) -Level ERROR
    }
    Write-Log 'No instales la aplicacion. Repara el archivo o restaura una imagen base sana y comienza una captura nueva.' -Level ERROR
    return $false
}

function Write-FileScanMetricsSummary {
    param(
        [Parameter(Mandatory=$true)]$Metrics,
        [string]$Label = "Escaneo"
    )

    Write-Log ("Metricas de {0}: {1:N0} indexado(s) | SHA256 leido: {2:N0} | rescate VSS: {3:N0} | USN reutilizado: {4:N0} | fallback USN: {5:N0} | META: {6:N0} | omitidos: {7:N0} | directorios: {8:N0} | hash leido/evitado: {9}/{10} | tiempo: {11}." -f `
        $Label,
        $Metrics.filesIndexed,
        $Metrics.filesHashed,
        $Metrics.filesRecoveredByVss,
        $Metrics.filesVerifiedByUsn,
        $Metrics.filesUsnFallback,
        $Metrics.filesByMetadata,
        $Metrics.filesSkipped,
        $Metrics.directoriesScanned,
        $Metrics.hashBytesReadLabel,
        $Metrics.hashBytesAvoidedByUsnLabel,
        $Metrics.elapsed) -Level INFO

    if ($Metrics.PSObject.Properties.Name -contains "registryValuesIndexed") {
        Write-Log ("Metricas de Registro ({0}): {1:N0} clave(s) | {2:N0} valor(es) | ramas excluidas: {3:N0} | valores omitidos: {4:N0} | errores: {5:N0} | tiempo: {6}." -f `
            $Label,
            $Metrics.registryKeysIndexed,
            $Metrics.registryValuesIndexed,
            $Metrics.registryBranchesExcluded,
            $Metrics.registryValuesExcluded,
            $Metrics.registryScanErrorCount,
            $Metrics.registryElapsed) -Level INFO
    }

    if (($Metrics.uncertainPathCount -gt 0) -or ($Metrics.registryScanErrorCount -gt 0)) {
        Write-Log ("Cobertura pendiente de correlacion en {0}: {1:N0} ruta(s) de archivos incierta(s) y {2:N0} ruta(s) de registro no verificable(s). Tras el segundo snapshot, las brechas protegidas identicas se separaran de los errores bloqueantes." -f `
            $Label, $Metrics.uncertainPathCount, $Metrics.registryScanErrorCount) -Level WARN
    }

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
        [int]$EffectiveParallelism = 1,
        [bool]$HashAllFiles = $false,
        [bool]$UseUsnOptimization = $false,
        [object[]]$PreFileUncertainPaths = @(),
        [object[]]$PostFileUncertainPaths = @(),
        [object[]]$PreRegistryScanErrors = @(),
        [object[]]$PostRegistryScanErrors = @(),
        [object[]]$ProtectedSystemMutationPaths = @(),
        [object[]]$ProtectedSystemMetadataOnlyPaths = @(),
        [object[]]$CorrelatedProtectedPaths = @(),
        [object[]]$ReproducibleReparsePointMutations = @(),
        [object[]]$UnsupportedReparsePointMutations = @(),
        $RegistryCoverageDiagnostic = $null,
        $ManagedRuntimeMaintenance = $null
    )

    $findings = New-Object 'System.Collections.Generic.List[object]'

    $postObservedFiles = [int64]($PostMetrics.filesIndexed + $PostMetrics.filesSkipped)
    $postIndexed       = [int64]$PostMetrics.filesIndexed
    $postSkipped       = [int64]$PostMetrics.filesSkipped
    $postHashed        = [int64]$PostMetrics.filesHashed
    $postVerifiedUsn   = [int64]$PostMetrics.filesVerifiedByUsn
    $postUsnFallback   = [int64]$PostMetrics.filesUsnFallback
    $postMetadata      = [int64]$PostMetrics.filesByMetadata
    $postFallback      = [int64]$PostMetrics.filesFallbackSize
    $postHashBytes     = [int64]$PostMetrics.hashBytesRead
    $postAvoidedBytes  = [int64]$PostMetrics.hashBytesAvoidedByUsn
    $postRecoveredByVss = if ($PostMetrics.PSObject.Properties.Name -contains 'filesRecoveredByVss') { [int64]$PostMetrics.filesRecoveredByVss } else { 0 }

    $uncertainTotal = @(@($PreFileUncertainPaths) + @($PostFileUncertainPaths) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Sort-Object -Unique).Count
    $indexedVerificationLevel = if ($uncertainTotal -gt 0) { "WARN" } else { "OK" }

    $hashedPct   = Get-PercentValue -Numerator $postHashed   -Denominator $postIndexed
    $usnPct      = Get-PercentValue -Numerator $postVerifiedUsn -Denominator $postIndexed
    $verifiedPct = Get-PercentValue -Numerator ($postHashed + $postVerifiedUsn) -Denominator $postIndexed
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

    if ($postIndexed -eq 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "No se indexaron archivos" `
            -Detail "El snapshot final no contiene archivos indexados. Puede indicar rutas de monitoreo vacias, permisos insuficientes o exclusiones demasiado agresivas." `
            -Recommendation "Revisa DirsToMonitor, la matriz DeltaPack.Exclusions.json y los permisos de lectura."
    } elseif ($UseUsnOptimization -and $HashAllFiles) {
        Add-ScanDiagnosticFinding -Findings $findings -Level $indexedVerificationLevel `
            -Title "Verificacion de archivos indexados (USN + SHA256)" `
            -Detail ("{0:N1}% de {1:N0} archivo(s) indexado(s) se verifico: {2:N1}% reutilizo un SHA256 base mediante identidad NTFS/USN estable y {3:N1}% se leyo con SHA256. Las {4:N0} ruta(s) incierta(s) se reportan aparte y no forman parte de este porcentaje." -f $verifiedPct, $postIndexed, $usnPct, $hashedPct, $uncertainTotal) `
            -Recommendation "Mantener este modo. Si USN no esta disponible o cambia el diario, DeltaPack vuelve automaticamente a SHA256 completo."
    } elseif ($HashAllFiles) {
        Add-ScanDiagnosticFinding -Findings $findings -Level $indexedVerificationLevel `
            -Title "Verificacion de archivos indexados (SHA256)" `
            -Detail ("{0:N1}% de {1:N0} archivo(s) indexado(s) fue firmado por contenido, sin limite de tamano. Las {2:N0} ruta(s) incierta(s) se reportan aparte y no forman parte de este porcentaje." -f $hashedPct, $postIndexed, $uncertainTotal) `
            -Recommendation "Mantener este modo para paquetes destinados a imagenes offline."
    } elseif ($HashThresholdBytes -le 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "Verificacion de contenido desactivada" `
            -Detail "El snapshot de archivos esta usando solo LastWriteTimeUtc-Length. Este modo puede producir falsos positivos cuando Windows toca timestamps sin cambiar contenido." `
            -Recommendation "Usa un umbral SHA256 hibrido, por ejemplo 512 KB o 1 MB, para reducir ruido del sistema operativo."
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

    $registryErrorTotal = @(@($PreRegistryScanErrors) + @($PostRegistryScanErrors) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Sort-Object -Unique).Count
    if ($null -eq $RegistryCoverageDiagnostic) {
        $RegistryCoverageDiagnostic = Get-RegistryCoverageDiagnostic -PreErrors $PreRegistryScanErrors -PostErrors $PostRegistryScanErrors
    }
    $blockingRegistryErrorCount = [int]$RegistryCoverageDiagnostic.blockingCount
    $stableRegistryGapCount = [int]$RegistryCoverageDiagnostic.stableKnownGapCount
    if (($uncertainTotal + $blockingRegistryErrorCount) -gt 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "Cobertura incompleta" `
            -Detail ("Rutas de archivos inciertas: {0:N0}; errores de registro bloqueantes: {1:N0}. No se usaron para generar cambios ni eliminaciones." -f $uncertainTotal, $blockingRegistryErrorCount) `
            -Recommendation "Cierra procesos, revisa permisos y repite la captura hasta obtener cobertura completa."
    }
    if ($stableRegistryGapCount -gt 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Brechas protegidas estables de Registro" `
            -Detail ("{0:N0} rama(s) Class\\{{GUID}}\\Properties permanecieron inaccesibles exactamente igual antes y despues. Se excluyeron del delta como brecha conocida, no como cambio del instalador." -f $stableRegistryGapCount) `
            -Recommendation "Revisa el manifest si el instalador agrega controladores. Todo error asimetrico o fuera de estas ramas sigue bloqueando la captura."
    }

    $protectedSystemMutationCount = @($ProtectedSystemMutationPaths |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Sort-Object -Unique).Count
    if ($protectedSystemMutationCount -gt 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "Mantenimiento de Windows detectado" `
            -Detail ("{0:N0} ruta(s) protegida(s) de catalogos, seguridad, tareas o nucleo cambiaron de contenido, aparecieron, desaparecieron o no pudieron verificarse." -f $protectedSystemMutationCount) `
            -Recommendation "Reinicia si corresponde, deja que Windows termine su mantenimiento y repite la captura desde cero. El WIM queda bloqueado."
    }

    $protectedSystemMetadataOnlyCount = @($ProtectedSystemMetadataOnlyPaths |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Sort-Object -Unique).Count
    if ($protectedSystemMetadataOnlyCount -gt 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Metadatos protegidos omitidos" `
            -Detail ("{0:N0} ruta(s) protegida(s) conservaron el mismo SHA256 y solo cambiaron su identidad USN o metadatos NTFS. Se documentaron y se retiraron del payload." -f $protectedSystemMetadataOnlyCount) `
            -Recommendation "Sin accion necesaria. Un hash diferente, una alta, una eliminacion o una huella incompleta siguen bloqueando el WIM."
    }

    $correlatedProtectedCount = @($CorrelatedProtectedPaths |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Sort-Object -Unique).Count
    if ($correlatedProtectedCount -gt 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Cambios protegidos correlacionados" `
            -Detail ("{0:N0} catalogo(s) o ruta(s) CatRoot se atribuyeron al paquete mediante tokens de producto o evidencia DriverStore del mismo delta. Se conservaron y se marcaron para despliegue especializado." -f $correlatedProtectedCount) `
            -Recommendation "El inyector debe aplicar Actions JSON cuando incluya catalogos o controladores; no trates estas rutas como mantenimiento aleatorio de Windows."
    }

    $managedRuntimeMaintenanceDetected = ($null -ne $ManagedRuntimeMaintenance -and [bool]$ManagedRuntimeMaintenance.detected)
    $managedRuntimeMaintenanceBlocking = ($managedRuntimeMaintenanceDetected -and [bool]$ManagedRuntimeMaintenance.blocking)
    $managedRuntimeMutationCount = if ($null -ne $ManagedRuntimeMaintenance) { [int]$ManagedRuntimeMaintenance.mutationCount } else { 0 }
    if ($managedRuntimeMaintenanceDetected) {
        $managedFamilyNames = @($ManagedRuntimeMaintenance.families | ForEach-Object { $_.name }) -join ", "
        $runtimeTitle = if ($managedRuntimeMaintenanceBlocking) { "Actualizacion de Edge/WebView2 bloqueante" } else { "Edge/WebView2 incluido por configuracion" }
        $runtimeRecommendation = if ($managedRuntimeMaintenanceBlocking) { "Deja terminar la actualizacion de Microsoft Edge/WebView2 y repite la captura desde cero. El WIM queda bloqueado para no mezclar versiones." } else { "Valida el runtime como dependencia intencional en una VM destino; la deteccion queda registrada en el manifest." }
        Add-ScanDiagnosticFinding -Findings $findings -Level $(if ($managedRuntimeMaintenanceBlocking) { "WARN" } else { "INFO" }) `
            -Title $runtimeTitle `
            -Detail ("{0:N0} mutacion(es) en {1}; {2:N0} pertenecen a arboles de version. Cambiadas: {3:N0}; eliminadas: {4:N0}." -f $ManagedRuntimeMaintenance.mutationCount, $managedFamilyNames, $ManagedRuntimeMaintenance.versionedMutationCount, $ManagedRuntimeMaintenance.changedCount, $ManagedRuntimeMaintenance.deletedCount) `
            -Recommendation $runtimeRecommendation
    }

    if ($reparseTotal -gt 0) {
        if ($fileReparse -gt 0 -and $dirReparse -gt 0) {
            $reparseDetail = ("{0:N0} archivo(s) y {1:N0} directorio(s)/junction(s) se inventariaron sin recorrer su destino para evitar duplicados o recursion." -f $fileReparse, $dirReparse)
        } elseif ($fileReparse -gt 0) {
            $reparseDetail = ("{0:N0} archivo(s) con reparse point se inventariaron mediante descriptor NTFS sin leer contenido indirecto." -f $fileReparse)
        } else {
            $reparseDetail = ("{0:N0} directorio(s)/junction(s) se inventariaron sin recorrer su destino para evitar duplicados o recursion." -f $dirReparse)
        }

        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Reparse points inventariados" `
            -Detail $reparseDetail `
            -Recommendation "No se recorre el destino durante el snapshot. Si cambian, DeltaPack exige descriptor RP1 completo y los recrea antes de capturar el WIM."
    }

    $reparseMutationCount = @($UnsupportedReparsePointMutations).Count
    if ($reparseMutationCount -gt 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "Reparse points modificados" `
            -Detail ("{0:N0} reparse point(s) no contienen un descriptor NTFS RP1 valido y no pueden reproducirse." -f $reparseMutationCount) `
            -Recommendation "La captura queda bloqueada. Revisa permisos o compatibilidad del tag; nunca conviertas estos enlaces en archivos ordinarios."
    }

    $reproducibleReparseMutationCount = @($ReproducibleReparsePointMutations).Count
    if ($reproducibleReparseMutationCount -gt 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Reparse points reproducibles" `
            -Detail ("{0:N0} alta(s), reemplazo(s) o eliminacion(es) tienen descriptor NTFS verificable. Las altas/reemplazos se recrean en Staging; las eliminaciones se envian como tombstones." -f $reproducibleReparseMutationCount) `
            -Recommendation "Conserva WIM con -NoRpFix y valida los descriptores despues de aplicar la imagen."
    }

    $slowScanRecommendation = if ($UseUsnOptimization -and $HashAllFiles) {
        "Revisa filesUsnFallback: si es alto, confirma que el volumen sea NTFS y que el diario USN este disponible."
    } elseif ($HashAllFiles) {
        "Acota DirsToMonitor o aumenta el paralelismo si el almacenamiento lo permite; no reduzcas la verificacion de contenido en paquetes offline."
    } else {
        "Baja el umbral SHA256 a 256 KB, reduce rutas monitoreadas o usa un paralelismo mayor si el disco es SSD."
    }
    $moderateScanRecommendation = if ($UseUsnOptimization -and $HashAllFiles) {
        "El snapshot inicial sigue leyendo SHA256 completo; el final debe reutilizar USN para la mayor parte de los archivos."
    } elseif ($HashAllFiles) {
        "Si el tiempo no es aceptable, acota DirsToMonitor o aumenta el paralelismo sin desactivar SHA256 completo."
    } else {
        "Si el tiempo es aceptable, mantener. Si no, baja el umbral SHA256 o acota DirsToMonitor."
    }
    $hashIntensiveRecommendation = if ($UseUsnOptimization -and $HashAllFiles) {
        "Normal en el snapshot inicial. En el final, revisa que hashBytesAvoidedByUsn sea alto y filesUsnFallback bajo."
    } elseif ($HashAllFiles) {
        "Es el costo esperado de verificar contenido. Acota rutas solo si el tiempo no es aceptable."
    } else {
        "Si el escaneo tarda demasiado, baja el umbral a 256 KB o 512 KB."
    }

    if ([int64]$PostMetrics.elapsedMilliseconds -gt 600000) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "WARN" `
            -Title "Escaneo lento" `
            -Detail ("El snapshot final tardo {0}." -f $PostMetrics.elapsed) `
            -Recommendation $slowScanRecommendation
    } elseif ([int64]$PostMetrics.elapsedMilliseconds -gt 180000) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Escaneo moderadamente largo" `
            -Detail ("El snapshot final tardo {0}." -f $PostMetrics.elapsed) `
            -Recommendation $moderateScanRecommendation
    }

    if ($postHashBytes -gt 5GB) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Lectura SHA256 intensiva" `
            -Detail ("Se leyeron {0} para calcular hashes." -f $PostMetrics.hashBytesReadLabel) `
            -Recommendation $hashIntensiveRecommendation
    }

    if ($UseUsnOptimization -and $postVerifiedUsn -gt 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Lectura evitada mediante USN" `
            -Detail ("Se evitaron {0} de lectura repetida; {1:N0} archivo(s) reutilizaron su SHA256 base." -f $PostMetrics.hashBytesAvoidedByUsnLabel, $postVerifiedUsn) `
            -Recommendation "Este ahorro conserva verificacion de contenido porque el SHA256 base solo se reutiliza con volumen, diario, ID de archivo y USN estables."
    }

    if ($UseUsnOptimization -and $postUsnFallback -gt 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Fallback SHA256 de USN" `
            -Detail ("{0:N0} archivo(s) no pudieron verificarse por USN y se leyeron completamente con SHA256." -f $postUsnFallback) `
            -Recommendation "Es un fallback seguro. Investiga solo si afecta a una parte grande del snapshot final."
    }

    if ($postRecoveredByVss -gt 0) {
        Add-ScanDiagnosticFinding -Findings $findings -Level "INFO" `
            -Title "Archivos recuperados mediante VSS" `
            -Detail ("{0:N0} archivo(s) inestable(s) o bloqueado(s) se verificaron contra una instantanea coherente del volumen despues de agotar los reintentos directos." -f $postRecoveredByVss) `
            -Recommendation "Sin accion necesaria. La ruta solo queda incierta si tambien falla el rescate VSS."
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

    $thresholdLabel = if ($UseUsnOptimization -and $HashAllFiles) { "USN seguro + SHA256 con fallback" } elseif ($HashAllFiles) { "SHA256 completo" } elseif ($HashThresholdBytes -le 0) { "Metadatos LastWriteTimeUtc-Length" } else { "SHA256 < $(Format-ByteSize -Bytes $HashThresholdBytes)" }

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
        verifiedByUsnPercent  = $usnPct
        contentVerifiedPercent = $verifiedPct
        contentCoverageComplete = ($uncertainTotal -eq 0)
        metadataPercent       = $metadataPct
        skippedPercent        = $skippedPct
        postFilesIndexed                    = $postIndexed
        postFilesSkipped                    = $postSkipped
        postHashBytesRead                   = $postHashBytes
        postHashBytesAvoidedByUsn            = $postAvoidedBytes
        postFilesVerifiedByUsn               = $postVerifiedUsn
        postFilesUsnFallback                 = $postUsnFallback
        postFilesRecoveredByVss              = $postRecoveredByVss
        postFilesSkippedByAccessDenied      = $fileAccessDenied
        postDirectoriesSkippedByAccessDenied = $dirAccessDenied
        postFilesSkippedByReparsePoint      = $fileReparse
        postDirectoriesSkippedByReparsePoint = $dirReparse
        postFilesSkippedByIoError           = $fileIoErrors
        postDirectoriesSkippedByIoError     = $dirIoErrors
        hashThresholdLabel                  = $thresholdLabel
        effectiveParallelism                = $EffectiveParallelism
        hashAllFiles                        = $HashAllFiles
        useUsnOptimization                  = $UseUsnOptimization
        uncertainPathCount                  = $uncertainTotal
        registryScanErrorCount              = $registryErrorTotal
        blockingRegistryScanErrorCount      = $blockingRegistryErrorCount
        stableRegistryKnownGapCount         = $stableRegistryGapCount
        protectedSystemMutationCount        = $protectedSystemMutationCount
        protectedSystemMetadataOnlyCount    = $protectedSystemMetadataOnlyCount
        correlatedProtectedMutationCount    = $correlatedProtectedCount
        unsupportedReparsePointMutationCount = $reparseMutationCount
        reproducibleReparsePointMutationCount = $reproducibleReparseMutationCount
        managedRuntimeMaintenanceDetected   = $managedRuntimeMaintenanceDetected
        managedRuntimeMaintenanceBlocking   = $managedRuntimeMaintenanceBlocking
        managedRuntimeMutationCount         = $managedRuntimeMutationCount
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
    [void]$sb.AppendLine(("**Verificacion de archivos indexados:** {0:N1}%  " -f $Diagnostic.contentVerifiedPercent))
    [void]$sb.AppendLine(("**Cobertura global completa:** {0}  " -f $Diagnostic.contentCoverageComplete))
    [void]$sb.AppendLine(("**SHA256 leido / SHA256 reutilizado por USN:** {0:N1}% / {1:N1}%  " -f $Diagnostic.hashedPercent, $Diagnostic.verifiedByUsnPercent))
    [void]$sb.AppendLine(("**Omisiones:** {0:N1}%  " -f $Diagnostic.skippedPercent))
    [void]$sb.AppendLine(("**Acceso denegado:** archivos {0:N0}; directorios {1:N0}  " -f $Diagnostic.postFilesSkippedByAccessDenied, $Diagnostic.postDirectoriesSkippedByAccessDenied))
    [void]$sb.AppendLine(("**Reparse points:** archivos {0:N0}; directorios {1:N0}" -f $Diagnostic.postFilesSkippedByReparsePoint, $Diagnostic.postDirectoriesSkippedByReparsePoint))
    [void]$sb.AppendLine(("**Rutas inciertas:** archivos {0:N0}; registro {1:N0}" -f $Diagnostic.uncertainPathCount, $Diagnostic.registryScanErrorCount))
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

        [AllowNull()]
        [string]$DriveRoot,

        [switch]$RecurseNewRootDirectories,

        [ValidateNotNullOrEmpty()]
        [string]$FileVerb = "Indexando"
    )

    if ($null -eq $script:RegTargets -or $script:RegTargets.Count -eq 0) {
        throw "RegTargets no esta inicializado. Define `$script:RegTargets antes de invocar el motor de escaneo."
    }

    foreach ($target in $script:RegTargets) {
        $label = [string]$target.Label
        if ([string]::IsNullOrWhiteSpace($label)) { $label = "$($target.Root)\$($target.Path)" }

        Write-Log -Message "Escaneando registro: $label" -Level INFO -NoConsole
        Write-Host " -> Registro $label " -NoNewline -ForegroundColor DarkGray

        try {
            if ($null -eq $target.Root -or [string]::IsNullOrWhiteSpace([string]$target.Path)) {
                throw "Entrada RegTargets invalida: falta Root o Path para '$label'."
            }

            $Engine.ScanRegistryTarget($target.Root, [string]$target.Path, $label)
            Write-Host "[OK]" -ForegroundColor Green
            if (-not [string]::IsNullOrWhiteSpace([string]$Engine.LastRegistryScanSummaryLine)) {
                Write-Host "    $($Engine.LastRegistryScanSummaryLine)" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "[ERROR]" -ForegroundColor Red
            Write-Log -Message "Error escaneando registro $label : $($_.Exception.Message)" -Level ERROR
            throw
        }
    }

    Write-Host ""

    if (-not [string]::IsNullOrWhiteSpace($DriveRoot) -and (Test-Path -LiteralPath $DriveRoot)) {
        $rootModeLabel = if ($RecurseNewRootDirectories) { "raiz + carpetas nuevas" } else { "raiz, nivel inmediato" }
        Write-Log -Message "${FileVerb}: $DriveRoot ($rootModeLabel)" -Level INFO -NoConsole
        Write-Host " -> $FileVerb $DriveRoot ($rootModeLabel) " -NoNewline -ForegroundColor DarkGray

        try {
            $Engine.ScanDriveRoot($DriveRoot, $FileVerb, [bool]$RecurseNewRootDirectories)
            Write-Host "[OK]" -ForegroundColor Green
            if (-not [string]::IsNullOrWhiteSpace([string]$Engine.LastScanSummaryLine)) {
                Write-Host "    $($Engine.LastScanSummaryLine)" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "[ERROR]" -ForegroundColor Red
            Write-Log -Message "Error durante '$FileVerb' en la raiz $DriveRoot : $($_.Exception.Message)" -Level ERROR
            throw
        }
    }

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
            $Engine.ScanDirectory($dir, $FileVerb)
            Write-Host "[OK]" -ForegroundColor Green
            if (-not [string]::IsNullOrWhiteSpace([string]$Engine.LastScanSummaryLine)) {
                Write-Host "    $($Engine.LastScanSummaryLine)" -ForegroundColor DarkGray
            }
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

function Initialize-DeltaPackVssCleanupHandler {
    if ($script:VssCleanupHandlerRegistered) { return }
    try {
        [Console]::add_CancelKeyPress({
            if ($script:VssShadowIdForCleanup) {
                try {
                    Start-Process -FilePath "vssadmin.exe" -ArgumentList "delete shadows /shadow=$($script:VssShadowIdForCleanup) /quiet" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
                } catch { }
            }
        })
        $script:VssCleanupHandlerRegistered = $true
    } catch { }
}

function New-DeltaPackVssSnapshot {
    param(
        [Parameter(Mandatory=$true)][string]$DriveRoot,
        [string]$Purpose = "captura"
    )

    Initialize-DeltaPackVssCleanupHandler
    Write-Log "Solicitando instantanea VSS de $DriveRoot para $Purpose..." -Level INFO
    $shadowId = $null
    try {
        $vssClass = Get-CimClass -ClassName Win32_ShadowCopy -Namespace "root/cimv2" -ErrorAction Stop
        $vssResult = Invoke-CimMethod -CimClass $vssClass -MethodName "Create" -Arguments @{
            Volume  = $DriveRoot
            Context = "ClientAccessible"
        } -ErrorAction Stop

        if ([int]$vssResult.ReturnValue -ne 0) {
            Write-Log "VSS no pudo crear la instantanea para $Purpose (codigo $($vssResult.ReturnValue)); se continuara con lectura directa y reintentos." -Level WARN
            return $null
        }

        $shadowId = [string]$vssResult.ShadowID
        $script:VssShadowIdForCleanup = $shadowId
        $deviceObject = $null
        for ($attempt = 1; $attempt -le 5 -and [string]::IsNullOrWhiteSpace($deviceObject); $attempt++) {
            if ($attempt -gt 1) { Start-Sleep -Milliseconds 400 }
            $snapshot = Get-CimInstance -ClassName Win32_ShadowCopy -Filter "ID = '$shadowId'" -ErrorAction SilentlyContinue
            if ($null -ne $snapshot) { $deviceObject = [string]$snapshot.DeviceObject }
        }
        if ([string]::IsNullOrWhiteSpace($deviceObject)) {
            throw "VSS creo $shadowId pero no publico DeviceObject."
        }

        Write-Log "Instantanea VSS disponible para ${Purpose}: $deviceObject" -Level SUCCESS
        return [pscustomobject][ordered]@{
            ShadowId    = $shadowId
            DeviceObject = $deviceObject
            DriveRoot   = $DriveRoot
            Purpose     = $Purpose
        }
    } catch {
        Write-Log "VSS no esta disponible para $Purpose; se continuara con lectura directa y reintentos. $($_.Exception.Message)" -Level WARN
        if (-not [string]::IsNullOrWhiteSpace($shadowId)) {
            try {
                Start-Process -FilePath "vssadmin.exe" -ArgumentList "delete shadows /shadow=$shadowId /quiet" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            } catch { }
        }
        $script:VssShadowIdForCleanup = $null
        return $null
    }
}

function Remove-DeltaPackVssSnapshot {
    param(
        [AllowNull()]$Snapshot,
        [switch]$Quiet
    )

    if ($null -eq $Snapshot -or [string]::IsNullOrWhiteSpace([string]$Snapshot.ShadowId)) { return $true }
    $shadowId = [string]$Snapshot.ShadowId
    $removed = $false
    try {
        $process = Start-Process -FilePath "vssadmin.exe" -ArgumentList "delete shadows /shadow=$shadowId /quiet" -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        $removed = ($process.ExitCode -eq 0)
    } catch { }
    if (-not $removed) {
        try {
            $snapshotInstance = Get-CimInstance -ClassName Win32_ShadowCopy -Filter "ID = '$shadowId'" -ErrorAction SilentlyContinue
            if ($null -ne $snapshotInstance) {
                $deleteResult = Invoke-CimMethod -InputObject $snapshotInstance -MethodName Delete -ErrorAction Stop
                $removed = ($null -eq $deleteResult.ReturnValue -or [int]$deleteResult.ReturnValue -eq 0)
            } else {
                $removed = $true
            }
        } catch { }
    }

    if ($script:VssShadowIdForCleanup -eq $shadowId) { $script:VssShadowIdForCleanup = $null }
    if (-not $Quiet) {
        if ($removed) {
            Write-Log "Instantanea VSS eliminada: $shadowId" -Level SUCCESS
        } else {
            Write-Log "La instantanea VSS $shadowId requiere limpieza manual: vssadmin delete shadows /shadow=$shadowId /quiet" -Level WARN
        }
    }
    return $removed
}

function Invoke-ScanEngineWithVssFallback {
    param(
        [Parameter(Mandatory=$true)][ValidateNotNull()]$Engine,
        [AllowNull()][string[]]$Dirs,
        [AllowNull()][string]$DriveRoot,
        [switch]$RecurseNewRootDirectories,
        [ValidateNotNullOrEmpty()][string]$FileVerb = "Indexando"
    )

    $scanSnapshot = $null
    try {
        if ($useVssScanFallback -and -not [string]::IsNullOrWhiteSpace($DriveRoot)) {
            $scanSnapshot = New-DeltaPackVssSnapshot -DriveRoot $DriveRoot -Purpose "escaneo $FileVerb"
        }
        if ($null -ne $scanSnapshot) {
            [DiffEngine]::VssFallbackDrive = [string]$scanSnapshot.DriveRoot
            [DiffEngine]::VssFallbackDeviceObject = [string]$scanSnapshot.DeviceObject
        } else {
            [DiffEngine]::VssFallbackDrive = ""
            [DiffEngine]::VssFallbackDeviceObject = ""
        }

        return Invoke-ScanEngine -Engine $Engine -Dirs $Dirs -DriveRoot $DriveRoot -RecurseNewRootDirectories:$RecurseNewRootDirectories -FileVerb $FileVerb
    } finally {
        [DiffEngine]::VssFallbackDrive = ""
        [DiffEngine]::VssFallbackDeviceObject = ""
        if ($null -ne $scanSnapshot) {
            $vssRemoved = Remove-DeltaPackVssSnapshot -Snapshot $scanSnapshot
        }
    }
}

function Set-PackageSpecificCapturePolicy {
    param(
        [Parameter(Mandatory=$true)][string]$PackageName,
        [bool]$IncludeBundledOneDrive = $false
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$env:COMPUTERNAME)) {
        # La rama Registration\<equipo> es estado local de primer arranque. No
        # debe convertirse en HKCU\Default ni viajar a otra imagen.
        [DiffEngine]::RegExclusions.Add("Software\Microsoft\Office\16.0\Registration\$env:COMPUTERNAME") | Out-Null
    }

    $packageIsOneDrive = $PackageName -match '(?i)(^|[_\-. ])OneDrive([_\-. ]|$)'
    if (-not $IncludeBundledOneDrive -and -not $packageIsOneDrive) {
        foreach ($fileRule in @(
            '\Microsoft OneDrive\',
            '\OneDriveSetup.exe',
            '\OneDrive Per-Machine Standalone Update Task',
            '\OneDrive.lnk'
        )) {
            [DiffEngine]::FileExclusions.Add($fileRule) | Out-Null
        }
        foreach ($registryRule in @(
            'SOFTWARE\Microsoft\OneDrive',
            'SOFTWARE\Microsoft\SkyDrive',
            'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OneDriveFileLauncher.exe',
            'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
            'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
            'SOFTWARE\Google\Chrome\NativeMessagingHosts\com.microsoft.onedrive.nucleus.auth.provider',
            'SOFTWARE\Classes\AppID\OneDrive.EXE',
            'SOFTWARE\Classes\WOW6432Node\AppID\OneDrive.EXE',
            'SOFTWARE\Classes\odopen',
            'SOFTWARE\Classes\grvopen',
            'SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
            'SOFTWARE\Classes\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
            'SOFTWARE\Classes\Interface\{6A821279-AB49-48F8-9A27-F6C59B4FF024}',
            'SOFTWARE\Classes\Interface\{A91EFACB-8B83-4B84-B797-1C8CF3AB3DCB}',
            'SOFTWARE\Classes\Interface\{B05D37A9-03A2-45CF-8850-F660DF0CBF07}',
            'SOFTWARE\Classes\Interface\{C47B67D4-BA96-44BC-AB9E-1CAC8EEA9E93}',
            'SOFTWARE\Classes\WOW6432Node\Interface\{6A821279-AB49-48F8-9A27-F6C59B4FF024}',
            'SOFTWARE\Classes\WOW6432Node\Interface\{A91EFACB-8B83-4B84-B797-1C8CF3AB3DCB}',
            'SOFTWARE\Classes\WOW6432Node\Interface\{B05D37A9-03A2-45CF-8850-F660DF0CBF07}',
            'SOFTWARE\Classes\WOW6432Node\Interface\{C47B67D4-BA96-44BC-AB9E-1CAC8EEA9E93}',
            'SYSTEM\CurrentControlSet\Services\FileSyncHelper',
            'SYSTEM\CurrentControlSet\Services\OneDrive Updater Service'
        )) {
            [DiffEngine]::RegExclusions.Add($registryRule) | Out-Null
        }
        foreach ($overlayIndex in 1..9) {
            [DiffEngine]::RegExclusions.Add("SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers\ OneDrive$overlayIndex") | Out-Null
        }
        foreach ($featureControlPath in @(
            'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Internet Explorer\Main\FeatureControl\FEATURE_BROWSER_EMULATION',
            'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Internet Explorer\Main\FeatureControl\FEATURE_BROWSER_EMULATION'
        )) {
            [DiffEngine]::AddRegistryValueExclusion($featureControlPath, 'OneDrive.exe')
        }
        [DiffEngine]::AddRegistryValueExclusion('HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Office\ClickToRun\Configuration', 'OneDriveClientAddon')
        Write-Log 'OneDrive incluido por instaladores de terceros se aislara del paquete principal. Usa captureSettings.includeBundledOneDrive=true o captura OneDrive como paquete independiente para conservarlo.' -Level INFO
    }

    [DiffEngine]::PrepareExclusionMatchers()
}


$exclusionsPath = Join-Path $PSScriptRoot "DeltaPack.Exclusions.json"
$managedRuntimePolicy = 'failClosed'
$allowAuditOnlyDeletions = $false
$includeBundledOneDrive = $false
$actionAwareInjector = $false
$fileScanMaxAttempts = 3
$fileScanRetryDelayMs = 200
$useVssScanFallback = $true
$additionalFileRoots = @()
$additionalRegistryTargetConfig = @()
$fileDeletionAuditRules = @()
$registryDeletionAuditRules = @()

if (-not (Test-Path $exclusionsPath)) {
    Write-Warning "No se encontro DeltaPack.Exclusions.json en: $exclusionsPath"
    Write-Warning "Este archivo es obligatorio: contiene la matriz de exclusiones 'Cero Ruido'. Restauralo junto al script antes de continuar."
    Read-Host "Presiona Enter para salir."
    exit
}

try {
    $exclusionsConfig = Get-Content -LiteralPath $exclusionsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$exclusionsConfig.schemaVersion -ne 3) {
        throw 'DeltaPack.Exclusions.json no usa el schema 3 requerido por esta compilacion.'
    }

    foreach ($group in $exclusionsConfig.registryExclusions) {
        foreach ($p in $group.paths) { [DiffEngine]::RegExclusions.Add($p) | Out-Null }
    }
    foreach ($group in @($exclusionsConfig.registryValueExclusions)) {
        foreach ($rule in @($group.rules)) {
            [DiffEngine]::AddRegistryValueExclusion([string]$rule.pathPrefix, [string]$rule.valueName)
        }
    }
    $registryDeletionAuditRules = @($exclusionsConfig.registryDeletionAuditRules)
    foreach ($ruleGroup in @($registryDeletionAuditRules)) {
        if ([string]::IsNullOrWhiteSpace([string]$ruleGroup.category)) {
            throw 'Una regla registryDeletionAuditRules no contiene category.'
        }
        foreach ($registryPath in @($ruleGroup.paths)) {
            $normalizedRegistryPath = ([string]$registryPath).Trim().TrimEnd([char]92)
            if ($normalizedRegistryPath -notmatch '^HKEY_(LOCAL_MACHINE|CURRENT_USER)\\.+') {
                throw "Ruta invalida en registryDeletionAuditRules/$($ruleGroup.category): $registryPath"
            }
            [DiffEngine]::RegistryDeletionAuditPaths.Add($normalizedRegistryPath) | Out-Null
        }
    }
    foreach ($group in $exclusionsConfig.fileExclusions) {
        foreach ($p in $group.paths) { [DiffEngine]::FileExclusions.Add($p) | Out-Null }
    }

    if ($null -ne $exclusionsConfig.captureSettings) {
        if ([bool]$exclusionsConfig.captureSettings.allowManagedRuntimeUpdates) {
            $managedRuntimePolicy = 'includeWhenDetected'
        }
        $allowAuditOnlyDeletions = [bool]$exclusionsConfig.captureSettings.allowAuditOnlyDeletions
        $includeBundledOneDrive = [bool]$exclusionsConfig.captureSettings.includeBundledOneDrive
        $actionAwareInjector = [bool]$exclusionsConfig.captureSettings.actionAwareInjector
        if ($null -ne $exclusionsConfig.captureSettings.fileScanMaxAttempts) {
            $fileScanMaxAttempts = [Math]::Max(1, [Math]::Min(10, [int]$exclusionsConfig.captureSettings.fileScanMaxAttempts))
        }
        if ($null -ne $exclusionsConfig.captureSettings.fileScanRetryDelayMs) {
            $fileScanRetryDelayMs = [Math]::Max(0, [Math]::Min(5000, [int]$exclusionsConfig.captureSettings.fileScanRetryDelayMs))
        }
        if ($null -ne $exclusionsConfig.captureSettings.useVssScanFallback) {
            $useVssScanFallback = [bool]$exclusionsConfig.captureSettings.useVssScanFallback
        }
        $additionalFileRoots = @($exclusionsConfig.captureSettings.additionalFileRoots)
        $additionalRegistryTargetConfig = @($exclusionsConfig.captureSettings.additionalRegistryTargets)
    }
    $fileDeletionAuditRules = @($exclusionsConfig.fileDeletionAuditRules)
    foreach ($ruleGroup in @($fileDeletionAuditRules)) {
        if ([string]::IsNullOrWhiteSpace([string]$ruleGroup.category)) {
            throw 'Una regla fileDeletionAuditRules no contiene category.'
        }
        foreach ($pattern in @($ruleGroup.patterns)) {
            try { $null = [regex]::new([string]$pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
            catch { throw "Patron regex invalido en fileDeletionAuditRules/$($ruleGroup.category): $pattern" }
        }
    }

    if ([DiffEngine]::RegExclusions.Count -eq 0 -or [DiffEngine]::FileExclusions.Count -eq 0) {
        Write-Warning "DeltaPack.Exclusions.json se leyo pero no contiene reglas validas (listas vacias)."
        Read-Host "Presiona Enter para salir."
        exit
    }

    Write-Log "Matriz de exclusiones cargada: $([DiffEngine]::RegExclusions.Count) reglas de claves, $([DiffEngine]::RegistryValueExclusionCount) reglas de valores, $([DiffEngine]::RegistryDeletionAuditPaths.Count) reglas de eliminacion auditOnly y $([DiffEngine]::FileExclusions.Count) reglas de archivos." -Level INFO

    [DiffEngine]::HashThresholdBytes = 512KB
    [DiffEngine]::HashAllFiles = $true
    [DiffEngine]::UseUsnOptimization = $true
    [DiffEngine]::FileScanMaxAttempts = $fileScanMaxAttempts
    [DiffEngine]::FileScanRetryDelayMilliseconds = $fileScanRetryDelayMs
    [DiffEngine]::PrepareExclusionMatchers()
} catch {
    Write-Warning "DeltaPack.Exclusions.json esta corrupto o mal formado: $($_.Exception.Message)"
    Read-Host "Presiona Enter para salir."
    exit
}

try {
    $engineIdentity = Get-DeltaPackEngineIdentity
} catch {
    Write-Warning "No se pudo verificar la identidad SHA256 de la compilacion: $($_.Exception.Message)"
    Read-Host "Presiona Enter para salir."
    exit 1
}

# =================================================================
#  Configuracion y Rutas
# =================================================================
Clear-Host
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "     DeltaPack Dual-Engine v$($script:Version) by SOFTMAXTER" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan

$captureRoot    = Join-Path $env:ProgramData "DeltaPack\Captures"
$workspaceDir   = Join-Path $captureRoot ("Capture_" + $currentUserSid.Replace('-', '_'))
$stateBinFile   = Join-Path $workspaceDir "snapshot_pre.bin"
$configJsonFile = Join-Path $workspaceDir "config.json"
[DiffEngine]::FileExclusions.Add(([string]$captureRoot + "\")) | Out-Null

$isResumeMode = $false
$capturePrivilegeResults = @()
$preScanMetrics = $null
$postScanMetrics = $null
$scanDiagnostic = $null
$preRegistryScanErrors  = @()
$postRegistryScanErrors = @()
$preFileUncertainPaths  = @()
$postFileUncertainPaths = @()
$preFileUncertainDetails  = @()
$postFileUncertainDetails = @()

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
$currentDesktopPath = [Environment]::GetFolderPath("Desktop")
if ([string]::IsNullOrWhiteSpace($currentDesktopPath)) {
    $currentDesktopPath = Join-Path $env:USERPROFILE "Desktop"
}
$script:DesktopRoot = $currentDesktopPath
[DiffEngine]::UserDesktopPath = $script:DesktopRoot
$systemDriveRoot = [System.IO.Path]::GetPathRoot($env:SystemRoot)
$DirsToMonitor = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:ProgramData,
    "$env:PUBLIC\Desktop",
    "$env:USERPROFILE\Desktop",
    $currentDesktopPath,
    $env:APPDATA,
    $env:LOCALAPPDATA,
    "$env:windir\System32",
    "$env:windir\SysWOW64",
    "$env:windir\Installer",
    "$env:windir\Fonts",
    "$env:windir\assembly",
    "$env:windir\Microsoft.NET"
)

foreach ($configuredRoot in @($additionalFileRoots)) {
    $expandedRoot = [Environment]::ExpandEnvironmentVariables([string]$configuredRoot).Trim()
    if ([string]::IsNullOrWhiteSpace($expandedRoot)) { continue }
    if (-not [System.IO.Path]::IsPathRooted($expandedRoot)) {
        Write-Warning "Ruta adicional ignorada porque no es absoluta: $expandedRoot"
        continue
    }
    $DirsToMonitor += $expandedRoot
}

$script:RegTargets = @(
    @{ Root = [Microsoft.Win32.Registry]::LocalMachine; Path = "SOFTWARE";                          Label = "HKLM\SOFTWARE" },
    @{ Root = [Microsoft.Win32.Registry]::CurrentUser;  Path = "Software";                          Label = "HKCU\Software" },
    @{ Root = [Microsoft.Win32.Registry]::LocalMachine; Path = "SYSTEM\CurrentControlSet\Services"; Label = "HKLM\SYSTEM\CurrentControlSet\Services" },
    @{ Root = [Microsoft.Win32.Registry]::LocalMachine; Path = "SYSTEM\CurrentControlSet\Control\Class"; Label = "HKLM\SYSTEM\CurrentControlSet\Control\Class" },
    @{ Root = [Microsoft.Win32.Registry]::LocalMachine; Path = "SYSTEM\CurrentControlSet\Control\Print"; Label = "HKLM\SYSTEM\CurrentControlSet\Control\Print" },
    @{ Root = [Microsoft.Win32.Registry]::LocalMachine; Path = "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; Label = "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" },
    @{ Root = [Microsoft.Win32.Registry]::CurrentUser;  Path = "Environment";                       Label = "HKCU\Environment" }
)

foreach ($configuredTarget in @($additionalRegistryTargetConfig)) {
    $configuredHive = ([string]$configuredTarget.hive).Trim().ToUpperInvariant()
    $configuredPath = ([string]$configuredTarget.path).Trim().TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($configuredPath)) { continue }
    $configuredRoot = switch ($configuredHive) {
        'HKLM' { [Microsoft.Win32.Registry]::LocalMachine }
        'HKEY_LOCAL_MACHINE' { [Microsoft.Win32.Registry]::LocalMachine }
        'HKCU' { [Microsoft.Win32.Registry]::CurrentUser }
        'HKEY_CURRENT_USER' { [Microsoft.Win32.Registry]::CurrentUser }
        default { $null }
    }
    if ($null -eq $configuredRoot) {
        Write-Warning "Objetivo de Registro adicional ignorado por hive no soportado: $configuredHive"
        continue
    }
    $configuredLabel = if ([string]::IsNullOrWhiteSpace([string]$configuredTarget.label)) { "$configuredHive\$configuredPath" } else { [string]$configuredTarget.label }
    $script:RegTargets += @{ Root = $configuredRoot; Path = $configuredPath; Label = $configuredLabel }
}

if ($isResumeMode) {
    # --- RUTA DE REANUDACION (POST-REINICIO) ---
    try {
        $config = Get-Content $configJsonFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        Assert-ResumeConfiguration -Config $config -StatePath $stateBinFile | Out-Null
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
        $workspaceDir   = $config.workspaceDir
        $stagingDir     = $config.stagingDir
        $script:LogPath = $config.LogPath
        $isDryRun       = [bool]$config.isDryRun
        $packageIdentity = Initialize-DeltaPackPackageIdentity -BaseName ([string]$pkgName) -Architecture ([string]$archTag) `
            -PackageType ([string]$sufijo) -FullName ([string]$finalPkgName)
        if ([string]$config.packageIdentitySha256 -cne [string]$packageIdentity.sha256) {
            throw 'La identidad canónica reanudada no coincide con su huella guardada.'
        }
        Write-Log ("Identidad del motor: PS1 {0} | C# {1} | Exclusiones {2}" -f $engineIdentity.scriptSha256, $engineIdentity.diffEngineSha256, $engineIdentity.exclusionsSha256) -Level INFO
        if (-not $isDryRun) {
            try {
                $capturePrivilegeResults = @(Enable-DeltaPackCapturePrivileges)
            } catch {
                Write-Log "CAPTURA BLOQUEADA ANTES DE STAGING: $($_.Exception.Message)" -Level ERROR
                Write-Warning "El workspace se conserva. Corrige la asignacion de privilegios y vuelve a reanudar."
                Read-Host "Presiona Enter para salir."
                exit 1
            }
        }
        [DiffEngine]::FileExclusions.Add(([string]$outDir + "\")) | Out-Null
        Set-PackageSpecificCapturePolicy -PackageName $script:DeltaPackPackageBaseName -IncludeBundledOneDrive $includeBundledOneDrive
        if ($null -ne $config.preScanMetrics) { $preScanMetrics = $config.preScanMetrics }

        Write-Log -Message "Reanudando paquete: $($script:DeltaPackPackageFullName)" -Level INFO
        Write-Log -Message "Cargando Snapshot base desde el disco duro (Des-serializacion Binaria)..." -Level STEP

        try {
            $enginePre = [DiffEngine]::LoadState($stateBinFile)
        } catch {
            Write-Log -Message "No se pudo restaurar el snapshot base de forma segura: $($_.Exception.Message)" -Level ERROR
            Write-Warning "La captura guardada es incompatible o fue alterada. Inicia una captura nueva."
            Remove-Item -Path $workspaceDir -Recurse -Force -ErrorAction SilentlyContinue
            Read-Host "Presiona Enter para salir."
            exit
        }
        if ($null -eq $preScanMetrics) {
            $preScanMetrics = Get-FileScanMetricsSnapshot -Engine $enginePre -Phase "Pre-Resume"
        }

        if (-not (Test-PreFileCoverageComplete -Engine $enginePre -Context 'Pre-Resume')) {
            Write-Warning 'La captura guardada no puede producir un delta completo porque su estado Pre contiene archivos ilegibles.'
            Write-Warning 'El workspace se conserva solo para diagnostico. En la siguiente ejecucion, descarta la reanudacion e inicia desde una imagen base reparada.'
            Read-Host "Presiona Enter para salir."
            exit 2
        }

        Write-Log -Message "Estado base restaurado en memoria." -Level SUCCESS
    }
}

# El bloque 'if (-not $isResumeMode)' cubre tanto la ruta normal como la ruta donde
# el modo resume fue abortado por config.json corrupto.
if (-not $isResumeMode) {
    # --- RUTA NORMAL (NUEVA CAPTURA) ---
    $pendingRebootIndicators = @(Get-PendingRebootIndicators)
    if ($pendingRebootIndicators.Count -gt 0) {
        Write-Host "`n[!] CAPTURA NUEVA BLOQUEADA: Windows tiene un reinicio pendiente." -ForegroundColor Red
        Write-Host "    Completa el reinicio y deja que Windows termine su mantenimiento antes del snapshot inicial." -ForegroundColor Yellow
        foreach ($indicator in $pendingRebootIndicators) {
            Write-Host "    - $indicator" -ForegroundColor DarkYellow
        }
        Write-Host "`n    Este control no se aplica al reanudar una captura guardada; en ese caso se valida el delta final." -ForegroundColor DarkGray
        Read-Host "Presiona Enter para salir."
        exit
    }

    do {
        $pkgName = (Read-Host "`n1. Ingresa el nombre base del software (Ej: Office_24)").Trim()

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
            $sufijo = (Read-Host "Ingresa el sufijo").Trim()

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
    $packageIdentity = Initialize-DeltaPackPackageIdentity -BaseName $pkgName -Architecture $archTag -PackageType $sufijo -FullName $finalPkgName
    Write-Host "`n[OK] El paquete se generara como: $($script:DeltaPackPackageFullName)" -ForegroundColor Green
    if ($isDryRun) {
        Write-Host "[INFO] Modo Dry Run activo: no se copiaran archivos ni se generara el .wim." -ForegroundColor Cyan
    }

    $outDirBase = Join-Path $script:DesktopRoot "DeltaPack_$($script:DeltaPackPackageFullName)"
    $outDir     = $outDirBase
    if (Test-Path -LiteralPath $outDir) {
        $captureStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $outDir = "${outDirBase}_${captureStamp}"
        $collisionIndex = 1
        while (Test-Path -LiteralPath $outDir) {
            $outDir = "${outDirBase}_${captureStamp}_${collisionIndex}"
            $collisionIndex++
        }
        Write-Host "[INFO] La salida anterior se conservara. Nueva carpeta: $(Split-Path $outDir -Leaf)" -ForegroundColor Cyan
    }
    $stagingDir = Join-Path $workspaceDir "Staging"

    New-Item -Path $outDir     -ItemType Directory -Force | Out-Null
    if (Test-Path -LiteralPath $workspaceDir) {
        Remove-Item -LiteralPath $workspaceDir -Recurse -Force -ErrorAction Stop
    }
    Set-DeltaPackSecureDirectoryAcl -Path $captureRoot
    Set-DeltaPackSecureDirectoryAcl -Path $workspaceDir
    New-Item -Path $stagingDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    [DiffEngine]::FileExclusions.Add(([string]$outDir + "\")) | Out-Null

    $script:LogPath = Join-Path $outDir "Install_Log.txt"
    Write-Log -Message "Entorno preparado. Log iniciado en: $script:LogPath" -Level SUCCESS
    Write-Log ("Identidad del motor: PS1 {0} | C# {1} | Exclusiones {2}" -f $engineIdentity.scriptSha256, $engineIdentity.diffEngineSha256, $engineIdentity.exclusionsSha256) -Level INFO
    if (-not $isDryRun) {
        try {
            $capturePrivilegeResults = @(Enable-DeltaPackCapturePrivileges)
        } catch {
            Write-Log "CAPTURA BLOQUEADA ANTES DEL SNAPSHOT INICIAL: $($_.Exception.Message)" -Level ERROR
            Write-Warning "No instales la aplicacion hasta corregir la asignacion de privilegios de Windows."
            Read-Host "Presiona Enter para salir."
            exit 1
        }
    }
    Set-PackageSpecificCapturePolicy -PackageName $script:DeltaPackPackageBaseName -IncludeBundledOneDrive $includeBundledOneDrive

    # --- FASE 1: SNAPSHOT INICIAL ---
    Write-Log -Message "Fase 1/4: Mapeando el estado base (Registro + Archivos)..." -Level STEP
    $enginePre = New-Object DiffEngine
    $preScanMetrics = Invoke-ScanEngineWithVssFallback -Engine $enginePre -Dirs $DirsToMonitor -DriveRoot $systemDriveRoot -FileVerb "Indexando"

    if (-not (Test-PreFileCoverageComplete -Engine $enginePre -Context 'Pre')) {
        Write-Warning 'La instalacion no debe comenzar sobre este estado base. El log de diagnostico se conserva en la carpeta de salida.'
        if (Test-Path -LiteralPath $workspaceDir) {
            Remove-Item -LiteralPath $workspaceDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Read-Host "Presiona Enter para salir."
        exit 2
    }

    # --- SALVAGUARDAR ESTADO ---
    Write-Log -Message "Serializando estado y guardando en disco (Proteccion contra reinicios)..." -Level INFO

    if (-not (Test-Path $workspaceDir)) {
        New-Item -Path $workspaceDir -ItemType Directory -Force | Out-Null
    }

    $configData = @{
        configSchemaVersion = 3
        pkgName      = $script:DeltaPackPackageBaseName
        finalPkgName = $script:DeltaPackPackageFullName
        archTag      = $script:DeltaPackPackageArchitecture
        sufijo       = $script:DeltaPackPackageType
        packageIdentitySha256 = $script:DeltaPackPackageIdentitySha256
        outDir       = $outDir
        workspaceDir = $workspaceDir
        stagingDir   = $stagingDir
        LogPath         = $script:LogPath
        isDryRun        = $isDryRun
        preScanMetrics  = $preScanMetrics
        scriptVersion   = $script:Version
        scriptSha256    = $engineIdentity.scriptSha256
        hashAllFiles    = [bool][DiffEngine]::HashAllFiles
        useUsnOptimization = [bool][DiffEngine]::UseUsnOptimization
        engineSha256       = (Get-FileHash -LiteralPath $diffEngineCsPath -Algorithm SHA256 -ErrorAction Stop).Hash
        exclusionsSha256   = (Get-FileHash -LiteralPath $exclusionsPath -Algorithm SHA256 -ErrorAction Stop).Hash
    }

    $stateTempFile  = "$stateBinFile.tmp"
    $configTempFile = "$configJsonFile.tmp"
    $enginePre.SaveState($stateTempFile)
    Move-Item -LiteralPath $stateTempFile -Destination $stateBinFile -Force -ErrorAction Stop
    $configData.stateSha256 = (Get-FileHash -LiteralPath $stateBinFile -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $configJson = $configData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($configTempFile, $configJson, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $configTempFile -Destination $configJsonFile -Force -ErrorAction Stop

    Write-Log -Message "Estado base asegurado. La herramienta sobrevivira a un reinicio." -Level SUCCESS
    [System.GC]::Collect()

    # --- AUTO-ARRANQUE (RESILIENCIA POST-REINICIO) ---
    Write-Log "Configurando Auto-Reanudacion (RunOnce)..." -Level INFO
    if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
        $launcherPath = Join-Path (Split-Path $PSScriptRoot -Parent) "DeltaPackDual-Engine.exe"

        if (Test-Path $launcherPath) {
            $runOnceKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
            $runOnceCommand = "`"$launcherPath`""
            try {
                if (-not (Test-Path -LiteralPath $runOnceKey)) {
                    New-Item -Path $runOnceKey -Force -ErrorAction Stop | Out-Null
                }
                Set-ItemProperty -LiteralPath $runOnceKey -Name "DeltaPackResume" -Value $runOnceCommand -Force -ErrorAction Stop
                $storedRunOnceCommand = [string](Get-ItemPropertyValue -LiteralPath $runOnceKey -Name "DeltaPackResume" -ErrorAction Stop)
                if ($storedRunOnceCommand -cne $runOnceCommand) {
                    throw "El valor RunOnce escrito no coincide con el comando esperado."
                }
                Write-Log "El ancla de auto-arranque esta lista y fue verificada." -Level SUCCESS
            } catch {
                Write-Log "No se pudo configurar Auto-Reanudacion en RunOnce: $($_.Exception.Message). El estado base permanece guardado; si el instalador reinicia Windows, ejecuta manualmente DeltaPackDual-Engine.exe con el mismo usuario para continuar." -Level WARN
            }
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
$runOnceSubKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$runOnceAbsoluteKey = "HKEY_CURRENT_USER\$runOnceSubKey"
$runOnceValueName = 'DeltaPackResume'
$runOnceKeyExistedInBaseline = [bool]$enginePre.RegSnapshot.ContainsKey($runOnceAbsoluteKey)
$removeTemporaryRunOnceKey = $false
$temporaryRunOnceKeyRemoved = $false
try {
    $runOnceHandle = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runOnceSubKey, $true)
    try {
        if ($null -ne $runOnceHandle) {
            if (@($runOnceHandle.GetValueNames()) -contains $runOnceValueName) {
                $runOnceHandle.DeleteValue($runOnceValueName, $false)
            }
            if (@($runOnceHandle.GetValueNames()) -contains $runOnceValueName) {
                throw 'El valor DeltaPackResume continua presente despues de intentar eliminarlo.'
            }
            $removeTemporaryRunOnceKey = ((-not $runOnceKeyExistedInBaseline) -and
                @($runOnceHandle.GetValueNames()).Count -eq 0 -and
                @($runOnceHandle.GetSubKeyNames()).Count -eq 0)
        }
    } finally {
        if ($null -ne $runOnceHandle) { $runOnceHandle.Dispose() }
    }

    # Si RunOnce no existia en el snapshot base y sigue completamente vacio,
    # pertenece a DeltaPack. Eliminarlo evita exportar una clave vacia al REG.
    if ($removeTemporaryRunOnceKey) {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($runOnceSubKey, $false)
        $temporaryRunOnceKeyRemoved = $true
    }

    $runOnceVerificationHandle = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runOnceSubKey, $false)
    try {
        if ($null -ne $runOnceVerificationHandle -and
            @($runOnceVerificationHandle.GetValueNames()) -contains $runOnceValueName) {
            throw 'La verificacion final detecto que DeltaPackResume sigue presente.'
        }
    } finally {
        if ($null -ne $runOnceVerificationHandle) { $runOnceVerificationHandle.Dispose() }
    }

    if ($temporaryRunOnceKeyRemoved) {
        Write-Log 'Ancla de auto-arranque eliminada y ausencia verificada; la clave RunOnce temporal tambien fue retirada.' -Level SUCCESS
    } else {
        Write-Log 'Ancla de auto-arranque eliminada y ausencia verificada; RunOnce preexistente o con contenido ajeno fue preservado.' -Level SUCCESS
    }
} catch {
    Write-Log "No se pudo eliminar y verificar el ancla de auto-arranque: $($_.Exception.Message)" -Level ERROR
    throw
}

# --- FASE 3: SNAPSHOT FINAL Y DIFF ---
Write-Log "Fase 3/4: Mapeando estado post-instalacion..." -Level STEP
$enginePost = New-Object DiffEngine
$enginePost.BaselineForReuse = $enginePre
$postScanMetrics = Invoke-ScanEngineWithVssFallback -Engine $enginePost -Dirs $DirsToMonitor -DriveRoot $systemDriveRoot -RecurseNewRootDirectories -FileVerb "Verificando"

$preRegistryScanErrors  = @($enginePre.RegScanErrors)
$postRegistryScanErrors = @($enginePost.RegScanErrors)
$preFileUncertainPaths  = @($enginePre.FileScanUncertainPaths.Keys)
$postFileUncertainPaths = @($enginePost.FileScanUncertainPaths.Keys)
$preFileUncertainDetails  = @(Get-FileScanFailureDetailList -Engine $enginePre -Phase 'Pre')
$postFileUncertainDetails = @(Get-FileScanFailureDetailList -Engine $enginePost -Phase 'Post')

$hashThresholdBytesForDiagnostic = [int64][DiffEngine]::HashThresholdBytes
$hashAllFilesForDiagnostic = [bool][DiffEngine]::HashAllFiles
$useUsnOptimizationForDiagnostic = [bool][DiffEngine]::UseUsnOptimization
$maxScanParallelismForDiagnostic = [int][DiffEngine]::MaxScanParallelism
$effectiveParallelismForDiagnostic = [DiffEngine]::GetEffectiveParallelism()

$registryCoverageDiagnostic = Get-RegistryCoverageDiagnostic -PreErrors $preRegistryScanErrors -PostErrors $postRegistryScanErrors
$scanCoverageComplete = (($preFileUncertainPaths.Count + $postFileUncertainPaths.Count) -eq 0 -and [bool]$registryCoverageDiagnostic.coverageComplete)
if (($preFileUncertainPaths.Count + $postFileUncertainPaths.Count) -gt 0) {
    Write-Log "Cobertura de archivos incompleta. Las rutas siguientes no se usaran para generar cambios ni eliminaciones:" -Level ERROR
    foreach ($scanFailure in @($preFileUncertainDetails + $postFileUncertainDetails)) {
        Write-Log (" - [{0}] {1} :: {2}" -f $scanFailure.phase, $scanFailure.path, $scanFailure.detail) -Level ERROR
    }
}
if ($registryCoverageDiagnostic.stableKnownGapCount -gt 0) {
    Write-Log ("Cobertura de Registro: {0:N0} brecha(s) protegida(s) Class\\{{GUID}}\\Properties fueron identicas antes/despues y quedan como advertencia estable." -f $registryCoverageDiagnostic.stableKnownGapCount) -Level INFO
}
if ($registryCoverageDiagnostic.blockingCount -gt 0) {
    Write-Log ("Cobertura de Registro incompleta: {0:N0} error(es) inesperado(s) o asimetricos bloquean la captura." -f $registryCoverageDiagnostic.blockingCount) -Level ERROR
    foreach ($registryCoveragePath in @($registryCoverageDiagnostic.blockingPaths)) {
        Write-Log " - $registryCoveragePath" -Level ERROR
    }
}

Write-Log "Calculando diferencias de Registro..." -Level INFO
$regOutputFile = Join-Path $outDir "$($script:DeltaPackPackageFullName).reg"
$auditOnlyRegistryKeyDeletions = @([DiffEngine]::GetAuditOnlyRegistryKeyDeletions($enginePre, $enginePost))
$auditOnlyRegistryMutations = @([DiffEngine]::GetAuditOnlyRegistryMutations($enginePre, $enginePost))
$taskCacheDeletionAuditOnly = @($auditOnlyRegistryMutations | Where-Object { ([string]$_).StartsWith('TaskCache eliminado (solo auditoria):', [System.StringComparison]::OrdinalIgnoreCase) })
[DiffEngine]::GenerateRegFile($enginePre, $enginePost, $regOutputFile)
$generatedRegText = [System.IO.File]::ReadAllText($regOutputFile, [System.Text.Encoding]::Unicode)
if ($generatedRegText.IndexOf('DeltaPackResume', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
    throw 'El REG generado contiene el ancla interna DeltaPackResume. La captura se detuvo antes del empaquetado.'
}
if ([regex]::IsMatch($generatedRegText,
        '(?im)^\[-HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WINEVT\\Publishers(?:\\|\])')) {
    throw 'El REG generado contiene una eliminacion destructiva de un publicador WINEVT protegido. Revisa registryDeletionAuditRules.'
}
$regMetrics = Get-RegFileMetrics -Path $regOutputFile
$registryPortabilityDiagnostic = Get-RegPortabilityDiagnostic -Path $regOutputFile
Write-Log ("Registro exportado: {0:N0} entrada(s) en .reg ({1:N0} seccion(es)/clave(s), {2:N0} valor(es), {3:N0} clave(s) eliminada(s), {4:N0} valor(es) eliminado(s))." -f `
    $regMetrics.TotalEntries, $regMetrics.KeySections, $regMetrics.ValueEntries, $regMetrics.DeletedKeys, $regMetrics.DeletedValues) -Level SUCCESS
if ([bool]$registryPortabilityDiagnostic.blocking) {
    Write-Log ("BLOQUEO DE PORTABILIDAD: el REG conserva {0:N0} referencia(s) al nombre del equipo y {1:N0} referencia(s) al perfil/SID de captura." -f `
        $registryPortabilityDiagnostic.machineNameReferenceCount, $registryPortabilityDiagnostic.captureIdentityReferenceCount) -Level ERROR
    foreach ($portabilityReference in @($registryPortabilityDiagnostic.machineNameReferences) + @($registryPortabilityDiagnostic.captureIdentityReferences)) {
        Write-Log " - $portabilityReference" -Level ERROR
    }
}
if ($registryPortabilityDiagnostic.absoluteSourceDriveNameCount -gt 0) {
    Write-Log ("Portabilidad de Registro: {0:N0} nombre(s) de valor contienen rutas absolutas de {1}; el destino debe conservar la misma letra de sistema." -f `
        $registryPortabilityDiagnostic.absoluteSourceDriveNameCount, $registryPortabilityDiagnostic.sourceSystemDrive) -Level WARN
}
if ($auditOnlyRegistryKeyDeletions.Count -gt 0) {
    Write-Log ("Auditoria de Registro: {0:N0} eliminacion(es) protegida(s) o no correlacionada(s) no se exportaron al .reg." -f $auditOnlyRegistryKeyDeletions.Count) -Level WARN
    foreach ($auditKey in $auditOnlyRegistryKeyDeletions) {
        Write-Log " - $auditKey" -Level WARN
    }
}
if ($auditOnlyRegistryMutations.Count -gt 0) {
    Write-Log ("Auditoria de Registro: {0:N0} mutacion(es) COM/TaskCache sin correlacion suficiente no se exportaron al .reg." -f $auditOnlyRegistryMutations.Count) -Level WARN
    foreach ($auditMutation in $auditOnlyRegistryMutations) {
        Write-Log " - $auditMutation" -Level WARN
    }
}

Write-Log "Calculando diferencias de Archivos..." -Level INFO
$changedFiles = [DiffEngine]::GetFileDifferences($enginePre, $enginePost)
$deletedFiles         = [DiffEngine]::GetDeletedFiles($enginePre, $enginePost)
$deletedListForReport = New-Object System.Collections.Generic.List[string]
$deletionEntries      = New-Object System.Collections.Generic.List[object]
$filesystemDeletionAuditOnly = New-Object System.Collections.Generic.List[object]
foreach ($delPath in $deletedFiles) {
    $isDelDir = ($enginePre.FileSnapshot.ContainsKey($delPath) -and [DiffEngine]::IsDirectoryFingerprint([string]$enginePre.FileSnapshot[$delPath]))
    $currentUserProfileForDeleted = (Split-Path $env:USERPROFILE -NoQualifier).TrimStart('\', '/')
    $delRel   = Convert-ToPortableRelativePath -SourcePath $delPath -CurrentUserProfileRelative $currentUserProfileForDeleted
    $deletionKind = if ($isDelDir) { 'directory' } else { 'file' }
    $auditClassification = Get-DeltaPackDeletionAuditClassification -RelativePath $delRel -Kind $deletionKind -Rules $fileDeletionAuditRules
    if ($null -ne $auditClassification) {
        $filesystemDeletionAuditOnly.Add($auditClassification) | Out-Null
        $deletedListForReport.Add("$delRel [solo auditoria: $($auditClassification.category)]") | Out-Null
        continue
    }
    $deletionEntries.Add([pscustomobject][ordered]@{
        operation = 'delete'
        kind      = $deletionKind
        path      = $delRel
    }) | Out-Null
    if ($isDelDir) { $delRel = "$delRel\ (carpeta)" }
    $deletedListForReport.Add($delRel)
}
if ($deletedListForReport.Count -gt 0) {
    Write-Log "$($deletedListForReport.Count) archivo(s)/carpeta(s) eliminados durante la ventana de captura (no incluidos en el WIM; documentados en el reporte)." -Level WARN
}
if ($filesystemDeletionAuditOnly.Count -gt 0) {
    Write-Log "$($filesystemDeletionAuditOnly.Count) eliminacion(es) de mantenimiento ambiental se conservaron solo para auditoria y no se enviaran al inyector." -Level INFO
}

$modifiedFilesObservedCount = $changedFiles.ModifiedFiles.Count
$protectedSystemMutationCandidates = @($changedFiles.NewFiles) + @($changedFiles.ModifiedFiles) + @($changedFiles.NewDirs) + @($changedFiles.ModifiedDirs) + @($deletedFiles)
$protectedSystemMutationDiagnostic = Get-ProtectedSystemMutationDiagnostic `
    -Paths $protectedSystemMutationCandidates -PreEngine $enginePre -PostEngine $enginePost -PackageName $script:DeltaPackPackageBaseName
$protectedSystemMutationPaths = @($protectedSystemMutationDiagnostic.blockingPaths)
$protectedSystemMetadataOnlyPaths = @($protectedSystemMutationDiagnostic.metadataOnlyPaths)
$protectedSystemCorrelatedPaths = @($protectedSystemMutationDiagnostic.correlatedPaths)
$protectedSystemSpecializedActionPaths = @($protectedSystemMutationDiagnostic.specializedActionPaths)

$protectedMetadataOnlySourceSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($metadataSourcePath in @($protectedSystemMutationDiagnostic.metadataOnlySourcePaths)) {
    [void]$protectedMetadataOnlySourceSet.Add([string]$metadataSourcePath)
}
$modifiedFilesForPayload = @($changedFiles.ModifiedFiles | Where-Object {
    -not $protectedMetadataOnlySourceSet.Contains([string]$_)
})
$changedFileOnlyPaths = @($changedFiles.NewFiles) + @($modifiedFilesForPayload)
$driverInfPaths = @($changedFileOnlyPaths | Where-Object {
    (Convert-ToWindowsRelativePathForPolicy -Path ([string]$_)) -match '(?i)^Windows\\System32\\DriverStore\\FileRepository\\.+\.inf$'
})
$scheduledTaskFiles = @($changedFileOnlyPaths | Where-Object {
    (Convert-ToWindowsRelativePathForPolicy -Path ([string]$_)) -match '(?i)^Windows\\System32\\Tasks\\'
})

Write-Log ("Delta aplicable: {0:N0} archivo(s) nuevo(s), {1:N0} modificado(s), {2:N0} carpeta(s) nueva(s), {3:N0} carpeta(s) con metadatos modificados." -f `
    $changedFiles.NewFiles.Count, $modifiedFilesForPayload.Count, $changedFiles.NewDirs.Count, $changedFiles.ModifiedDirs.Count) -Level INFO
if ($protectedSystemMetadataOnlyPaths.Count -gt 0) {
    Write-Log ("Auditoria de integridad: {0:N0} archivo(s) protegido(s) conservaron el mismo SHA256; sus cambios de metadatos/USN no se incluiran en el payload." -f $protectedSystemMetadataOnlyPaths.Count) -Level INFO
    foreach ($metadataOnlyPath in $protectedSystemMetadataOnlyPaths) {
        Write-Log " - $metadataOnlyPath" -Level INFO
    }
}
if ($protectedSystemCorrelatedPaths.Count -gt 0) {
    Write-Log ("Integridad correlacionada: {0:N0} ruta(s) protegida(s) pertenecen al instalador segun tokens del producto o evidencia DriverStore del mismo delta; se conservaran y auditaran." -f $protectedSystemCorrelatedPaths.Count) -Level WARN
    foreach ($correlatedProtectedPath in $protectedSystemCorrelatedPaths) {
        Write-Log " - $correlatedProtectedPath" -Level INFO
    }
}
if ($changedFiles.NewDirs.Count -gt 0) {
    Write-Log ("Directorios nuevos detectados: {0:N0}. Se conservaran tambien los directorios vacios y sus metadatos." -f $changedFiles.NewDirs.Count) -Level INFO
}

$protectedSystemMutationDetected = ($protectedSystemMutationPaths.Count -gt 0)
if ($protectedSystemMutationDetected) {
    Write-Log ("BLOQUEO DE INTEGRIDAD: {0:N0} ruta(s) protegida(s) de Windows cambiaron de contenido, aparecieron, desaparecieron o no pudieron verificarse. No se generara el WIM." -f $protectedSystemMutationPaths.Count) -Level ERROR
    foreach ($protectedPath in $protectedSystemMutationPaths) {
        Write-Log " - $protectedPath" -Level ERROR
    }
}

$managedRuntimeChangedPaths = @($changedFileOnlyPaths) + @($changedFiles.NewDirs) + @($changedFiles.ModifiedDirs)
$managedRuntimeMaintenance = Get-ManagedRuntimeMaintenanceDiagnostic -ChangedPaths $managedRuntimeChangedPaths -DeletedPaths $deletedFiles -Policy $managedRuntimePolicy
$managedRuntimeMaintenanceDetected = [bool]$managedRuntimeMaintenance.detected
$managedRuntimeMaintenanceBlocking = [bool]$managedRuntimeMaintenance.blocking
if ($managedRuntimeMaintenanceBlocking) {
    Write-Log ("BLOQUEO DE INTEGRIDAD: se detecto una migracion masiva de Edge/WebView2 ({0:N0} mutaciones; {1:N0} en arboles versionados). No se generara el WIM." -f $managedRuntimeMaintenance.mutationCount, $managedRuntimeMaintenance.versionedMutationCount) -Level ERROR
    foreach ($family in @($managedRuntimeMaintenance.families)) {
        Write-Log (" - {0}: {1:N0} cambiada(s), {2:N0} eliminada(s), {3:N0} versionada(s)" -f $family.name, $family.changedCount, $family.deletedCount, $family.versionedMutationCount) -Level ERROR
    }
    foreach ($samplePath in @($managedRuntimeMaintenance.samplePaths)) {
        Write-Log "   muestra: $samplePath" -Level WARN
    }
} elseif ($managedRuntimeMaintenanceDetected) {
    Write-Log ("Edge/WebView2 detectado como componente intencional ({0:N0} mutaciones). Se incluira por captureSettings.allowManagedRuntimeUpdates=true." -f $managedRuntimeMaintenance.mutationCount) -Level WARN
}
$reparsePointChanges = @([DiffEngine]::GetChangedReparsePointRecords($enginePre, $enginePost))
$reproducibleReparsePointMutations = @($reparsePointChanges | Where-Object { [bool]$_.Reproducible })
$reparseChangesForStaging = @($reproducibleReparsePointMutations | Where-Object { $_.Operation -in @('add', 'replace') })
$reparsePointDeletions = @($reproducibleReparsePointMutations | Where-Object { $_.Operation -eq 'delete' })
$unsupportedReparsePointRecords = @($reparsePointChanges | Where-Object { -not [bool]$_.Reproducible })
$unsupportedReparsePointMutations = @($unsupportedReparsePointRecords | ForEach-Object {
    "{0}: {1} [{2}]" -f $_.Operation, $_.Path, $_.Reason
})
$unsupportedReparsePointMutationDetected = ($unsupportedReparsePointRecords.Count -gt 0)
if ($unsupportedReparsePointMutationDetected) {
    Write-Log ("BLOQUEO DE FIDELIDAD: {0:N0} reparse point(s) no tienen descriptor NTFS reproducible." -f $unsupportedReparsePointMutations.Count) -Level ERROR
    foreach ($reparseMutation in $unsupportedReparsePointMutations) { Write-Log " - $reparseMutation" -Level ERROR }
}
if ($reparseChangesForStaging.Count -gt 0) {
    Write-Log ("Reparse points reproducibles: {0:N0} alta(s)/reemplazo(s) se recrearan en Staging desde su descriptor NTFS RP1." -f $reparseChangesForStaging.Count) -Level INFO
}
foreach ($reparseDeletion in $reparsePointDeletions) {
    $deletedProfileRelative = (Split-Path $env:USERPROFILE -NoQualifier).TrimStart('\', '/')
    $deletedReparseRelative = Convert-ToPortableRelativePath -SourcePath ([string]$reparseDeletion.Path) -CurrentUserProfileRelative $deletedProfileRelative
    $deletionEntries.Add([pscustomobject][ordered]@{
        operation = 'delete'
        kind      = 'reparsePoint'
        path      = $deletedReparseRelative
        tag       = [string]$reparseDeletion.Tag
    }) | Out-Null
    $deletedListForReport.Add("$deletedReparseRelative\ (reparse point)") | Out-Null
}
$registryPortabilityBlocking = [bool]$registryPortabilityDiagnostic.blocking
$requiresSpecializedActions = (($protectedSystemSpecializedActionPaths.Count + $driverInfPaths.Count) -gt 0)
$engineIdentityStableBeforePackaging = $false
try {
    $prePackagingEngineIdentity = Get-DeltaPackEngineIdentity
    $engineIdentityStableBeforePackaging = (
        [string]$prePackagingEngineIdentity.scriptSha256 -eq [string]$engineIdentity.scriptSha256 -and
        [string]$prePackagingEngineIdentity.diffEngineSha256 -eq [string]$engineIdentity.diffEngineSha256 -and
        [string]$prePackagingEngineIdentity.exclusionsSha256 -eq [string]$engineIdentity.exclusionsSha256
    )
} catch {
    Write-Log "BLOQUEO DE IDENTIDAD: no se pudo verificar nuevamente el PS1, DiffEngine.cs y DeltaPack.Exclusions.json antes del empaquetado: $($_.Exception.Message)" -Level ERROR
}
if (-not $engineIdentityStableBeforePackaging) {
    Write-Log "BLOQUEO DE IDENTIDAD: uno o mas componentes del motor cambiaron durante la captura. No se generara el WIM." -Level ERROR
}
$captureBlockerDetected = ($protectedSystemMutationDetected -or $managedRuntimeMaintenanceBlocking -or $unsupportedReparsePointMutationDetected -or $registryPortabilityBlocking -or (-not $engineIdentityStableBeforePackaging))

$scanDiagnostic = Get-ScanHealthDiagnostic -PreMetrics $preScanMetrics -PostMetrics $postScanMetrics -HashThresholdBytes $hashThresholdBytesForDiagnostic -EffectiveParallelism $effectiveParallelismForDiagnostic -HashAllFiles $hashAllFilesForDiagnostic -UseUsnOptimization $useUsnOptimizationForDiagnostic `
    -PreFileUncertainPaths $preFileUncertainPaths -PostFileUncertainPaths $postFileUncertainPaths `
    -PreRegistryScanErrors $preRegistryScanErrors -PostRegistryScanErrors $postRegistryScanErrors `
    -ProtectedSystemMutationPaths $protectedSystemMutationPaths -ProtectedSystemMetadataOnlyPaths $protectedSystemMetadataOnlyPaths `
    -CorrelatedProtectedPaths $protectedSystemCorrelatedPaths `
    -ReproducibleReparsePointMutations $reproducibleReparsePointMutations `
    -UnsupportedReparsePointMutations $unsupportedReparsePointMutations `
    -RegistryCoverageDiagnostic $registryCoverageDiagnostic `
    -ManagedRuntimeMaintenance $managedRuntimeMaintenance
Write-ScanHealthDiagnosticSummary -Diagnostic $scanDiagnostic

# Liberar memoria del Snapshot 'Pre' que ya no se necesita
$enginePre = $null
[System.GC]::Collect()

$osInfo    = Get-CimInstance Win32_OperatingSystem
$osVersion = "$($osInfo.Caption) (Build $($osInfo.BuildNumber))"

# --- FASE 4: STAGING Y EMPAQUETADO (VSS INTEGRATED) ---
Write-Log "Fase 4/4: Extrayendo archivos (Soporte VSS para archivos bloqueados)..." -Level STEP
$fileCount         = 0
$directoryCount    = 0
$totalSizeBytes    = 0
$fileListForReport = New-Object System.Collections.Generic.List[string]
$directoryListForReport = New-Object System.Collections.Generic.List[string]
$copyFailures      = New-Object System.Collections.Generic.List[string]
$reparsePointsStaged = 0
$stagingApplicable = (-not $isDryRun)
$stagingAttempted = ((-not $isDryRun) -and (-not $captureBlockerDetected))
$stagingComplete = $false

$checksumLines     = New-Object System.Collections.Generic.List[string]

# Abstraccion segura del perfil de usuario
$currentUserProfile = Split-Path $env:USERPROFILE -NoQualifier
$currentUserProfile = $currentUserProfile.TrimStart('\', '/')

# Los candidatos se congelan antes de tocar Staging. De este modo el manifest
# no confunde objetos detectados con objetos realmente preparados.
$filesToCopy = @($changedFileOnlyPaths | Where-Object {
    -not $_.StartsWith($workspaceDir, [System.StringComparison]::OrdinalIgnoreCase)
})
$dirsToStageCandidates = @((@($changedFiles.NewDirs) + @($changedFiles.ModifiedDirs)) | Where-Object {
    -not $_.StartsWith($workspaceDir, [System.StringComparison]::OrdinalIgnoreCase)
})
$candidateRegularFileCount = $filesToCopy.Count
$candidateReparseFileCount = @($reparseChangesForStaging | Where-Object { [string]$_.Kind -ne 'directory' }).Count
$candidateReparseDirectoryCount = @($reparseChangesForStaging | Where-Object { [string]$_.Kind -eq 'directory' }).Count
$candidateFileCount = $candidateRegularFileCount + $candidateReparseFileCount
$candidateDirectoryCount = $dirsToStageCandidates.Count + $candidateReparseDirectoryCount
$candidateSizeBytes = [int64]0
foreach ($candidateFile in $filesToCopy) {
    try {
        $candidateInfo = [System.IO.FileInfo]::new($candidateFile)
        if ($candidateInfo.Exists) { $candidateSizeBytes += $candidateInfo.Length }
    } catch { }
}

if ($isDryRun -or $captureBlockerDetected) {
    if ($isDryRun) {
        Write-Log "Modo Dry Run activo: se omite la copia de archivos, VSS y la creacion del WIM." -Level WARN
    }
    if ($protectedSystemMutationDetected) {
        Write-Log "Staging, VSS y WIM omitidos porque el delta contiene mantenimiento de Windows no atribuible de forma segura al instalador." -Level ERROR
    }
    if ($managedRuntimeMaintenanceBlocking) {
        Write-Log "Staging, VSS y WIM omitidos porque una actualizacion masiva de Edge/EdgeCore/WebView2 coincidio con la captura." -Level ERROR
    }
    if ($unsupportedReparsePointMutationDetected) {
        Write-Log "Staging, VSS y WIM omitidos porque el delta contiene reparse points que el formato actual no puede reconstruir." -Level ERROR
    }
    if ($registryPortabilityBlocking) {
        Write-Log "Staging, VSS y WIM omitidos porque el REG conserva identidad del equipo o usuario capturador." -Level ERROR
    }
    if (-not $engineIdentityStableBeforePackaging) {
        Write-Log "Staging, VSS y WIM omitidos porque la identidad SHA256 del motor no permanecio estable." -Level ERROR
    }

    foreach ($file in $filesToCopy) {
        $relPath = Convert-ToPortableRelativePath -SourcePath $file -CurrentUserProfileRelative $currentUserProfile

        try {
            $fi = [System.IO.FileInfo]::new($file)
            if ($fi.Exists) {
                $fileCount++
                $totalSizeBytes += $fi.Length
                $fileListForReport.Add($relPath)
            }
        } catch { }
    }

    foreach ($dir in $dirsToStageCandidates) {
        $relDir = Convert-ToPortableRelativePath -SourcePath $dir -CurrentUserProfileRelative $currentUserProfile
        $directoryCount++
        $directoryListForReport.Add($relDir)
    }

    foreach ($reparseChange in $reparseChangesForStaging) {
        $reparseRelative = Convert-ToPortableRelativePath -SourcePath ([string]$reparseChange.Path) -CurrentUserProfileRelative $currentUserProfile
        if ([string]$reparseChange.Kind -eq 'directory') {
            $directoryCount++
            $directoryListForReport.Add("$reparseRelative [reparse $($reparseChange.Tag)]")
        } else {
            $fileCount++
            $fileListForReport.Add("$reparseRelative [reparse $($reparseChange.Tag)]")
        }
    }

    $wimOutputFile = $null
    $captureComplete = ($scanCoverageComplete -and (-not $captureBlockerDetected))
    if ($isDryRun) {
        Write-Log ("Cambios detectados: {0:N0} archivo(s), {1:N0} directorio(s), {2} estimados. Dry Run activo: no se copio ningun archivo." -f $fileCount, $directoryCount, (Format-ByteSize -Bytes $totalSizeBytes)) -Level SUCCESS
    } elseif ($protectedSystemMutationDetected) {
        Write-Log ("CAPTURA INCOMPLETA: {0:N0} archivo(s) y {1:N0} directorio(s) candidatos; no se copiaron porque se detectaron {2:N0} mutacion(es) protegida(s) de Windows." -f $fileCount, $directoryCount, $protectedSystemMutationPaths.Count) -Level ERROR
    } elseif ($managedRuntimeMaintenanceBlocking) {
        Write-Log ("CAPTURA CONTAMINADA: {0:N0} archivo(s) y {1:N0} directorio(s) candidatos; no se copiaron porque {2:N0} mutacion(es) de Edge/WebView2 coincidieron con la captura." -f $fileCount, $directoryCount, $managedRuntimeMaintenance.mutationCount) -Level ERROR
    } elseif ($unsupportedReparsePointMutationDetected) {
        Write-Log ("CAPTURA INCOMPLETA: {0:N0} archivo(s) y {1:N0} directorio(s) candidatos; no se copiaron porque existen {2:N0} mutacion(es) de reparse points no reproducibles." -f $fileCount, $directoryCount, $unsupportedReparsePointMutations.Count) -Level ERROR
    } elseif (-not $engineIdentityStableBeforePackaging) {
        Write-Log ("CAPTURA INCOMPLETA: {0:N0} archivo(s) y {1:N0} directorio(s) candidatos; no se copiaron porque la identidad SHA256 del motor cambio." -f $fileCount, $directoryCount) -Level ERROR
    } elseif ($registryPortabilityBlocking) {
        Write-Log ("CAPTURA NO PORTABLE: {0:N0} referencia(s) al equipo y {1:N0} referencia(s) al usuario permanecen en el REG." -f $registryPortabilityDiagnostic.machineNameReferenceCount, $registryPortabilityDiagnostic.captureIdentityReferenceCount) -Level ERROR
    } else {
        Write-Log "CAPTURA INCOMPLETA: un control fail-closed impidio preparar el Staging." -Level ERROR
    }
} else {
# --- 0. CREACION DE DIRECTORIOS NUEVOS CON METADATOS ---
Reset-DeltaPackStaging -StagingPath $stagingDir -WorkspacePath $workspaceDir
$dirsToStage = @($dirsToStageCandidates | Sort-Object { $_.Length })

foreach ($dir in $dirsToStage) {
    $relDir  = Convert-ToPortableRelativePath -SourcePath $dir -CurrentUserProfileRelative $currentUserProfile
    $oldDirPath = (Split-Path $dir -NoQualifier).TrimStart('\', '/')
    $isPortableProfileDirectory = ($oldDirPath -ne $relDir)
    $destDir = Join-Path $stagingDir $relDir
    try {
        if (-not (Test-PathWithin -Path $destDir -Parent $stagingDir)) {
            throw "La ruta relativa escapa del directorio Staging."
        }
        $metadataWarning = [DiffEngine]::CreateDirectoryWithMetadata($dir, $destDir)
        if (-not [string]::IsNullOrWhiteSpace($metadataWarning)) {
            $copyFailures.Add("Directorio sin metadatos completos: $relDir -> $metadataWarning")
            Write-Log "Metadatos incompletos en directorio $relDir : $metadataWarning" -Level ERROR
        }
        if ($isPortableProfileDirectory) {
            $profileSecurityWarning = [DiffEngine]::ApplyPortableProfileSecurity($destDir, $true)
            if (-not [string]::IsNullOrWhiteSpace($profileSecurityWarning)) {
                throw "No se pudo normalizar la ACL portable del perfil: $profileSecurityWarning"
            }
        }
        $directoryCount++
        $directoryListForReport.Add($relDir)
    } catch {
        $copyFailures.Add("No se pudo preparar el directorio: $relDir -> $($_.Exception.Message)")
        Write-Log "ERROR preparando directorio $relDir : $($_.Exception.Message)" -Level ERROR
    }
}

# --- 1. INICIALIZACION VSS ---
$systemDrive = $env:SystemDrive + "\"
$stagingVssSnapshot = New-DeltaPackVssSnapshot -DriveRoot $systemDrive -Purpose "extraccion de Staging"
$vssDeviceObject = $null
if ($null -ne $stagingVssSnapshot) {
    $vssDeviceObject = [string]$stagingVssSnapshot.DeviceObject
}

# --- 2. BUCLE DE EXTRACCION ---
$copyTotal     = $filesToCopy.Count
$copyProcessed = 0

if ($copyTotal -gt 0) {
    Write-Log ("Preparando copia: {0:N0} archivo(s) candidato(s) al Staging." -f $copyTotal) -Level INFO
    Write-FileCopyProgress -Processed 0 -Total $copyTotal -Copied 0 -Bytes 0 -CurrentFile $null
} else {
    Write-Log "No hay archivos candidatos para copiar al Staging." -Level INFO
}

foreach ($file in $filesToCopy) {

    if ($file.StartsWith($workspaceDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Log "Auto-exclusion: Ignorando archivo interno del workspace: $(Split-Path $file -Leaf)" -Level INFO
        continue
    }

    $isDir = ($enginePost.FileSnapshot.ContainsKey($file) -and [DiffEngine]::IsDirectoryFingerprint([string]$enginePost.FileSnapshot[$file]))
    if ($isDir) {
        continue
    }

    $oldPath = (Split-Path $file -NoQualifier).TrimStart('\', '/')
    $relPath = Convert-ToPortableRelativePath -SourcePath $file -CurrentUserProfileRelative $currentUserProfile
    $isPortableProfileFile = ($oldPath -ne $relPath)
    if ($oldPath -ne $relPath) {
        Write-Log "Redirigiendo perfil: $oldPath -> $relPath" -Level INFO -NoConsole
    }

    $destPath = Join-Path $stagingDir $relPath
    if (-not (Test-PathWithin -Path $destPath -Parent $stagingDir)) {
        $copyFailures.Add("Ruta de destino insegura: $relPath")
        Write-Log "ERROR: La ruta de destino escapa del Staging: $relPath" -Level ERROR
        continue
    }

    $copyProcessed++
    Write-FileCopyProgress -Processed $copyProcessed -Total $copyTotal -Copied $fileCount -Bytes $totalSizeBytes -CurrentFile $file

    $destFolder  = Split-Path $destPath -Parent
    $fileCopied  = $false
    $hashHex     = $null
    $metadataPreserved = $false
    $failureRecorded = $false

    try {
        if (-not [System.IO.Directory]::Exists($destFolder)) {
            [System.IO.Directory]::CreateDirectory($destFolder) | Out-Null
        }

        # Intento 1: copia nativa, metadatos NTFS y verificacion SHA256.
        $copyResult = [DiffEngine]::CopyAndHash($file, $destPath)
        $hashHex    = [string]$copyResult.HashHex
        $metadataPreserved = [bool]$copyResult.MetadataPreserved
        $fileCopied = $true

    } catch {
        # Intento 2: Copia VSS (Rescate de archivo en uso/bloqueado)
        # File.Copy puede haber dejado un destino parcial o ReadOnly. Se elimina
        # antes del segundo intento para que el rescate no herede ese estado.
        Remove-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue
        $fileDrive = Split-Path $file -Qualifier
        if ($null -ne $vssDeviceObject -and $fileDrive -ieq $env:SystemDrive) {
            Write-Log "Archivo bloqueado detectado. Rescatando desde VSS: $file" -Level WARN
            try {
                $vssFilePath = $file -replace "^$([regex]::Escape($env:SystemDrive))", $vssDeviceObject
                $copyResult = [DiffEngine]::CopyAndHash($vssFilePath, $destPath)
                $hashHex    = [string]$copyResult.HashHex
                $metadataPreserved = [bool]$copyResult.MetadataPreserved
                $fileCopied = $true
                Write-Log "Rescate VSS exitoso para: $relPath" -Level SUCCESS
            } catch {
                $copyFailures.Add("No se pudo copiar: $relPath -> $($_.Exception.Message)")
                $failureRecorded = $true
                Write-Log "ERROR CRITICO: El archivo resistio incluso a VSS: $file -> $($_.Exception.Message)" -Level ERROR
            }
        } else {
            $copyFailures.Add("No se pudo copiar: $relPath -> $($_.Exception.Message)")
            $failureRecorded = $true
            Write-Log "ERROR: Archivo omitido; VSS no esta disponible para su volumen: $file" -Level ERROR
        }
    }

    if ($fileCopied) {
        $expectedHash = Get-SnapshotSha256 -Engine $enginePost -Path $file
        if ([string]::IsNullOrWhiteSpace($expectedHash)) {
            $copyFailures.Add("Fingerprint final no verificable: $relPath")
            $failureRecorded = $true
            Write-Log "ERROR: El snapshot final no contiene SHA256 verificable para $relPath" -Level ERROR
        } elseif ($hashHex -ne $expectedHash) {
            $copyFailures.Add("El archivo cambio despues del snapshot: $relPath")
            $failureRecorded = $true
            $fileCopied = $false
            Remove-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue
            Write-Log "ERROR: El contenido de $relPath cambio entre el snapshot y la copia. Captura no determinista." -Level ERROR
        }

        if (-not $metadataPreserved) {
            $metadataDetail = if ($null -ne $copyResult) { [string]$copyResult.MetadataWarning } else { "Metadatos no disponibles" }
            $copyFailures.Add("Metadatos NTFS incompletos: $relPath -> $metadataDetail")
            $failureRecorded = $true
            Write-Log "ERROR: No se preservaron todos los metadatos de $relPath : $metadataDetail" -Level ERROR
        }

        if ($fileCopied -and $isPortableProfileFile) {
            $profileSecurityWarning = [DiffEngine]::ApplyPortableProfileSecurity($destPath, $false)
            if (-not [string]::IsNullOrWhiteSpace($profileSecurityWarning)) {
                $copyFailures.Add("ACL portable incompleta: $relPath -> $profileSecurityWarning")
                $failureRecorded = $true
                Write-Log "ERROR: No se pudo eliminar el SID del usuario capturador en $relPath : $profileSecurityWarning" -Level ERROR
            }
        }
    }

    if ($fileCopied) {
        $fileInfo = [System.IO.FileInfo]::new($destPath)
        if ($fileInfo.Exists) {
            $fileCount++
            $totalSizeBytes += $fileInfo.Length
            $fileListForReport.Add($relPath)

            if (-not [string]::IsNullOrEmpty($hashHex)) {
                $checksumLines.Add("$hashHex  $relPath")
            }

            Write-FileCopyProgress -Processed $copyProcessed -Total $copyTotal -Copied $fileCount -Bytes $totalSizeBytes -CurrentFile $file
        }
    } elseif (-not $failureRecorded) {
        $copyFailures.Add("No se pudo completar la copia: $relPath")
    }
}

# --- 2B. RECREACION NATIVA DE REPARSE POINTS ---
foreach ($reparseChange in $reparseChangesForStaging) {
    $sourceReparsePath = [string]$reparseChange.Path
    $relReparsePath = Convert-ToPortableRelativePath -SourcePath $sourceReparsePath -CurrentUserProfileRelative $currentUserProfile
    $destReparsePath = Join-Path $stagingDir $relReparsePath
    try {
        if (-not (Test-PathWithin -Path $destReparsePath -Parent $stagingDir)) {
            throw 'La ruta relativa del reparse point escapa de Staging.'
        }
        $oldReparsePath = (Split-Path $sourceReparsePath -NoQualifier).TrimStart('\', '/')
        if ($oldReparsePath -ne $relReparsePath) {
            throw 'Los reparse points dentro del perfil capturador requieren saneamiento de destino especializado y no se trasladan a Users\Default.'
        }
        $reparseCopyResult = [DiffEngine]::CopyReparsePoint($sourceReparsePath, $destReparsePath, [string]$reparseChange.Descriptor)
        if (-not [bool]$reparseCopyResult.MetadataPreserved) {
            Write-Log "Metadatos del objeto reparse heredados de Staging: $relReparsePath -> $($reparseCopyResult.MetadataWarning)" -Level WARN -NoConsole
        }

        $reparsePointsStaged++
        if ([string]$reparseChange.Kind -eq 'directory') {
            $directoryCount++
            $directoryListForReport.Add("$relReparsePath [reparse $($reparseChange.Tag)]")
        } else {
            $fileCount++
            $fileListForReport.Add("$relReparsePath [reparse $($reparseChange.Tag)]")
        }
        $checksumLines.Add("$($reparseCopyResult.DescriptorSha256)  $relReparsePath [reparse-descriptor]")
        Write-Log "Reparse point recreado: $relReparsePath [$($reparseChange.Tag)]" -Level SUCCESS -NoConsole
    } catch {
        $copyFailures.Add("No se pudo recrear reparse point: $relReparsePath -> $($_.Exception.Message)")
        Write-Log "ERROR recreando reparse point $relReparsePath : $($_.Exception.Message)" -Level ERROR
    }
}

# Crear archivos altera LastWriteTime de sus carpetas padre. Restauramos los
# metadatos de directorio de abajo hacia arriba antes de capturar el WIM.
foreach ($dir in @($dirsToStage | Sort-Object { $_.Length } -Descending)) {
    $relDir  = Convert-ToPortableRelativePath -SourcePath $dir -CurrentUserProfileRelative $currentUserProfile
    $destDir = Join-Path $stagingDir $relDir
    try {
        $metadataWarning = [DiffEngine]::CreateDirectoryWithMetadata($dir, $destDir)
        if (-not [string]::IsNullOrWhiteSpace($metadataWarning)) {
            $copyFailures.Add("No se pudieron restaurar metadatos finales del directorio: $relDir -> $metadataWarning")
        }
        $oldDirPath = (Split-Path $dir -NoQualifier).TrimStart('\', '/')
        if ($oldDirPath -ne $relDir) {
            $profileSecurityWarning = [DiffEngine]::ApplyPortableProfileSecurity($destDir, $true)
            if (-not [string]::IsNullOrWhiteSpace($profileSecurityWarning)) {
                $copyFailures.Add("No se pudo restaurar ACL portable del directorio: $relDir -> $profileSecurityWarning")
            }
        }
    } catch {
        $copyFailures.Add("No se pudieron restaurar metadatos finales del directorio: $relDir -> $($_.Exception.Message)")
    }
}

if ($copyTotal -gt 0) {
    $regularFilesStaged = [math]::Max(0, ($fileCount - $reparsePointsStaged))
    Write-FileCopyProgress -Processed $copyTotal -Total $copyTotal -Copied $regularFilesStaged -Bytes $totalSizeBytes `
        -Failures $copyFailures.Count -ReparseStaged $reparsePointsStaged -ReparseTotal $reparseChangesForStaging.Count -Completed
}

# --- 3. LIMPIEZA VSS ---
if ($null -ne $stagingVssSnapshot) {
    $stagingVssRemoved = Remove-DeltaPackVssSnapshot -Snapshot $stagingVssSnapshot
}

$stagingComplete = ($copyFailures.Count -eq 0)
$captureComplete = ($scanCoverageComplete -and $stagingComplete -and (-not $captureBlockerDetected))
if ($captureComplete) {
    Write-Log ("Staging verificado: {0:N0} archivo(s), {1:N0} directorio(s), {2} total." -f $fileCount, $directoryCount, (Format-ByteSize -Bytes $totalSizeBytes)) -Level SUCCESS
} else {
    Write-Log ("CAPTURA INCOMPLETA: {0:N0} problema(s) de staging; cobertura de escaneo completa: {1}. No se generara un WIM utilizable." -f $copyFailures.Count, $scanCoverageComplete) -Level ERROR
}

# La identidad se comprueba otra vez despues de Staging para cerrar la ventana
# entre el primer control y la invocacion de DISM. Si cambia, el workspace se
# conserva y el contenedor nunca llega a crearse.
if ($captureComplete) {
    try {
        $preWimEngineIdentity = Get-DeltaPackEngineIdentity
        $engineIdentityStableBeforePackaging = (
            $engineIdentityStableBeforePackaging -and
            [string]$preWimEngineIdentity.scriptSha256 -eq [string]$engineIdentity.scriptSha256 -and
            [string]$preWimEngineIdentity.diffEngineSha256 -eq [string]$engineIdentity.diffEngineSha256 -and
            [string]$preWimEngineIdentity.exclusionsSha256 -eq [string]$engineIdentity.exclusionsSha256
        )
    } catch {
        $engineIdentityStableBeforePackaging = $false
        Write-Log "BLOQUEO DE IDENTIDAD: no se pudo verificar el motor inmediatamente antes de DISM: $($_.Exception.Message)" -Level ERROR
    }
    if (-not $engineIdentityStableBeforePackaging) {
        $captureBlockerDetected = $true
        $captureComplete = $false
        Write-Log "BLOQUEO DE IDENTIDAD: el motor cambio durante Staging. El WIM no se generara y el workspace se conservara." -Level ERROR
    }
}

# --- 4. CREACION DEL WIM ---
$wimCaptureMetrics = $null
if ($captureComplete -and (($fileCount -gt 0) -or ($directoryCount -gt 0))) {
    $wimOutputFile = Join-Path $outDir "$($script:DeltaPackPackageFullName).wim"
    $dismLog       = Join-Path $outDir "dism.log"
    $scratchDir    = Join-Path ($env:SystemDrive + "\") ("DP_" + [Guid]::NewGuid().ToString("N").Substring(0,8))
    $scratchCreated = $false

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
        try {
            # Directorio corto, unico y propiedad exclusiva de esta ejecucion.
            # New-Item no expone -LiteralPath en Windows PowerShell 5.1.
            # $scratchDir se construye internamente con GUID y no contiene comodines.
            New-Item -Path $scratchDir -ItemType Directory -ErrorAction Stop | Out-Null
            $scratchCreated = $true

            $dateStr  = Get-Date -Format "yyyy-MM-dd HH:mm"
            $nameMeta = "$($script:DeltaPackPackageFullName) [DeltaPack]"
            $descMeta = "App: $($script:DeltaPackPackageBaseName) | Modulo: $($script:DeltaPackPackageType) | Arch: $($script:DeltaPackPackageArchitecture) | SO Captura: $osVersion | Fecha: $dateStr"

            Write-Log "Comprimiendo contenedor (Max Compression) usando Scratch exclusivo en $scratchDir..." -Level INFO
            Write-Host "`nIniciando captura WIM. Se mostrara actividad, tiempo y tamano escrito..." -ForegroundColor Yellow

            $wimCaptureMetrics = Invoke-DeltaPackWimCapture `
                -ImagePath $wimOutputFile `
                -CapturePath $stagingDir `
                -ImageName $nameMeta `
                -ImageDescription $descMeta `
                -LogPath $dismLog `
                -ScratchDirectory $scratchDir

            Write-Log ("Paquete WIM creado exitosamente en {0}; tamano comprimido: {1}." -f `
                $wimCaptureMetrics.elapsed, (Format-ByteSize -Bytes ([int64]$wimCaptureMetrics.finalSizeBytes))) -Level SUCCESS
        } catch {
            Write-Log "Fallo al crear WIM: $($_.Exception.Message)" -Level ERROR
            Write-Log "Log detallado disponible en: $(Split-Path $dismLog -Leaf)" -Level ERROR
            if (Test-Path $wimOutputFile) { Remove-Item $wimOutputFile -Force }
            $wimOutputFile = $null
        } finally {
            if ($scratchCreated -and (Test-Path -LiteralPath $scratchDir)) {
                Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Log "Empaquetado WIM omitido por falta de espacio. El .reg y el manifiesto ya fueron generados; libera espacio y vuelve a ejecutar para obtener el .wim." -Level WARN
        $wimOutputFile = $null
    }
} elseif (-not $captureComplete) {
    Write-Log "WIM omitido porque la captura no supero las verificaciones de cobertura, integridad o metadatos." -Level ERROR
    $wimOutputFile = $null
} else {
    Write-Log "No se detectaron cambios en archivos. No se generara paquete WIM." -Level WARN
    $wimOutputFile = $null
}
}

$stagingStatus = if (-not $stagingApplicable) {
    'notApplicable'
} elseif (-not $stagingAttempted) {
    'blocked'
} elseif ($stagingComplete) {
    'complete'
} else {
    'incomplete'
}
$captureIntegrityStatus = if ($isDryRun) {
    'notApplicable'
} elseif ($captureComplete) {
    'complete'
} else {
    'incomplete'
}

$checksumsFile = $null
if (-not $isDryRun -and $captureComplete -and $checksumLines.Count -gt 0) {
    $checksumsFile = Join-Path $outDir "Checksums_$($script:DeltaPackPackageFullName).sha256"
    try {
        $checksumEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($checksumsFile, [string[]]$checksumLines, $checksumEncoding)
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

# 2. Formateo de Tamaño Dinamico (Maneja tamanos menores a 1MB). El tamaño
# candidato y el realmente preparado no se mezclan cuando Staging falla.
$candidateSizeDisplay = Format-ByteSize -Bytes $candidateSizeBytes
$stagedSizeDisplay = Format-ByteSize -Bytes $totalSizeBytes

if ($null -eq $preScanMetrics)  { $preScanMetrics  = Get-FileScanMetricsSnapshot -Engine $enginePre  -Phase "Pre" }
if ($null -eq $postScanMetrics) { $postScanMetrics = Get-FileScanMetricsSnapshot -Engine $enginePost -Phase "Post" }
$hashThresholdBytes = [int64][DiffEngine]::HashThresholdBytes
$hashAllFiles = [bool][DiffEngine]::HashAllFiles
$useUsnOptimization = [bool][DiffEngine]::UseUsnOptimization
$maxScanParallelism = [int][DiffEngine]::MaxScanParallelism
$effectiveParallelism = [DiffEngine]::GetEffectiveParallelism()
if ($null -eq $scanDiagnostic) {
    $scanDiagnostic = Get-ScanHealthDiagnostic -PreMetrics $preScanMetrics -PostMetrics $postScanMetrics -HashThresholdBytes $hashThresholdBytes -EffectiveParallelism $effectiveParallelism -HashAllFiles $hashAllFiles -UseUsnOptimization $useUsnOptimization `
        -PreFileUncertainPaths $preFileUncertainPaths -PostFileUncertainPaths $postFileUncertainPaths `
        -PreRegistryScanErrors $preRegistryScanErrors -PostRegistryScanErrors $postRegistryScanErrors `
        -ProtectedSystemMutationPaths $protectedSystemMutationPaths -ProtectedSystemMetadataOnlyPaths $protectedSystemMetadataOnlyPaths `
        -CorrelatedProtectedPaths $protectedSystemCorrelatedPaths `
        -ReproducibleReparsePointMutations $reproducibleReparsePointMutations `
        -UnsupportedReparsePointMutations $unsupportedReparsePointMutations `
        -RegistryCoverageDiagnostic $registryCoverageDiagnostic `
        -ManagedRuntimeMaintenance $managedRuntimeMaintenance
}
$scanDiagnosticMarkdown = Convert-ScanDiagnosticToMarkdown -Diagnostic $scanDiagnostic

$reportFile = Join-Path $outDir "README_$($script:DeltaPackPackageFullName).md"
$dateStr    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Tombstones estructurados. El inyector debe aplicarlos de forma explicita;
# nunca se ocultan dentro del WIM porque ese formato es aditivo.
$structuredArtifactFailures = New-Object System.Collections.Generic.List[string]
$actionableDeletionCount = [int]$deletionEntries.Count
$filesystemAuditOnlyDeletionCount = [int]$filesystemDeletionAuditOnly.Count
$registryDeletionAuditOnly = @(
    @($auditOnlyRegistryKeyDeletions | ForEach-Object { [string]$_ })
    @($taskCacheDeletionAuditOnly | ForEach-Object { [string]$_ })
) | Sort-Object -Unique
$registryAuditOnlyDeletionCount = [int]$registryDeletionAuditOnly.Count
$auditOnlyDeletionCount = [int]($filesystemAuditOnlyDeletionCount + $registryAuditOnlyDeletionCount)
$deletionEvidenceCount = [int]($actionableDeletionCount + $auditOnlyDeletionCount)
$deletionRequiresInjector = (($actionableDeletionCount -gt 0) -and (-not $allowAuditOnlyDeletions))
$deletionApplyPolicy = if ($actionableDeletionCount -eq 0) {
    'auditOnlyEvidence'
} elseif ($allowAuditOnlyDeletions) {
    'auditOnlyByExplicitConfiguration'
} else {
    'requiredBeforeRegistryImport'
}
$deletionsFile = $null
if ($deletionEvidenceCount -gt 0) {
    $deletionsCandidate = Join-Path $outDir "Deletions_$($script:DeltaPackPackageFullName).json"
    try {
        # Windows PowerShell 5.1 no materializa de forma fiable List[object]
        # mediante @($lista) dentro de un OrderedDictionary. ToArray evita el
        # error "Los tipos de argumentos no coinciden" y conserva [] en JSON.
        [object[]]$deletionEntriesArray = $deletionEntries.ToArray()
        [object[]]$filesystemAuditOnlyArray = $filesystemDeletionAuditOnly.ToArray()
        [object[]]$registryAuditOnlyArray = @($registryDeletionAuditOnly | ForEach-Object { [string]$_ })
        $deletionsObject = [ordered]@{
            schemaVersion = 2
            generatedBy = "DeltaPack Dual-Engine v$($script:Version)"
            package = [ordered]@{
                fullName = $script:DeltaPackPackageFullName
                identitySha256 = $script:DeltaPackPackageIdentitySha256
            }
            applyPolicy = $deletionApplyPolicy
            requiresDeletionAwareInjector = $deletionRequiresInjector
            actionableEntryCount = $actionableDeletionCount
            auditOnlyEntryCount = $auditOnlyDeletionCount
            filesystemAuditOnlyEntryCount = $filesystemAuditOnlyDeletionCount
            registryAuditOnlyEntryCount = $registryAuditOnlyDeletionCount
            entries = $deletionEntriesArray
            filesystemAuditOnly = $filesystemAuditOnlyArray
            registryAuditOnly = $registryAuditOnlyArray
        }
        Write-ValidatedJsonFile -InputObject $deletionsObject -Path $deletionsCandidate -Depth 7 -ExpectedSchemaVersion 2 `
            -RequiredProperties @('schemaVersion', 'package', 'applyPolicy', 'requiresDeletionAwareInjector', 'actionableEntryCount', 'auditOnlyEntryCount', 'filesystemAuditOnlyEntryCount', 'registryAuditOnlyEntryCount', 'entries', 'filesystemAuditOnly', 'registryAuditOnly')
        $deletionsFile = $deletionsCandidate
        $deletionsLogLevel = if ($deletionRequiresInjector) { 'WARN' } else { 'INFO' }
        Write-Log "Manifiesto de eliminaciones generado y validado: $(Split-Path $deletionsFile -Leaf)" -Level $deletionsLogLevel
    } catch {
        if (Test-Path -LiteralPath $deletionsCandidate) {
            Remove-Item -LiteralPath $deletionsCandidate -Force -ErrorAction SilentlyContinue
        }
        $deletionsFile = $null
        $structuredArtifactFailures.Add("Deletions JSON: $($_.Exception.Message)") | Out-Null
        Write-Log "ERROR DE ARTEFACTO: No se pudo generar un Deletions JSON valido: $($_.Exception.Message)" -Level ERROR
    }
}

# Acciones que un inyector offline debe ejecutar o validar fuera de una copia
# WIM+REG simple. El WIM sigue conteniendo los reparse points recreados; el
# manifiesto conserva su descriptor para verificacion post-aplicacion.
$portableDriverInfPaths = @($driverInfPaths | ForEach-Object {
    Convert-ToPortableRelativePath -SourcePath ([string]$_) -CurrentUserProfileRelative $currentUserProfile
} | Sort-Object -Unique)
$portableScheduledTaskFiles = @($scheduledTaskFiles | ForEach-Object {
    Convert-ToPortableRelativePath -SourcePath ([string]$_) -CurrentUserProfileRelative $currentUserProfile
} | Sort-Object -Unique)
$portableReparseActions = @($reparsePointChanges | ForEach-Object {
    [pscustomobject][ordered]@{
        operation = [string]$_.Operation
        path = (Convert-ToPortableRelativePath -SourcePath ([string]$_.Path) -CurrentUserProfileRelative $currentUserProfile)
        kind = [string]$_.Kind
        tag = [string]$_.Tag
        descriptorSha256 = [string]$_.DescriptorSha256
        descriptor = if ([bool]$_.Reproducible -and $_.Operation -ne 'delete') { [string]$_.Descriptor } else { $null }
        reproducible = [bool]$_.Reproducible
    }
})
$actionsFile = $null
$hasActionEvidence = (($protectedSystemSpecializedActionPaths.Count + $portableDriverInfPaths.Count + $portableScheduledTaskFiles.Count + $portableReparseActions.Count) -gt 0 -or [bool]$registryPortabilityDiagnostic.requiresSameSystemDrive)
if ($hasActionEvidence) {
    $actionsCandidate = Join-Path $outDir "Actions_$($script:DeltaPackPackageFullName).json"
    try {
        $actionsObject = [ordered]@{
            schemaVersion = 2
            generatedBy = "DeltaPack Dual-Engine v$($script:Version)"
            package = [ordered]@{
                fullName = $script:DeltaPackPackageFullName
                identitySha256 = $script:DeltaPackPackageIdentitySha256
            }
            requiresActionAwareInjector = $requiresSpecializedActions
            injectorSupportDeclared = $actionAwareInjector
            sourceSystemDrive = [string]$registryPortabilityDiagnostic.sourceSystemDrive
            requiresSameSystemDrive = [bool]$registryPortabilityDiagnostic.requiresSameSystemDrive
            phases = [ordered]@{
                afterWimBeforeRegistry = [ordered]@{
                    driverPackages = @($portableDriverInfPaths | ForEach-Object {
                        [pscustomobject][ordered]@{ operation = 'addDriverOffline'; infPath = [string]$_; required = $true }
                    })
                    protectedCatalogs = @($protectedSystemSpecializedActionPaths | ForEach-Object {
                        [pscustomobject][ordered]@{ operation = 'registerOrValidateCatalog'; path = [string]$_; required = $true }
                    })
                }
                afterRegistry = [ordered]@{
                    scheduledTasks = @($portableScheduledTaskFiles | ForEach-Object {
                        [pscustomobject][ordered]@{ operation = 'validateScheduledTaskRegistration'; taskFile = [string]$_; required = $false }
                    })
                    reparsePoints = @($portableReparseActions)
                }
            }
            note = 'El orden obligatorio es WIM, acciones afterWimBeforeRegistry, entries accionables de Deletions JSON si existen, REG y validaciones afterRegistry. filesystemAuditOnly y registryAuditOnly son evidencia y no se ejecutan. Un controlador o catalogo no se considera instalado por la sola copia de archivos.'
        }
        Write-ValidatedJsonFile -InputObject $actionsObject -Path $actionsCandidate -Depth 9 -ExpectedSchemaVersion 2 `
            -RequiredProperties @('schemaVersion', 'package', 'requiresActionAwareInjector', 'injectorSupportDeclared', 'phases')
        $actionsFile = $actionsCandidate
        Write-Log "Manifiesto de acciones offline generado y validado: $(Split-Path $actionsFile -Leaf)" -Level WARN
        if ($requiresSpecializedActions -and -not $actionAwareInjector) {
            Write-Log 'El paquete requiere acciones de catalogos/controladores y no se marcara listo hasta que captureSettings.actionAwareInjector=true confirme soporte del inyector.' -Level WARN
        }
    } catch {
        if (Test-Path -LiteralPath $actionsCandidate) {
            Remove-Item -LiteralPath $actionsCandidate -Force -ErrorAction SilentlyContinue
        }
        $actionsFile = $null
        $structuredArtifactFailures.Add("Actions JSON: $($_.Exception.Message)") | Out-Null
        Write-Log "ERROR DE ARTEFACTO: No se pudo generar un Actions JSON valido: $($_.Exception.Message)" -Level ERROR
    }
}
$deletionArtifactComplete = (($deletionEvidenceCount -eq 0) -or ($null -ne $deletionsFile -and (Test-Path -LiteralPath $deletionsFile -PathType Leaf)))
$actionArtifactComplete = ((-not $hasActionEvidence) -or ($null -ne $actionsFile -and (Test-Path -LiteralPath $actionsFile -PathType Leaf)))
$engineIdentityStable = $false
try {
    $finalEngineIdentity = Get-DeltaPackEngineIdentity
    $engineIdentityStable = (
        $engineIdentityStableBeforePackaging -and
        [string]$finalEngineIdentity.scriptSha256 -eq [string]$engineIdentity.scriptSha256 -and
        [string]$finalEngineIdentity.diffEngineSha256 -eq [string]$engineIdentity.diffEngineSha256 -and
        [string]$finalEngineIdentity.exclusionsSha256 -eq [string]$engineIdentity.exclusionsSha256
    )
    if (-not $engineIdentityStable) {
        $structuredArtifactFailures.Add('Identidad del motor: uno o mas componentes cambiaron durante la captura.') | Out-Null
        Write-Log 'ERROR DE INTEGRIDAD: el PS1, DiffEngine.cs o DeltaPack.Exclusions.json cambio durante la captura.' -Level ERROR
    }
} catch {
    $structuredArtifactFailures.Add("Identidad del motor: $($_.Exception.Message)") | Out-Null
    Write-Log "ERROR DE INTEGRIDAD: no se pudo volver a verificar la identidad del motor: $($_.Exception.Message)" -Level ERROR
}
if (-not $engineIdentityStable) {
    $captureBlockerDetected = $true
    $captureComplete = $false
    $captureIntegrityStatus = 'incomplete'
    if ($wimOutputFile -and (Test-Path -LiteralPath $wimOutputFile -PathType Leaf)) {
        try {
            Remove-Item -LiteralPath $wimOutputFile -Force -ErrorAction Stop
            Write-Log "WIM descartado porque la identidad final del motor no coincide con la identidad inicial." -Level ERROR
            $wimOutputFile = $null
        } catch {
            $structuredArtifactFailures.Add("WIM no confiable: no se pudo eliminar despues del fallo de identidad: $($_.Exception.Message)") | Out-Null
            Write-Log "ERROR CRITICO: el WIM no es confiable y no pudo eliminarse: $($_.Exception.Message)" -Level ERROR
        }
    }
    if ($checksumsFile -and (Test-Path -LiteralPath $checksumsFile -PathType Leaf)) {
        try {
            Remove-Item -LiteralPath $checksumsFile -Force -ErrorAction Stop
            $checksumsFile = $null
        } catch {
            $structuredArtifactFailures.Add("Checksums de payload: no se pudieron retirar despues del fallo de identidad: $($_.Exception.Message)") | Out-Null
        }
    }
}
$structuredArtifactGenerationComplete = ($deletionArtifactComplete -and $actionArtifactComplete -and $engineIdentityStable -and $structuredArtifactFailures.Count -eq 0)

$windowsVersionInfo = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

# =================================================================
#  GENERACION DEL MANIFEST JSON
# =================================================================
$manifestFile = Join-Path $outDir "manifest_$($script:DeltaPackPackageFullName).json"
$hasFilePayload = (($candidateFileCount -gt 0) -or ($candidateDirectoryCount -gt 0))
$hasWimOutput = ($wimOutputFile -and (Test-Path -LiteralPath $wimOutputFile))
$stagedFileCountForReport = if ($stagingAttempted) { $fileCount } else { 0 }
$stagedDirectoryCountForReport = if ($stagingAttempted) { $directoryCount } else { 0 }
$sizeDisplay = if ($hasWimOutput) { $stagedSizeDisplay } else { $candidateSizeDisplay }
$deletionCompatibilityOk = ($deletionArtifactComplete -and (-not $deletionRequiresInjector))
$actionCompatibilityOk = ($actionArtifactComplete -and ((-not $requiresSpecializedActions) -or $actionAwareInjector))
$packageReady = ((-not $isDryRun) -and $captureComplete -and $structuredArtifactGenerationComplete -and $deletionCompatibilityOk -and $actionCompatibilityOk -and (-not $hasFilePayload -or $hasWimOutput))
$manifestObj  = [ordered]@{
    schemaVersion    = 6
    generatedBy      = "DeltaPack Dual-Engine v$($script:Version)"
    engineIdentity   = [ordered]@{
        schemaVersion = [int]$engineIdentity.schemaVersion
        scriptSha256 = [string]$engineIdentity.scriptSha256
        diffEngineSha256 = [string]$engineIdentity.diffEngineSha256
        exclusionsSha256 = [string]$engineIdentity.exclusionsSha256
        stableDuringCapture = $engineIdentityStable
    }
    captureTimestamp = (Get-Date -Format "s")   # ISO 8601 sortable: 2025-06-01T14:30:00
    package          = [ordered]@{
        fullName     = $script:DeltaPackPackageFullName
        baseName     = $script:DeltaPackPackageBaseName
        type         = $script:DeltaPackPackageType
        architecture = $script:DeltaPackPackageArchitecture
        identitySha256 = $script:DeltaPackPackageIdentitySha256
        sourceOS     = $osVersion
    }
    host             = [ordered]@{
        computerName = $env:COMPUTERNAME
        psVersion    = "$($PSVersionTable.PSVersion)"
        capturePrivileges = @($capturePrivilegeResults | ForEach-Object {
            [pscustomobject][ordered]@{
                name      = [string]$_.Name
                enabled   = [bool]$_.Enabled
                errorCode = [int]$_.ErrorCode
            }
        })
    }
    compatibility    = [ordered]@{
        architecture = $script:DeltaPackPackageArchitecture
        buildNumber  = [string]$osInfo.BuildNumber
        ubr          = if ($null -ne $windowsVersionInfo) { [int]$windowsVersionInfo.UBR } else { $null }
        editionId    = if ($null -ne $windowsVersionInfo) { [string]$windowsVersionInfo.EditionID } else { $null }
        displayVersion = if ($null -ne $windowsVersionInfo) { [string]$windowsVersionInfo.DisplayVersion } else { $null }
        installationType = if ($null -ne $windowsVersionInfo) { [string]$windowsVersionInfo.InstallationType } else { $null }
        culture      = ([System.Globalization.CultureInfo]::CurrentUICulture).Name
        sourceSystemDrive = [string]$registryPortabilityDiagnostic.sourceSystemDrive
        requiresSameSystemDrive = [bool]$registryPortabilityDiagnostic.requiresSameSystemDrive
        policy       = 'sameArchitectureAndCompatibleWindowsServicingBaseline'
    }
    stats            = [ordered]@{
        fileCount               = $candidateFileCount
        candidateFileCount      = $candidateFileCount
        candidateRegularFileCount = $candidateRegularFileCount
        candidateReparseFileCount = $candidateReparseFileCount
        stagedFileCount         = $stagedFileCountForReport
        candidateDirectoryCount = $candidateDirectoryCount
        candidateReparseDirectoryCount = $candidateReparseDirectoryCount
        stagedDirectoryCount    = $stagedDirectoryCountForReport
        candidateSizeBytes      = $candidateSizeBytes
        stagedSizeBytes         = if ($stagingAttempted) { $totalSizeBytes } else { 0 }
        filesPackaged           = if ($hasWimOutput) { $fileCount } else { 0 }
        newFilesInDelta         = $changedFiles.NewFiles.Count
        modifiedFilesObserved   = $modifiedFilesObservedCount
        modifiedFilesInDelta    = $modifiedFilesForPayload.Count
        newDirectoriesDetected  = $changedFiles.NewDirs.Count
        modifiedDirectoriesDetected = $changedFiles.ModifiedDirs.Count
        reparsePointMutations = $reparsePointChanges.Count
        reparsePointsExpected = $reparseChangesForStaging.Count
        reparsePointsStaged   = $reparsePointsStaged
        reparsePointDeletions = $reparsePointDeletions.Count
        directoriesPackaged     = if ($hasWimOutput) { $directoryCount } else { 0 }
        packagedSizeBytes       = if ($hasWimOutput) { $totalSizeBytes } else { 0 }
        wimContainerSizeBytes   = if ($null -ne $wimCaptureMetrics) { [int64]$wimCaptureMetrics.finalSizeBytes } else { 0 }
        wimCaptureElapsedMilliseconds = if ($null -ne $wimCaptureMetrics) { [int64]$wimCaptureMetrics.elapsedMilliseconds } else { 0 }
        wimCaptureElapsed       = if ($null -ne $wimCaptureMetrics) { [string]$wimCaptureMetrics.elapsed } else { $null }
        wimProgressMode         = if ($null -ne $wimCaptureMetrics) { [string]$wimCaptureMetrics.progressMode } else { 'notApplicable' }
        emptyDirectoriesSupported = $true
        totalSizeBytes          = $candidateSizeBytes
        totalSizeMB             = [math]::Round($candidateSizeBytes / 1MB, 2)
        registryTotalEntries    = $regMetrics.TotalEntries
        registryKeysAdded       = $regKeysCount
        registryValuesAdded     = $regValuesCount
        registryKeysDeleted     = $regKeysDeleted
        registryValuesDeleted   = $regValuesDeleted
        registryKeysDeletedAuditOnly = $auditOnlyRegistryKeyDeletions.Count
        registryMutationsAuditOnly = $auditOnlyRegistryMutations.Count
        filesDeletedDuringCapture = $deletedListForReport.Count
        filesDeletedByInstaller   = $actionableDeletionCount
        actionableDeletions       = $actionableDeletionCount
        filesystemDeletionsAuditOnly = $filesystemAuditOnlyDeletionCount
        registryDeletionsAuditOnly = $registryAuditOnlyDeletionCount
    }
    scan             = [ordered]@{
        hashThresholdBytes = $hashThresholdBytes
        hashAllFiles       = $hashAllFiles
        useUsnOptimization = $useUsnOptimization
        fileScanMaxAttempts = [int][DiffEngine]::FileScanMaxAttempts
        fileScanRetryDelayMs = [int][DiffEngine]::FileScanRetryDelayMilliseconds
        useVssScanFallback = [bool]$useVssScanFallback
        mode               = if ($useUsnOptimization -and $hashAllFiles) { "SafeUSN" } elseif ($hashAllFiles) { "FullSHA256" } else { "Hybrid" }
        hashThresholdLabel = if ($useUsnOptimization -and $hashAllFiles) { "USN seguro + SHA256 con fallback" } elseif ($hashAllFiles) { "SHA256 completo" } elseif ($hashThresholdBytes -le 0) { "Metadatos LastWriteTimeUtc-Length" } else { "SHA256 para archivos menores de $(Format-ByteSize -Bytes $hashThresholdBytes)" }
        maxParallelism     = $maxScanParallelism
        effectiveParallelism = $effectiveParallelism
        coverageComplete  = $scanCoverageComplete
        diagnostic        = $scanDiagnostic
        pre               = $preScanMetrics
        post              = $postScanMetrics
        uncertainPaths    = [ordered]@{
            preFiles      = $preFileUncertainPaths
            postFiles     = $postFileUncertainPaths
            preFileDetails = $preFileUncertainDetails
            postFileDetails = $postFileUncertainDetails
            preRegistry   = $preRegistryScanErrors
            postRegistry  = $postRegistryScanErrors
        }
        registryCoverage = $registryCoverageDiagnostic
    }
    staging          = [ordered]@{
        applicable               = $stagingApplicable
        attempted                = $stagingAttempted
        status                   = $stagingStatus
        complete                 = $stagingComplete
        candidateFileCount       = $candidateFileCount
        stagedFileCount          = $stagedFileCountForReport
        candidateDirectoryCount  = $candidateDirectoryCount
        stagedDirectoryCount     = $stagedDirectoryCountForReport
        reparsePointsExpected    = $reparseChangesForStaging.Count
        reparsePointsStaged      = $reparsePointsStaged
        failureCount             = $copyFailures.Count
        failures                 = @($copyFailures)
        metadataPolicy           = "ReadOnly se neutraliza temporalmente; timestamps y atributos exactos se restauran antes de ACL; propietario, grupo y streams NTFS se preservan"
    }
    systemIntegrity  = [ordered]@{
        protectedMutationDetected = $protectedSystemMutationDetected
        protectedMutationCount    = $protectedSystemMutationPaths.Count
        protectedMutationPaths    = @($protectedSystemMutationPaths)
        protectedMetadataOnlyCount = $protectedSystemMetadataOnlyPaths.Count
        protectedMetadataOnlyPaths = @($protectedSystemMetadataOnlyPaths)
        correlatedProtectedMutationCount = $protectedSystemCorrelatedPaths.Count
        correlatedProtectedMutationPaths = @($protectedSystemCorrelatedPaths)
        specializedActionPaths = @($protectedSystemSpecializedActionPaths)
        protectedMutationEvaluations = @($protectedSystemMutationDiagnostic.evaluations)
        managedRuntimeMaintenanceDetected = $managedRuntimeMaintenanceDetected
        managedRuntimeMaintenanceBlocking = $managedRuntimeMaintenanceBlocking
        managedRuntimeMaintenance = $managedRuntimeMaintenance
        unsupportedReparsePointMutationDetected = $unsupportedReparsePointMutationDetected
        unsupportedReparsePointMutations = @($unsupportedReparsePointMutations)
        reproducibleReparsePointMutationCount = $reproducibleReparsePointMutations.Count
        reparsePointActions = @($portableReparseActions)
        registryPortabilityBlocking = $registryPortabilityBlocking
        engineIdentityStableBeforePackaging = $engineIdentityStableBeforePackaging
        blockerDetected           = $captureBlockerDetected
        policy                    = "failClosed"
        note                      = "Las rutas protegidas con SHA256 identico se omiten como metadatos; catalogos correlacionados por tokens del producto o DriverStore se conservan con Actions JSON. Huellas no verificables, cambios en la identidad del motor, reparse points sin descriptor RP1, identidad del host y migraciones masivas no autorizadas bloquean el WIM."
    }
    deletions        = [ordered]@{
        applyPolicy          = $deletionApplyPolicy
        requiresDeletionAwareInjector = $deletionRequiresInjector
        actionableEntryCount = $actionableDeletionCount
        auditOnlyEntryCount = $auditOnlyDeletionCount
        filesystemAuditOnlyEntryCount = $filesystemAuditOnlyDeletionCount
        registryAuditOnlyEntryCount = $registryAuditOnlyDeletionCount
        file                 = if ($deletionsFile) { Split-Path $deletionsFile -Leaf } else { $null }
        filesAndDirectories  = @($deletedListForReport)
        filesystemAuditOnly = @($filesystemDeletionAuditOnly.ToArray())
        registryAuditOnly    = @($registryDeletionAuditOnly)
        registryPolicy       = "Las eliminaciones protegidas por registryDeletionAuditRules, TaskCache no correlacionado y CLSID directos sin referencia se documentan, pero no se importan en la imagen offline."
        note                 = "Elementos eliminados durante la ventana de captura. AdminImagenOffline debe aplicar solo entries; filesystemAuditOnly y registryAuditOnly son evidencia no destructiva. Un WIM aditivo no elimina archivos y los cambios ambientales no correlacionados tampoco se ejecutan."
    }
    registryFiltering = [ordered]@{
        applyPolicy             = "correlatedOnly"
        auditOnlyMutations      = @($auditOnlyRegistryMutations)
        transientNotifyIconAumidExcluded = $true
        postRebootBranchesExcluded = @(
            "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppReadiness",
            "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Package Installation",
            "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Mrt\_Merged"
        )
        dynamicTaskMetadataExcluded = $true
        taskCachePolicy         = "Tasks, Tree e indices solo se exportan cuando GUID, ruta de tarea y archivo fisico nuevo/modificado estan correlacionados."
        comAppIdPolicy          = "Una mutacion AppID-only en un CLSID se omite cuando no existe servidor COM, referencia externa o clave AppID nueva/modificada correlacionada."
        portability             = $registryPortabilityDiagnostic
        bundledOneDriveIncluded = $includeBundledOneDrive
    }
    deployment       = [ordered]@{
        target       = "AdminImagenOffline"
        packageIdentitySha256 = $script:DeltaPackPackageIdentitySha256
        actionsSchemaVersion = 2
        deletionsSchemaVersion = 2
        order        = @("Aplicar WIM", "Aplicar Actions afterWimBeforeRegistry si existe", "Aplicar entries accionables de Deletions JSON si existen", "Importar REG", "Validar Actions afterRegistry")
        userProfile  = "Users\Default"
        registryMode = "Hives offline"
        fileCopyRequirements = @("/E", "/B", "/COPY:DATSO", "/DCOPY:DAT", "/SECFIX")
        securityNote = "El WIM conserva DACL, propietario y grupo; el inyector debe copiar esa seguridad NTFS al destino offline."
        requiresDeletionSupport = $deletionRequiresInjector
        requiresActionSupport = $requiresSpecializedActions
        actionSupportDeclared = $actionAwareInjector
    }
    outputs          = [ordered]@{
        wimFile       = if ($wimOutputFile -and (Test-Path $wimOutputFile)) { Split-Path $wimOutputFile -Leaf } else { $null }
        regFile       = if (Test-Path $regOutputFile)  { Split-Path $regOutputFile  -Leaf } else { $null }
        checksumsFile = if ($checksumsFile)             { Split-Path $checksumsFile  -Leaf } else { $null }
        deletionsFile = if ($deletionsFile)             { Split-Path $deletionsFile -Leaf } else { $null }
        actionsFile    = if ($actionsFile)               { Split-Path $actionsFile -Leaf } else { $null }
        readmeFile    = Split-Path $reportFile -Leaf
        manifestFile  = "manifest_$($script:DeltaPackPackageFullName).json"
        artifactChecksumsFile = $null
    }
    flags            = [ordered]@{
        isDryRun             = $isDryRun
        scanCoverageComplete = $scanCoverageComplete
        stagingApplicable    = $stagingApplicable
        stagingComplete      = $stagingComplete
        captureIntegrityStatus = $captureIntegrityStatus
        captureComplete      = $captureComplete
        packageReady         = $packageReady
        wimCreated           = ($null -ne $wimOutputFile -and (Test-Path $wimOutputFile))
        actionCompatibilityComplete = $actionCompatibilityOk
        structuredArtifactsComplete = $structuredArtifactGenerationComplete
        structuredArtifactFailures = @($structuredArtifactFailures.ToArray())
        artifactIntegrityComplete = $false
    }
}
try {
    Write-ValidatedJsonFile -InputObject $manifestObj -Path $manifestFile -Depth 8 -ExpectedSchemaVersion 6 `
        -RequiredProperties @('schemaVersion', 'engineIdentity', 'package', 'scan', 'staging', 'deletions', 'deployment', 'outputs', 'flags')
    Write-Log "Manifiesto JSON generado y validado: $(Split-Path $manifestFile -Leaf)" -Level SUCCESS
} catch {
    Write-Log "ERROR DE ARTEFACTO: No se pudo escribir un manifest.json valido: $($_.Exception.Message)" -Level ERROR
    $structuredArtifactFailures.Add("Manifest JSON: $($_.Exception.Message)") | Out-Null
    $structuredArtifactGenerationComplete = $false
    $packageReady = $false
    $manifestFile = $null
}

$dryRunBanner   = if ($isDryRun) { "> **MODO DRY RUN - VISTA PREVIA.** No se copio ningun archivo ni se genero un paquete `` .wim ``." } else { "" }
$incompleteBanner = if (-not $captureComplete) { "> **CAPTURA INCOMPLETA.** Se detectaron problemas de cobertura, integridad o metadatos. El WIM fue bloqueado para evitar desplegar un paquete parcial." } else { "" }
$engineIdentityBanner = if (-not $engineIdentityStable) { "> **IDENTIDAD DEL MOTOR MODIFICADA.** El PS1, DiffEngine.cs o DeltaPack.Exclusions.json cambio durante la ventana de captura. El WIM fue bloqueado o descartado y el workspace se conservo." } else { "" }
$systemMutationBanner = if ($protectedSystemMutationDetected) { "> **MANTENIMIENTO DE WINDOWS DETECTADO.** Rutas protegidas cambiaron de contenido, aparecieron, desaparecieron o no pudieron verificarse. Repite la captura desde cero cuando Windows haya terminado su mantenimiento." } else { "" }
$managedRuntimeBanner = if ($managedRuntimeMaintenanceBlocking) { "> **ACTUALIZACION MASIVA DE EDGE/WEBVIEW2 DETECTADA.** Las diferencias se conservaron para auditoria, pero Staging, VSS y WIM fueron bloqueados para evitar mezclar versiones ajenas al instalador." } elseif ($managedRuntimeMaintenanceDetected) { "> **EDGE/WEBVIEW2 INCLUIDO INTENCIONALMENTE.** La configuracion permite este runtime; valida el paquete en una VM destino." } else { "" }
$reparseBanner = if ($unsupportedReparsePointMutationDetected) {
    "> **REPARSE POINTS NO REPRODUCIBLES.** Uno o mas enlaces no pudieron leerse como descriptor NTFS RP1. El WIM fue bloqueado."
} elseif ($reparseChangesForStaging.Count -gt 0 -and $isDryRun) {
    "> **REPARSE POINTS INVENTARIADOS.** Se detectaron $($reparseChangesForStaging.Count) enlace(s) nativo(s) reproducible(s). No se modifico Staging en Dry Run; se recrearan durante la Captura Completa y sus descriptores quedaron en Actions/manifest."
} elseif ($reparseChangesForStaging.Count -gt 0 -and $reparsePointsStaged -eq $reparseChangesForStaging.Count) {
    "> **REPARSE POINTS PRESERVADOS.** Se recrearon $reparsePointsStaged enlace(s) nativo(s) en Staging y sus descriptores quedaron en Actions/manifest."
} elseif ($reparseChangesForStaging.Count -gt 0) {
    "> **REPARSE POINTS INCOMPLETOS.** Se recrearon $reparsePointsStaged de $($reparseChangesForStaging.Count) enlace(s) nativo(s) en Staging. La captura no debe desplegarse hasta completar esta fase."
} else { "" }
$portabilityBanner = if ($registryPortabilityBlocking) { "> **REGISTRO LIGADO AL HOST.** Permanecen referencias al equipo, perfil o SID capturador. El WIM fue bloqueado hasta sanearlas." } else { "" }
$structuredArtifactsBanner = if (-not $structuredArtifactGenerationComplete) { "> **ARTEFACTOS JSON INCOMPLETOS.** Uno o mas manifiestos estructurados no superaron serializacion y validacion. ``packageReady`` permanece en ``false`` y no se publica el indice de artefactos." } else { "" }
$actionsBanner = if ($requiresSpecializedActions -and -not $actionAwareInjector -and $actionsFile) { "> **ACCIONES OFFLINE REQUERIDAS.** Se genero ``$(Split-Path $actionsFile -Leaf)`` para catalogos/controladores. El WIM puede existir, pero ``packageReady`` permanece en ``false`` hasta confirmar un inyector compatible." } else { "" }
$deletionsBanner = if ($deletionRequiresInjector -and $deletionsFile) { "> **ELIMINACIONES REQUERIDAS.** El paquete incluye ``$(Split-Path $deletionsFile -Leaf)`` y no se considera listo hasta que el inyector aplique sus tombstones accionables." } else { "" }
$reportBannerLines = @(
    @(
        $dryRunBanner
        $incompleteBanner
        $engineIdentityBanner
        $structuredArtifactsBanner
        $systemMutationBanner
        $managedRuntimeBanner
        $reparseBanner
        $portabilityBanner
        $actionsBanner
        $deletionsBanner
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
)
$reportBannerBlock = if ($reportBannerLines.Count -gt 0) {
    "`r`n" + ($reportBannerLines -join "`r`n`r`n") + "`r`n"
} else { "" }
$directoriesPackagedForReport = if ($hasWimOutput) { $directoryCount } else { 0 }
$sizeMetricLabel = if ($hasWimOutput) { "Tamaño Total Descomprimido del WIM" } else { "Tamaño Estimado de Candidatos" }
$stagingStatusDisplay = switch ($stagingStatus) {
    'notApplicable' { 'No aplica (Dry Run)' }
    'blocked'       { 'Bloqueado antes de Staging' }
    'complete'      { 'Completo' }
    default         { 'Incompleto' }
}
$captureIntegrityStatusDisplay = switch ($captureIntegrityStatus) {
    'notApplicable' { 'No aplica (Dry Run)' }
    'complete'      { 'Completa' }
    default         { 'Incompleta' }
}
$manifestoDescTxt = if ($captureBlockerDetected -and -not $stagingAttempted) {
    "A continuacion se detallan los archivos candidatos detectados. No se copiaron al Staging porque el control de integridad bloqueo la captura."
} elseif ($captureBlockerDetected) {
    "A continuacion se detallan los archivos preparados en Staging. El WIM fue bloqueado o descartado por un control de integridad posterior y el workspace se conservo para diagnostico."
} elseif ($isDryRun) {
    "A continuacion, se detalla la ruta relativa de los archivos que se incluirian en el paquete (vista previa; ningun archivo fue copiado)."
} elseif ($hasWimOutput) {
    "A continuacion, se detalla la ruta relativa de los archivos contenidos en el paquete WIM."
} else {
    "A continuacion, se detallan los archivos preparados en Staging. No pertenecen a un WIM porque la captura fue bloqueada."
}

$systemIntegrityMarkdownBuilder = New-Object System.Text.StringBuilder
[void]$systemIntegrityMarkdownBuilder.AppendLine("## Integridad del Sistema Base")
[void]$systemIntegrityMarkdownBuilder.AppendLine("")
if ($captureBlockerDetected) {
    [void]$systemIntegrityMarkdownBuilder.AppendLine("**Estado:** BLOQUEADO (fail-closed)  ")
    if ($protectedSystemMutationDetected) {
        [void]$systemIntegrityMarkdownBuilder.AppendLine("Se detectaron $($protectedSystemMutationPaths.Count) rutas protegidas con cambio de contenido, alta, eliminacion o huella no verificable durante la ventana de captura:")
        [void]$systemIntegrityMarkdownBuilder.AppendLine("")
        foreach ($protectedPath in $protectedSystemMutationPaths) {
            [void]$systemIntegrityMarkdownBuilder.AppendLine("- ``$protectedPath``")
        }
        [void]$systemIntegrityMarkdownBuilder.AppendLine("")
    }
    if ($managedRuntimeMaintenanceDetected) {
        [void]$systemIntegrityMarkdownBuilder.AppendLine(("Se detectaron {0:N0} mutaciones de Edge/EdgeCore/WebView2 ({1:N0} versionadas; {2:N0} cambiadas y {3:N0} eliminadas)." -f $managedRuntimeMaintenance.mutationCount, $managedRuntimeMaintenance.versionedMutationCount, $managedRuntimeMaintenance.changedCount, $managedRuntimeMaintenance.deletedCount))
        [void]$systemIntegrityMarkdownBuilder.AppendLine("")
        foreach ($family in @($managedRuntimeMaintenance.families)) {
            [void]$systemIntegrityMarkdownBuilder.AppendLine(("- **{0}:** {1:N0} cambiadas, {2:N0} eliminadas, {3:N0} versionadas" -f $family.name, $family.changedCount, $family.deletedCount, $family.versionedMutationCount))
        }
        [void]$systemIntegrityMarkdownBuilder.AppendLine("")
        [void]$systemIntegrityMarkdownBuilder.AppendLine("Muestra de rutas (maximo 25):")
        [void]$systemIntegrityMarkdownBuilder.AppendLine("")
        foreach ($samplePath in @($managedRuntimeMaintenance.samplePaths)) {
            [void]$systemIntegrityMarkdownBuilder.AppendLine("- ``$samplePath``")
        }
        [void]$systemIntegrityMarkdownBuilder.AppendLine("")
    }
    if ($unsupportedReparsePointMutationDetected) {
        [void]$systemIntegrityMarkdownBuilder.AppendLine("Se detectaron $($unsupportedReparsePointMutations.Count) reparse points sin descriptor NTFS reproducible:")
        [void]$systemIntegrityMarkdownBuilder.AppendLine("")
        foreach ($reparseMutation in $unsupportedReparsePointMutations) {
            [void]$systemIntegrityMarkdownBuilder.AppendLine("- ``$reparseMutation``")
        }
        [void]$systemIntegrityMarkdownBuilder.AppendLine("")
    }
    if ($registryPortabilityBlocking) {
        [void]$systemIntegrityMarkdownBuilder.AppendLine(("El REG conserva {0:N0} referencia(s) al nombre del equipo y {1:N0} al perfil/SID capturador." -f $registryPortabilityDiagnostic.machineNameReferenceCount, $registryPortabilityDiagnostic.captureIdentityReferenceCount))
        [void]$systemIntegrityMarkdownBuilder.AppendLine("")
    }
    if (-not $engineIdentityStable) {
        [void]$systemIntegrityMarkdownBuilder.AppendLine("La identidad SHA256 del PS1, DiffEngine.cs o DeltaPack.Exclusions.json no permanecio estable; el WIM se bloqueo o se descarto y el workspace quedo conservado.")
        [void]$systemIntegrityMarkdownBuilder.AppendLine("")
    }
    [void]$systemIntegrityMarkdownBuilder.AppendLine("El WIM no se publica como confiable. Corrige las causas concretas descritas arriba y repite la captura desde un snapshot limpio.")
} else {
    [void]$systemIntegrityMarkdownBuilder.AppendLine("**Estado:** Sin mutaciones protegidas bloqueantes ni migraciones masivas de runtimes administrados.")
}
if ($protectedSystemCorrelatedPaths.Count -gt 0) {
    [void]$systemIntegrityMarkdownBuilder.AppendLine("")
    [void]$systemIntegrityMarkdownBuilder.AppendLine("Se conservaron $($protectedSystemCorrelatedPaths.Count) cambios protegidos correlacionados con tokens del producto o DriverStore:")
    [void]$systemIntegrityMarkdownBuilder.AppendLine("")
    foreach ($correlatedPath in $protectedSystemCorrelatedPaths) {
        [void]$systemIntegrityMarkdownBuilder.AppendLine("- ``$correlatedPath``")
    }
    [void]$systemIntegrityMarkdownBuilder.AppendLine("")
    if ($actionsFile) {
        [void]$systemIntegrityMarkdownBuilder.AppendLine("Los catalogos/controladores que requieren registro offline se describen en ``$(Split-Path $actionsFile -Leaf)``.")
    } else {
        [void]$systemIntegrityMarkdownBuilder.AppendLine('No se pudo publicar Actions JSON; el paquete permanece bloqueado por integridad de artefactos.')
    }
}
if ($reproducibleReparsePointMutations.Count -gt 0) {
    [void]$systemIntegrityMarkdownBuilder.AppendLine("")
    [void]$systemIntegrityMarkdownBuilder.AppendLine("Reparse points reproducibles: $($reproducibleReparsePointMutations.Count); recreados en Staging: $reparsePointsStaged; eliminaciones enviadas como tombstones: $($reparsePointDeletions.Count).")
}
if ($protectedSystemMetadataOnlyPaths.Count -gt 0) {
    [void]$systemIntegrityMarkdownBuilder.AppendLine("")
    [void]$systemIntegrityMarkdownBuilder.AppendLine("Se omitieron $($protectedSystemMetadataOnlyPaths.Count) cambios de metadatos en rutas protegidas porque el SHA256 inicial y final fue identico:")
    [void]$systemIntegrityMarkdownBuilder.AppendLine("")
    foreach ($metadataOnlyPath in $protectedSystemMetadataOnlyPaths) {
        [void]$systemIntegrityMarkdownBuilder.AppendLine("- ``$metadataOnlyPath``")
    }
    [void]$systemIntegrityMarkdownBuilder.AppendLine("")
    [void]$systemIntegrityMarkdownBuilder.AppendLine("Estos archivos no se copiaron al payload. Un cambio de contenido o una huella incompleta sigue siendo bloqueante.")
}
[void]$systemIntegrityMarkdownBuilder.AppendLine("")
$systemIntegrityMarkdown = $systemIntegrityMarkdownBuilder.ToString()

# 3. Generacion del Markdown por Bloques (Evita OutOfMemory en listas inmensas)
$mdHeader = @"
# Reporte de Paquete: $($script:DeltaPackPackageFullName)
$reportBannerBlock
**Generado automaticamente por DeltaPack Dual-Engine v$($script:Version)**
* **Fecha:** $dateStr
* **Host:** $($env:COMPUTERNAME)
* **SO de Captura:** $($osInfo.Caption) (Build $($osInfo.BuildNumber))
* **SHA256 PS1:** ``$($engineIdentity.scriptSha256)``
* **SHA256 DiffEngine:** ``$($engineIdentity.diffEngineSha256)``
* **SHA256 Exclusiones:** ``$($engineIdentity.exclusionsSha256)``
* **SHA256 Identidad del Paquete:** ``$($script:DeltaPackPackageIdentitySha256)``
* **Identidad estable durante la captura:** $engineIdentityStable

## Resumen Estadistico

| Metrica | Valor |
|---|---|
| Archivos Candidatos Totales | $candidateFileCount |
| Archivos Regulares Candidatos | $candidateRegularFileCount |
| Archivos Reparse Candidatos | $candidateReparseFileCount |
| Archivos Preparados en Staging | $stagedFileCountForReport |
| Archivos Nuevos Detectados | $($changedFiles.NewFiles.Count) |
| Archivos Modificados Observados | $modifiedFilesObservedCount |
| Archivos Modificados Aplicables | $($modifiedFilesForPayload.Count) |
| Carpetas Nuevas Detectadas | $($changedFiles.NewDirs.Count) |
| Carpetas con Metadatos Modificados | $($changedFiles.ModifiedDirs.Count) |
| Directorios Candidatos | $candidateDirectoryCount |
| Directorios Preparados en Staging | $stagedDirectoryCountForReport |
| Directorios Empaquetados en WIM | $directoriesPackagedForReport |
| Modo de Ejecucion | $(if ($isDryRun) { "Dry Run / Vista Previa" } else { "Captura Completa" }) |
| Cobertura del Escaneo | $(if ($scanCoverageComplete) { "Completa" } else { "Incompleta" }) |
| Estado de Staging | $stagingStatusDisplay |
| Integridad de Captura | $captureIntegrityStatusDisplay |
| WIM Generado | $(if ($hasWimOutput) { "Si" } else { "No" }) |
| Paquete Listo para Inyeccion | $packageReady |
| Problemas de Staging | $($copyFailures.Count) |
| $sizeMetricLabel | $sizeDisplay |
| Tamaño Comprimido del Contenedor WIM | $(if ($null -ne $wimCaptureMetrics) { Format-ByteSize -Bytes ([int64]$wimCaptureMetrics.finalSizeBytes) } else { "No aplica" }) |
| Tiempo de Captura y Verificación WIM | $(if ($null -ne $wimCaptureMetrics) { [string]$wimCaptureMetrics.elapsed } else { "No aplica" }) |
| Monitor de Progreso WIM | $(if ($null -ne $wimCaptureMetrics) { "Actividad indeterminada con tiempo/tamaño" } else { "No aplica" }) |
| Claves de Registro Agregadas/Modificadas (.reg) | $regKeysCount |
| Valores de Registro Agregados/Modificados | $regValuesCount |
| Claves de Registro Eliminadas (.reg) | $regKeysDeleted |
| Valores de Registro Eliminados | $regValuesDeleted |
| Claves de Registro Protegidas/No Correlacionadas Eliminadas (solo auditoria) | $($auditOnlyRegistryKeyDeletions.Count) |
| Mutaciones COM/TaskCache no correlacionadas (solo auditoria) | $($auditOnlyRegistryMutations.Count) |
| Archivos/Carpetas Eliminados Durante la Captura | $($deletedListForReport.Count) |
| Mutaciones Protegidas Bloqueantes | $($protectedSystemMutationPaths.Count) |
| Metadatos Protegidos Omitidos (SHA256 igual) | $($protectedSystemMetadataOnlyPaths.Count) |
| Mutaciones Protegidas Correlacionadas | $($protectedSystemCorrelatedPaths.Count) |
| Brechas Estables de Registro | $($registryCoverageDiagnostic.stableKnownGapCount) |
| Errores Bloqueantes de Registro | $($registryCoverageDiagnostic.blockingCount) |
| Mutaciones Edge/EdgeCore/WebView2 | $($managedRuntimeMaintenance.mutationCount) (versionadas: $($managedRuntimeMaintenance.versionedMutationCount); bloqueo: $managedRuntimeMaintenanceBlocking) |
| Reparse Points Reproducibles | $($reproducibleReparsePointMutations.Count) (Staging: $reparsePointsStaged) |
| Reparse Points No Reproducibles | $($unsupportedReparsePointMutations.Count) |
| Referencias de Host Bloqueantes en REG | $($registryPortabilityDiagnostic.machineNameReferenceCount + $registryPortabilityDiagnostic.captureIdentityReferenceCount) |
| Acciones Offline Especializadas | $(if ($requiresSpecializedActions) { "Requeridas" } else { "No requeridas" }) |
| Eliminaciones que Requieren Inyector Compatible | $(if ($deletionRequiresInjector) { $actionableDeletionCount } else { 0 }) |
| Eliminaciones de Archivos Solo Auditoria | $filesystemAuditOnlyDeletionCount |
| Eliminaciones de Registro Solo Auditoria | $registryAuditOnlyDeletionCount |
| Integridad SHA256 del Payload/WIM | $(if ($checksumsFile) { "Si - $(Split-Path $checksumsFile -Leaf)" } elseif ($isDryRun) { "No aplica en Dry Run (no existe payload copiado)" } else { "No generado (captura incompleta o sin archivos)" }) |
| Integridad SHA256 de Artefactos | $(if ($manifestFile -and $structuredArtifactGenerationComplete) { "Programada al finalizar - Artifacts_$($script:DeltaPackPackageFullName).sha256" } else { "Bloqueada: falta un JSON estructurado valido" }) |

## Metricas Internas de Escaneo de Archivos

| Fase | Indexados | SHA256 leido | SHA reutilizado por USN | Fallback USN | Omitidos | Directorios | Hash leido | Lectura evitada | Tiempo |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Snapshot Inicial | $($preScanMetrics.filesIndexed) | $($preScanMetrics.filesHashed) | $($preScanMetrics.filesVerifiedByUsn) | $($preScanMetrics.filesUsnFallback) | $($preScanMetrics.filesSkipped) | $($preScanMetrics.directoriesScanned) | $($preScanMetrics.hashBytesReadLabel) | $($preScanMetrics.hashBytesAvoidedByUsnLabel) | $($preScanMetrics.elapsed) |
| Snapshot Final | $($postScanMetrics.filesIndexed) | $($postScanMetrics.filesHashed) | $($postScanMetrics.filesVerifiedByUsn) | $($postScanMetrics.filesUsnFallback) | $($postScanMetrics.filesSkipped) | $($postScanMetrics.directoriesScanned) | $($postScanMetrics.hashBytesReadLabel) | $($postScanMetrics.hashBytesAvoidedByUsnLabel) | $($postScanMetrics.elapsed) |

Detalle de omisiones: excluidos, reparse points, acceso denegado, errores I/O y otros quedan separados por archivos/directorios en el manifest JSON.

## Metricas Internas de Escaneo del Registro

| Fase | Claves | Valores | Ramas excluidas | Valores omitidos | Errores | Tiempo |
|---|---:|---:|---:|---:|---:|---:|
| Snapshot Inicial | $($preScanMetrics.registryKeysIndexed) | $($preScanMetrics.registryValuesIndexed) | $($preScanMetrics.registryBranchesExcluded) | $($preScanMetrics.registryValuesExcluded) | $($preScanMetrics.registryScanErrorCount) | $($preScanMetrics.registryElapsed) |
| Snapshot Final | $($postScanMetrics.registryKeysIndexed) | $($postScanMetrics.registryValuesIndexed) | $($postScanMetrics.registryBranchesExcluded) | $($postScanMetrics.registryValuesExcluded) | $($postScanMetrics.registryScanErrorCount) | $($postScanMetrics.registryElapsed) |

$scanDiagnosticMarkdown
$systemIntegrityMarkdown
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

$mdDirectoriesHeader = @"

## Manifiesto de Directorios Nuevos o con Metadatos Modificados

<details>
<summary><b>Clic aqui para expandir lista ($directoryCount directorios)</b></summary>
<pre><code>
"@

$mdDirectoriesFooter = @"
</code></pre>
</details>
"@

$mdFailuresHeader = @"

## Problemas de Integridad o Staging

<details>
<summary><b>Clic aqui para expandir lista ($($copyFailures.Count) problema(s))</b></summary>
<pre><code>
"@

$mdDeletedHeader = @"

## Archivos y Carpetas Eliminados Durante la Captura

Estos elementos existian en el snapshot inicial y ya no estaban presentes en el snapshot final.
Un WIM es un contenedor aditivo y no puede representar una eliminacion. DeltaPack los escribe en
``Deletions_$($script:DeltaPackPackageFullName).json`` para que un inyector compatible los aplique de forma explicita.

<details>
<summary><b>Clic aqui para expandir lista ($($deletedListForReport.Count) elemento(s))</b></summary>
<pre><code>
"@

$mdDeletedFooter = @"
</code></pre>
</details>
"@

$mdRegistryAuditHeader = @"

## Eliminaciones de Registro Conservadas Solo para Auditoria

Estas ramas desaparecieron durante la ventana de captura, pero una regla declarativa las protege o
no se encontro evidencia suficiente que correlacione su eliminacion con la aplicacion. Para evitar
borrar publicadores de eventos, componentes COM u otros registros del sistema al importar el REG
en una imagen offline, no se exportaron como operaciones destructivas. Las altas y modificaciones
legitimas permanecen habilitadas.

<details>
<summary><b>Clic aqui para expandir lista ($($auditOnlyRegistryKeyDeletions.Count) clave(s))</b></summary>
<pre><code>
"@

$mdRegistryAuditFooter = @"
</code></pre>
</details>
"@

$mdRegistryMutationAuditHeader = @"

## Mutaciones COM y TaskCache Conservadas Solo para Auditoria

Estas mutaciones no alcanzaron la correlacion minima necesaria para atribuirlas al instalador.
No se exportaron al REG que consumira AdminImagenOffline.

<details>
<summary><b>Clic aqui para expandir lista ($($auditOnlyRegistryMutations.Count) mutacion(es))</b></summary>
<pre><code>
"@

$dryRunNotaTecnica   = if ($isDryRun) { "`n* **Modo Dry Run:** no se genero el archivo `` .wim `` ni se copio ningun archivo a disco. Vuelve a ejecutar en modo Captura Completa para generar el paquete final." } else { "" }
$checksumNotaTecnica = if ($checksumsFile) { "`n* Verifica la integridad de los archivos extraidos comparando contra `` $(Split-Path $checksumsFile -Leaf) `` (formato `` hash  ruta ``, compatible con herramientas tipo sha256sum)." } else { "" }
$artifactChecksumNotaTecnica = if ($manifestFile -and $structuredArtifactGenerationComplete) { "`n* Los artefactos de auditoria y despliegue se verifican por separado mediante ``Artifacts_$($script:DeltaPackPackageFullName).sha256``; este indice tambien se genera en Dry Run." } elseif ($manifestFile) { "`n* El indice de artefactos no se publica cuando un JSON obligatorio no supera la validacion transaccional." } else { "" }
$manifestNotaTecnica = if ($manifestFile)  { "`n* Metricas de la captura en formato maquina-legible: ``$(Split-Path $manifestFile -Leaf)`` (JSON, schemaVersion 6)." } else { "" }
$actionsNotaTecnica = if ($actionsFile) { "`n* Acciones y validaciones offline: ``$(Split-Path $actionsFile -Leaf)``. Orden: WIM, acciones previas al REG, tombstones, REG y validaciones posteriores." } else { "" }

$mdNotasTecnicas = @"

## Notas Tecnicas
* El paquete incluye redireccion automatica de ``%USERPROFILE%`` a ``Users\Default``.
* Los archivos redirigidos al perfil Default reciben una ACL de plantilla sin el SID del usuario capturador.
* Inyectar el archivo ``.reg`` **despues** de desplegar el ``.wim`` y ejecutar las acciones ``afterWimBeforeRegistry`` cuando exista ``Actions_*.json``.
* La captura WIM se supervisa en un proceso de trabajo. Como WIMGAPI no entrega un porcentaje continuo fiable, DeltaPack muestra tiempo transcurrido, bytes escritos y un latido de consola cada minuto.
* El escaneo de archivos usa: $($manifestObj.scan.hashThresholdLabel); paralelismo efectivo: $effectiveParallelism.
* En modo SafeUSN, el snapshot inicial conserva SHA256 completo. El final reutiliza ese hash solo cuando volumen, diario, ID de archivo y USN siguen estables; cualquier falta de soporte o cambio de diario activa SHA256 completo automaticamente.
* Diagnostico automatico del escaneo: $($scanDiagnostic.status) ($($scanDiagnostic.warnCount) advertencia(s), $($scanDiagnostic.infoCount) observacion(es)).
* Los directorios nuevos, incluidos los vacios, conservan ACL, propietario, grupo, atributos y timestamps cuando Windows permite leerlos.
* El WIM conserva DACL, propietario y grupo. El inyector offline debe desplegarlos con semantica equivalente a ``robocopy /COPY:DATSO /DCOPY:DAT /SECFIX``; una copia limitada a ``/COPY:DAT`` descarta esa seguridad.
* ``HKCR`` no se captura como vista combinada; las clases globales y por usuario proceden de ``HKLM\SOFTWARE\Classes`` y ``HKCU\Software\Classes`` respectivamente.
* El estado post-reinicio de ``AppReadiness``, ``Mrt\_Merged`` y ``Explorer\Package Installation`` se excluye por subarbol: contiene SID, contadores y rutas de cache propios del host de captura y nunca debe importarse en otra imagen.
* Las eliminaciones completas de CLSID directos sin correlacion y las ramas protegidas por ``registryDeletionAuditRules`` se conservan en el reporte, manifest y ``Deletions_*.json``, pero no se escriben en el ``.reg`` destructivo. Las altas y modificaciones legitimas de esas ramas siguen siendo capturables.
* Las ramas indice de ``TaskCache`` requieren correlacion con ``Tasks``, ``Tree`` y el archivo fisico de la tarea. Las mutaciones ``AppID`` aisladas en CLSID tambien se conservan solo para auditoria.
* Las mutaciones en catalogos, controladores de seguridad, ``mstask.dll``, PBR o binarios de nucleo se comparan por SHA256. Los catalogos correlacionados por tokens del producto o DriverStore se conservan en ``Actions_*.json``; cambios protegidos no correlacionados siguen bloqueando el WIM.
* ``EdgeWebView\Application\SetupMetrics`` se excluye simetricamente como telemetria de instalacion. Una migracion masiva en arboles versionados de Edge, EdgeCore o WebView2 se conserva como evidencia y bloquea Staging, VSS y WIM para evitar mezclar runtimes ajenos al instalador.
* Si la captura no es completa, el WIM se bloquea y el detalle queda en este reporte y en el manifest JSON.
* Los reparse points cambiados se leen mediante ``FSCTL_GET_REPARSE_POINT`` y se recrean con ``FSCTL_SET_REPARSE_POINT``. Un descriptor ilegible o que cambie despues del snapshot bloquea el WIM.
* Las ramas ``Class\{GUID}\Properties`` inaccesibles de forma identica antes/despues se documentan como brecha estable. Errores asimetricos o fuera de esa forma siguen siendo bloqueantes.
* OneDrive incorporado incidentalmente se excluye por defecto para evitar mezclar cuenta, tarea y binarios. Usa ``includeBundledOneDrive=true`` solo si forma parte intencional del paquete.
* Si el REG conserva el nombre del equipo, ruta del perfil o SID capturador, Staging queda bloqueado. Los nombres de valor basados en una ruta absoluta no admiten variables y obligan a conservar la misma letra de sistema.
* Si existen eliminaciones aplicables, el paquete solo se considera listo cuando el inyector soporta ``Deletions_*.json`` o ``allowAuditOnlyDeletions`` fue habilitado explicitamente. La evidencia ``filesystemAuditOnly`` y ``registryAuditOnly`` se conserva para diagnostico y no exige soporte destructivo del inyector.
* Generado con DeltaPack Dual-Engine v$($script:Version) - PS $($PSVersionTable.PSVersion)$dryRunNotaTecnica$checksumNotaTecnica$artifactChecksumNotaTecnica$manifestNotaTecnica$actionsNotaTecnica
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

    if ($directoryListForReport.Count -gt 0) {
        $writer.WriteLine($mdDirectoriesHeader)
        foreach ($dirItem in $directoryListForReport) { $writer.WriteLine($dirItem) }
        $writer.WriteLine($mdDirectoriesFooter)
    } else {
        $writer.WriteLine(([Environment]::NewLine + "## Manifiesto de Directorios Nuevos o con Metadatos Modificados" + [Environment]::NewLine + [Environment]::NewLine + "No se detectaron directorios nuevos ni cambios de metadatos en directorios existentes."))
    }

    if ($copyFailures.Count -gt 0) {
        $writer.WriteLine($mdFailuresHeader)
        foreach ($failure in $copyFailures) { $writer.WriteLine($failure) }
        $writer.WriteLine($mdDirectoriesFooter)
    } else {
        $writer.WriteLine(([Environment]::NewLine + "## Problemas de Integridad o Staging" + [Environment]::NewLine + [Environment]::NewLine + "No se detectaron problemas de copia ni de metadatos. La integridad del sistema base se informa en su seccion independiente."))
    }

    if ($deletedListForReport.Count -gt 0) {
        $writer.WriteLine($mdDeletedHeader)
        foreach ($d in $deletedListForReport) {
            $writer.WriteLine($d)
        }
        $writer.WriteLine($mdDeletedFooter)
    } else {
        $writer.WriteLine(([Environment]::NewLine + "## Archivos y Carpetas Eliminados Durante la Captura" + [Environment]::NewLine + [Environment]::NewLine + "No se detectaron eliminaciones durante la captura."))
    }

    if ($auditOnlyRegistryKeyDeletions.Count -gt 0) {
        $writer.WriteLine($mdRegistryAuditHeader)
        foreach ($auditKey in $auditOnlyRegistryKeyDeletions) { $writer.WriteLine($auditKey) }
        $writer.WriteLine($mdRegistryAuditFooter)
    } else {
        $writer.WriteLine(([Environment]::NewLine + "## Eliminaciones de Registro Conservadas Solo para Auditoria" + [Environment]::NewLine + [Environment]::NewLine + "No se detectaron eliminaciones protegidas o no correlacionadas."))
    }

    if ($auditOnlyRegistryMutations.Count -gt 0) {
        $writer.WriteLine($mdRegistryMutationAuditHeader)
        foreach ($auditMutation in $auditOnlyRegistryMutations) { $writer.WriteLine($auditMutation) }
        $writer.WriteLine($mdRegistryAuditFooter)
    } else {
        $writer.WriteLine(([Environment]::NewLine + "## Mutaciones COM y TaskCache Conservadas Solo para Auditoria" + [Environment]::NewLine + [Environment]::NewLine + "No se detectaron mutaciones COM/TaskCache sin correlacion suficiente."))
    }

    $writer.WriteLine($mdNotasTecnicas)

} finally {
    if ($null -ne $writer) { $writer.Dispose() }
}

# Checksums de artefactos consumidos por el inyector. El manifest se actualiza
# primero con el nombre del indice y despues se incluye en la verificacion.
$artifactChecksumsFile = $null
$artifactIntegrityComplete = $false
$artifactCandidate = $null
$artifactLines = New-Object System.Collections.Generic.List[string]
if ($null -ne $manifestFile -and (Test-Path -LiteralPath $manifestFile)) {
    try {
        if (-not $structuredArtifactGenerationComplete) {
            throw 'No se publican checksums porque faltan uno o mas artefactos JSON obligatorios.'
        }
        $artifactCandidate = Join-Path $outDir "Artifacts_$($script:DeltaPackPackageFullName).sha256"
        $manifestObj.outputs.artifactChecksumsFile = Split-Path $artifactCandidate -Leaf
        $manifestObj.flags.artifactIntegrityComplete = $true
        Write-ValidatedJsonFile -InputObject $manifestObj -Path $manifestFile -Depth 8 -ExpectedSchemaVersion 6 `
            -RequiredProperties @('schemaVersion', 'engineIdentity', 'package', 'scan', 'staging', 'deletions', 'deployment', 'outputs', 'flags')

        Assert-DeltaPackPackageArtifactSet -OutputDirectory $outDir -ManifestPath $manifestFile `
            -WimPath $wimOutputFile -RegPath $regOutputFile -ChecksumsPath $checksumsFile `
            -DeletionsPath $deletionsFile -ActionsPath $actionsFile -ReadmePath $reportFile `
            -ArtifactChecksumsPath $artifactCandidate

        foreach ($artifact in @($wimOutputFile, $regOutputFile, $deletionsFile, $actionsFile, $reportFile, $checksumsFile, $manifestFile)) {
            if ($artifact -and (Test-Path -LiteralPath $artifact)) {
                $artifactHash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                $artifactLeaf = Split-Path $artifact -Leaf
                $artifactLines.Add(("{0}  {1}" -f $artifactHash, $artifactLeaf))
            }
        }
        if ($artifactLines.Count -eq 0) { throw "No hay artefactos verificables." }

        $artifactChecksumEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($artifactCandidate, [string[]]$artifactLines, $artifactChecksumEncoding)
        Assert-DeltaPackArtifactChecksumIndex -IndexPath $artifactCandidate -OutputDirectory $outDir
        $artifactChecksumsFile = $artifactCandidate
        $artifactIntegrityComplete = $true
        Write-Log "Checksums de artefactos generados: $(Split-Path $artifactChecksumsFile -Leaf)" -Level SUCCESS
    } catch {
        Write-Log "ADVERTENCIA: No se pudo generar el checksum de artefactos: $($_.Exception.Message)" -Level WARN
        $packageReady = $false
        $manifestObj.flags.packageReady = $false
        if ($artifactCandidate -and (Test-Path -LiteralPath $artifactCandidate)) {
            Remove-Item -LiteralPath $artifactCandidate -Force -ErrorAction SilentlyContinue
        }
        $manifestObj.outputs.artifactChecksumsFile = $null
        $manifestObj.flags.artifactIntegrityComplete = $false
        try {
            Write-ValidatedJsonFile -InputObject $manifestObj -Path $manifestFile -Depth 8 -ExpectedSchemaVersion 6 `
                -RequiredProperties @('schemaVersion', 'engineIdentity', 'package', 'scan', 'staging', 'deletions', 'deployment', 'outputs', 'flags')
        } catch { }
        $artifactChecksumsFile = $null
        $artifactIntegrityComplete = $false
    }
}

# =================================================================
#  LIMPIEZA Y FINALIZACION
# =================================================================
$preserveWorkspaceForRetry = ((-not $isDryRun) -and ((-not $captureComplete) -or ($hasFilePayload -and -not $hasWimOutput)))
if ($preserveWorkspaceForRetry) {
    Write-Log "Workspace protegido conservado para reintentar la fase final sin reinstalar la aplicacion: $workspaceDir" -Level WARN
} elseif (Test-Path -LiteralPath $workspaceDir) {
    Write-Log "Limpiando workspace protegido..." -Level INFO
    Remove-Item -LiteralPath $workspaceDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n=======================================================" -ForegroundColor Cyan
if ($packageReady) {
    Write-Log "PROCESO FINALIZADO" -Level SUCCESS
} elseif (-not $structuredArtifactGenerationComplete) {
    Write-Log "PROCESO FINALIZADO CON ERRORES DE ARTEFACTOS: uno o mas JSON obligatorios no se publicaron de forma valida." -Level ERROR
} elseif (-not $artifactIntegrityComplete) {
    Write-Log "PROCESO FINALIZADO CON ERROR DE INTEGRIDAD: no se pudo publicar el indice SHA256 de artefactos." -Level ERROR
} elseif ($isDryRun -and $captureComplete) {
    Write-Log "DRY RUN COMPLETADO: analisis integro; no se genero WIM ni paquete desplegable." -Level SUCCESS
} elseif ($captureComplete -and $hasWimOutput) {
    Write-Log "PROCESO FINALIZADO CON REQUISITOS PENDIENTES DEL INYECTOR: revisa Actions/Deletions y packageReady." -Level WARN
} else {
    Write-Log "PROCESO FINALIZADO CON ERRORES: paquete no listo para inyeccion" -Level ERROR
}
Write-Host "Carpeta de Salida: $outDir" -ForegroundColor Gray
Write-Host "Identidad SHA256: $($script:DeltaPackPackageIdentitySha256)" -ForegroundColor DarkGray

$regName = Split-Path $regOutputFile -Leaf
$mdName  = Split-Path $reportFile   -Leaf

if (Test-Path $regOutputFile) { Write-Host "  [OK] $regName" -ForegroundColor White }

if ($null -ne $checksumsFile -and (Test-Path $checksumsFile)) {
    Write-Host "  [OK] $(Split-Path $checksumsFile -Leaf)" -ForegroundColor White
}
if ($null -ne $deletionsFile -and (Test-Path $deletionsFile)) {
    Write-Host "  [OK] $(Split-Path $deletionsFile -Leaf)" -ForegroundColor Yellow
}
if ($null -ne $actionsFile -and (Test-Path $actionsFile)) {
    Write-Host "  [OK] $(Split-Path $actionsFile -Leaf)" -ForegroundColor Yellow
}
if ($null -ne $artifactChecksumsFile -and (Test-Path $artifactChecksumsFile)) {
    Write-Host "  [OK] $(Split-Path $artifactChecksumsFile -Leaf)" -ForegroundColor White
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
Write-Host ("Resumen candidatos: Registro {0:N0} entrada(s) | Archivos {1:N0} | Directorios {2:N0} | Tamaño {3}" -f `
    $regMetrics.TotalEntries, $candidateFileCount, $candidateDirectoryCount, $candidateSizeDisplay) -ForegroundColor Cyan
if ($stagingApplicable) {
    Write-Host ("Staging: archivos {0:N0}/{1:N0} | directorios {2:N0}/{3:N0} | reparse {4:N0}/{5:N0} | incidencias {6:N0} | estado {7}" -f `
        $stagedFileCountForReport, $candidateFileCount, $stagedDirectoryCountForReport, $candidateDirectoryCount, `
        $reparsePointsStaged, $reparseChangesForStaging.Count, $copyFailures.Count, $stagingStatus) -ForegroundColor $(if ($stagingComplete) { 'Cyan' } else { 'Yellow' })
} else {
    Write-Host "Staging: no aplica en Dry Run." -ForegroundColor Cyan
}
Write-Host ("Diagnostico escaneo: {0} ({1:N0} advertencia(s), {2:N0} observacion(es))" -f $scanDiagnostic.status, $scanDiagnostic.warnCount, $scanDiagnostic.infoCount) -ForegroundColor Cyan
$finalPackageStatus = if ($packageReady) {
    "LISTO PARA INYECCION"
} elseif (-not $structuredArtifactGenerationComplete) {
    "NO LISTO - ARTEFACTOS JSON INVALIDOS O AUSENTES"
} elseif (-not $artifactIntegrityComplete) {
    "NO LISTO - INDICE SHA256 DE ARTEFACTOS AUSENTE"
} elseif ($isDryRun -and $captureComplete) {
    "VISTA PREVIA COMPLETADA - WIM NO GENERADO"
} elseif ($captureComplete -and $hasWimOutput) {
    "NO LISTO - REQUISITOS DEL INYECTOR PENDIENTES"
} else {
    "NO LISTO - REVISAR ERRORES DEL REPORTE"
}
$finalPackageStatusColor = if ($packageReady) {
    "Green"
} elseif (-not $structuredArtifactGenerationComplete) {
    "Red"
} elseif (-not $artifactIntegrityComplete) {
    "Red"
} elseif ($captureComplete) {
    "Yellow"
} else {
    "Red"
}
Write-Host ("Estado del paquete: {0}" -f $finalPackageStatus) -ForegroundColor $finalPackageStatusColor
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""
if ($null -ne $script:InstanceMutex) {
    try { $script:InstanceMutex.ReleaseMutex() } catch { }
    $script:InstanceMutex.Dispose()
    $script:InstanceMutex = $null
}
Pause
