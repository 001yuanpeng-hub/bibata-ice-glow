[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [ValidateSet("Modern", "Original")]
    [string]$Style = "Modern",
    [ValidateSet("Regular", "Large", "Extra-Large")]
    [string]$Size = "Regular",
    [ValidateSet("", "Ice", "Cyan", "Frost", "PinkBlue", "Rainbow")]
    [string]$Palette = "",
    [switch]$SingleSize,
    [switch]$SkipCursor,
    [switch]$SkipTrail,
    [switch]$NoAutoStart,
    [switch]$NoLaunch,
    [string]$RegistryRoot = "HKCU:",
    [switch]$SkipCursorRefresh,
    [switch]$SkipTaskScheduler,
    [string]$TestSourceOverride = "",
    [string]$LaunchArgs = "",
    [string]$TestCursorZipPath = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "src\InstallState.ps1")

function Normalize-BibataPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    $clean = $p.Trim().Trim('"')
    try {
        return [System.IO.Path]::GetFullPath($clean).TrimEnd('\').ToLowerInvariant()
    }
    catch {
        return $clean.TrimEnd('\').ToLowerInvariant()
    }
}

function Add-UniquePath($list, [string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return }
    $normP = Normalize-BibataPath $p
    foreach ($existing in $list) {
        if ((Normalize-BibataPath $existing) -eq $normP) { return }
    }
    $list.Add([string]$p)
}

function Remove-PathFromList($list, [string]$targetPath) {
    if ($null -eq $list -or [string]::IsNullOrWhiteSpace($targetPath)) { return }
    $normTarget = Normalize-BibataPath $targetPath
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
        if ((Normalize-BibataPath ([string]$list[$i])) -eq $normTarget) {
            $list.RemoveAt($i)
        }
    }
}

function Resolve-BibataAbsolutePath([string]$rawPath) {
    if ([string]::IsNullOrWhiteSpace($rawPath)) { return "" }
    $trimmed = $rawPath.Trim().Trim('"')
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($trimmed)
    $full = [System.IO.Path]::GetFullPath($resolved)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Test-CursorSizeComplete([string]$dirPath, $roleMap) {
    if ([string]::IsNullOrWhiteSpace($dirPath) -or -not (Test-Path -LiteralPath $dirPath -PathType Container)) {
        return $false
    }
    foreach ($role in $roleMap.Keys) {
        $rf = Join-Path $dirPath $roleMap[$role]
        if (-not (Test-Path -LiteralPath $rf -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Get-FileSha256([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "" }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

function Write-FileFreshInode([string]$srcFile, [string]$dstFile) {
    $dir = Split-Path -Parent $dstFile
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmpFile = "$dstFile.swap." + [Guid]::NewGuid().ToString("N").Substring(0, 8) + ".tmp"
    try {
        [System.IO.File]::Copy($srcFile, $tmpFile, $true)
        if (Test-Path -LiteralPath $dstFile -PathType Leaf) {
            Remove-Item -LiteralPath $dstFile -Force -ErrorAction Stop
        }
        [System.IO.File]::Move($tmpFile, $dstFile)
    }
    catch {
        if (Test-Path -LiteralPath $tmpFile -PathType Leaf) {
            Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Restore-FileBackup([string]$backupPath, [string]$targetPath) {
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        return $false
    }
    $bakHash = Get-FileSha256 $backupPath
    try {
        [System.IO.File]::Copy($backupPath, $targetPath, $true)
        $dstHash = Get-FileSha256 $targetPath
        if ($dstHash -eq $bakHash) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
            return $true
        }
        Write-Warning "Restored file hash mismatch for $targetPath; keeping backup at $backupPath"
        return $false
    }
    catch {
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            try {
                $dstHash = Get-FileSha256 $targetPath
                if ($dstHash -eq $bakHash) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                    return $true
                }
            }
            catch {
            }
        }
        Write-Warning "Could not restore backup for ${targetPath}: $($_.Exception.Message); keeping backup at $backupPath"
        return $false
    }
}

function Refresh-WindowsCursors {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BibataCursorApi {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
}
"@ -ErrorAction SilentlyContinue | Out-Null
    $ok = [BibataCursorApi]::SystemParametersInfo(0x0057, 0, [IntPtr]::Zero, 0x02)
    if (-not $ok) {
        Write-Warning "SystemParametersInfo(SPI_SETCURSORS) returned False; please re-apply scheme in main.cpl if needed."
    }
}

function Get-BibataProcessesByExe([string]$targetExe) {
    $normTarget = Normalize-BibataPath $targetExe
    $matches = New-Object System.Collections.Generic.List[object]
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'BibataIceTrail.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ((Normalize-BibataPath $p.ExecutablePath) -eq $normTarget) {
                $matches.Add([pscustomobject]@{ Id = [int]$p.ProcessId; Path = $p.ExecutablePath })
            }
        }
    }
    catch {
        $gp = Get-Process -Name "BibataIceTrail" -ErrorAction SilentlyContinue
        foreach ($p in $gp) {
            try {
                if ((Normalize-BibataPath $p.MainModule.FileName) -eq $normTarget) {
                    $matches.Add([pscustomobject]@{ Id = [int]$p.Id; Path = $p.MainModule.FileName })
                }
            }
            catch {
            }
        }
    }
    return $matches
}

function Snapshot-RegValue([string]$keyPath, [string]$valueName) {
    $snap = [ordered]@{
        keyExisted = $false
        valExisted = $false
        value      = $null
        kind       = "String"
    }
    if (-not (Test-Path $keyPath)) {
        return $snap
    }
    $snap.keyExisted = $true
    $item = Get-Item -Path $keyPath -ErrorAction SilentlyContinue
    if ($item) {
        $valNames = @($item.GetValueNames())
        if ($valNames -contains $valueName) {
            $snap.valExisted = $true
            $snap.value = $item.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            try {
                $snap.kind = $item.GetValueKind($valueName).ToString()
            }
            catch {
                $snap.kind = "String"
            }
        }
    }
    return $snap
}

function Restore-RegValue([string]$keyPath, [string]$valueName, $snap) {
    if (-not $snap) { return }
    if ($snap.valExisted) {
        if (-not (Test-Path $keyPath)) {
            New-Item -Path $keyPath -Force | Out-Null
        }
        Set-ItemProperty -Path $keyPath -Name $valueName -Value $snap.value -Type ([string]$snap.kind)
    }
    else {
        if (Test-Path $keyPath) {
            Remove-ItemProperty -Path $keyPath -Name $valueName -ErrorAction SilentlyContinue
        }
    }
}

function Snapshot-CursorState([string]$cursorsPath) {
    $roles = @(
        "Arrow", "Help", "AppStarting", "Wait", "Crosshair", "IBeam",
        "NWPen", "No", "SizeNS", "SizeWE", "SizeNWSE", "SizeNESW",
        "SizeAll", "UpArrow", "Hand", "Pin", "Person"
    )
    $state = [ordered]@{
        existed       = $false
        defaultScheme = $null
        schemeSource  = $null
        roles         = [ordered]@{}
    }
    if (-not (Test-Path $cursorsPath)) {
        return $state
    }
    $state.existed = $true
    $item = Get-Item -Path $cursorsPath -ErrorAction SilentlyContinue
    if ($item) {
        $state.defaultScheme = $item.GetValue("", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $ss = $item.GetValue("Scheme Source", $null)
        if ($null -ne $ss) {
            $state.schemeSource = [int]$ss
        }
        foreach ($r in $roles) {
            $val = $item.GetValue($r, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -ne $val) {
                $state.roles[$r] = [string]$val
            }
            else {
                $state.roles[$r] = $null
            }
        }
    }
    return $state
}

function Restore-CursorState([string]$cursorsPath, $prevState) {
    if (-not $prevState -or -not $prevState.existed) {
        if (Test-Path $cursorsPath) {
            $k = Get-Item -Path $cursorsPath -ErrorAction SilentlyContinue
            if ($k -and $k.SubKeyCount -eq 0) {
                Remove-Item -Path $cursorsPath -Force -ErrorAction SilentlyContinue
            }
        }
        return
    }
    if (-not (Test-Path $cursorsPath)) {
        New-Item -Path $cursorsPath -Force | Out-Null
    }
    if ($null -ne $prevState.defaultScheme) {
        Set-ItemProperty -Path $cursorsPath -Name "(Default)" -Value ([string]$prevState.defaultScheme) -Type String
    }
    else {
        Remove-ItemProperty -Path $cursorsPath -Name "(Default)" -ErrorAction SilentlyContinue
    }
    if ($null -ne $prevState.schemeSource) {
        Set-ItemProperty -Path $cursorsPath -Name "Scheme Source" -Value ([int]$prevState.schemeSource) -Type DWord
    }
    else {
        Remove-ItemProperty -Path $cursorsPath -Name "Scheme Source" -ErrorAction SilentlyContinue
    }
    if ($prevState.roles) {
        $pairs = New-Object System.Collections.Generic.List[object]
        if ($prevState.roles -is [System.Collections.IDictionary]) {
            foreach ($roleName in $prevState.roles.Keys) {
                $pairs.Add([pscustomobject]@{ Name = [string]$roleName; Value = $prevState.roles[$roleName] })
            }
        }
        else {
            foreach ($prop in $prevState.roles.PSObject.Properties) {
                $pairs.Add([pscustomobject]@{ Name = [string]$prop.Name; Value = $prop.Value })
            }
        }
        foreach ($pair in $pairs) {
            if ($null -eq $pair.Value) {
                Remove-ItemProperty -Path $cursorsPath -Name $pair.Name -ErrorAction SilentlyContinue
            }
            else {
                $valStr = [string]$pair.Value
                $regType = if ($valStr -like "*%*") { "ExpandString" } else { "String" }
                Set-ItemProperty -Path $cursorsPath -Name $pair.Name -Value $valStr -Type $regType
            }
        }
    }
}

function Resolve-InheritedCursorState($currentState, [string]$currentInstallDir) {
    $state = $currentState
    if (-not $state -or -not $state.existed) { return $state }
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $curNorm = Normalize-BibataPath $currentInstallDir
    if (-not [string]::IsNullOrEmpty($curNorm)) {
        $visited.Add($curNorm) | Out-Null
    }

    for ($hop = 0; $hop -lt 5; $hop++) {
        $arrowVal = $null
        if ($state.roles) {
            if ($state.roles -is [System.Collections.IDictionary]) {
                if ($state.roles.Contains("Arrow")) { $arrowVal = $state.roles["Arrow"] }
            }
            elseif ($state.roles.PSObject.Properties["Arrow"]) {
                $arrowVal = $state.roles.Arrow
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$arrowVal)) { break }
        $arrowStr = [string]$arrowVal
        if ($arrowStr -notmatch '^(?i)(.+)\\Bibata-(?:Modern|Original)-Ice\\Bibata-(?:Modern|Original)-Ice-(?:Regular|Large|Extra-Large)-Windows\\[^\\]+$') {
            break
        }
        $otherInstallDir = $Matches[1]
        $otherNorm = Normalize-BibataPath $otherInstallDir
        if ([string]::IsNullOrEmpty($otherNorm) -or $visited.Contains($otherNorm)) { break }
        $visited.Add($otherNorm) | Out-Null

        $otherManifestPath = Join-Path $otherInstallDir "bibata-ice-glow-manifest.json"
        if (-not (Test-Path -LiteralPath $otherManifestPath -PathType Leaf)) { break }
        try {
            $otherManifest = Get-Content -LiteralPath $otherManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($otherManifest -and $otherManifest.managedCursor -and $otherManifest.previousCursorState -and $otherManifest.previousCursorState.existed) {
                $state = $otherManifest.previousCursorState
                continue
            }
        }
        catch {
        }
        break
    }
    return $state
}

function Test-SchemeValueValid([string]$schemeVal) {
    if ($null -eq $schemeVal) { return $false }
    if ([string]::IsNullOrWhiteSpace($schemeVal)) { return $true }
    $parts = $schemeVal -split ','
    foreach ($part in $parts) {
        $trimmed = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($trimmed)
        if (-not (Test-Path -LiteralPath $expanded -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Test-AllSchemePathsUnderDir([string]$schemeVal, [string]$dirRoot) {
    if ([string]::IsNullOrWhiteSpace($schemeVal) -or [string]::IsNullOrWhiteSpace($dirRoot)) { return $false }
    $normRoot = Normalize-BibataPath $dirRoot
    if ([string]::IsNullOrEmpty($normRoot)) { return $false }
    $prefix = $normRoot + "\"
    $nonEmptyCount = 0
    foreach ($part in ($schemeVal -split ',')) {
        $trimmed = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $nonEmptyCount++
        $normPart = Normalize-BibataPath ([Environment]::ExpandEnvironmentVariables($trimmed))
        if (-not ($normPart -eq $normRoot -or $normPart.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
            return $false
        }
    }
    return ($nonEmptyCount -gt 0)
}

function Get-RetainedSchemeFiles([string]$schemesPath, $schemeRecords, $previousState, $roleMap) {
    $values = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $schemesPath) {
        $schemes = Get-Item -LiteralPath $schemesPath
        foreach ($name in $schemes.GetValueNames()) {
            if ($name) {
                $raw = $schemes.GetValue($name, "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $values.Add([string]$raw)
            }
        }
    }
    # A later uninstall may restore these values even when their schemes are inactive.
    foreach ($record in $schemeRecords.Values) {
        if ($record.existedBefore) { $values.Add([string]$record.previousValue) }
    }
    foreach ($role in $roleMap.Keys) {
        $values.Add([string]$previousState.roles.$role)
    }

    $files = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $values) {
        foreach ($part in ($value -split ',')) {
            $path = [Environment]::ExpandEnvironmentVariables($part.Trim().Trim('"'))
            if ($path) { [void]$files.Add((Normalize-BibataPath $path)) }
        }
    }
    return ,$files
}

function Import-RuntimeSchemeRecords([string]$installRoot, $targetMap) {
    if ([string]::IsNullOrWhiteSpace($installRoot) -or $null -eq $targetMap) { return }
    $rtPath = Join-Path $installRoot "bibata-runtime-schemes.json"
    if (-not (Test-Path -LiteralPath $rtPath -PathType Leaf)) { return }
    try {
        $runtimeState = Read-BibataRuntimeSchemes $rtPath
        foreach ($item in $runtimeState.Records) {
            if (-not $item -or [string]::IsNullOrWhiteSpace([string]$item.name)) { continue }
            $sName = [string]$item.name
            if (-not $targetMap.Contains($sName)) {
                $targetMap[$sName] = [ordered]@{
                    existedBefore = [bool]$item.existedBefore
                    previousValue = $item.previousValue
                    previousKind  = if ([string]::IsNullOrWhiteSpace([string]$item.previousKind)) { "String" } else { [string]$item.previousKind }
                    writtenValue  = [string]$item.writtenValue
                }
            }
            else {
                $existingRec = $targetMap[$sName]
                $prevMatchesManifestWritten = ([bool]$item.existedBefore) -and
                    [string]::Equals([string]$item.previousValue, [string]$existingRec.writtenValue, [StringComparison]::OrdinalIgnoreCase)
                if (-not $prevMatchesManifestWritten) {
                    $existingRec.existedBefore = [bool]$item.existedBefore
                    $existingRec.previousValue = $item.previousValue
                    $existingRec.previousKind = if ([string]::IsNullOrWhiteSpace([string]$item.previousKind)) { "String" } else { [string]$item.previousKind }
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$item.writtenValue)) {
                    $existingRec.writtenValue = [string]$item.writtenValue
                }
            }
        }
    }
    catch {
    }
}

function Resolve-InheritedSchemeSnapshot([string]$schemeName, $currentSnap, [string]$currentInstallDir) {
    $snap = $currentSnap
    if (-not $snap -or -not $snap.valExisted -or [string]::IsNullOrWhiteSpace([string]$snap.value)) {
        return $snap
    }
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $curNorm = Normalize-BibataPath $currentInstallDir
    if (-not [string]::IsNullOrEmpty($curNorm)) {
        $visited.Add($curNorm) | Out-Null
    }

    for ($hop = 0; $hop -lt 5; $hop++) {
        $valStr = [string]$snap.value
        $firstPath = ($valStr -split ',')[0]
        if ([string]::IsNullOrWhiteSpace($firstPath)) { break }
        if ($firstPath -notmatch '^(?i)(.+)\\Bibata-(?:Modern|Original)-Ice\\Bibata-(?:Modern|Original)-Ice-(?:Regular|Large|Extra-Large)-Windows\\[^\\]+$') {
            break
        }
        $otherInstallDir = $Matches[1]
        $otherNorm = Normalize-BibataPath $otherInstallDir
        if ([string]::IsNullOrEmpty($otherNorm) -or $visited.Contains($otherNorm)) { break }
        $visited.Add($otherNorm) | Out-Null

        $otherRecs = New-Object 'System.Collections.Specialized.OrderedDictionary' ([StringComparer]::OrdinalIgnoreCase)
        $otherManifestPath = Join-Path $otherInstallDir "bibata-ice-glow-manifest.json"
        if (Test-Path -LiteralPath $otherManifestPath -PathType Leaf) {
            try {
                $om = Get-Content -LiteralPath $otherManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($om -and $om.managedSchemeRecords) {
                    foreach ($prop in $om.managedSchemeRecords.PSObject.Properties) {
                        $recObj = $prop.Value
                        if ($recObj) {
                            $otherRecs[$prop.Name] = [ordered]@{
                                existedBefore = [bool]$recObj.existedBefore
                                previousValue = $recObj.previousValue
                                previousKind  = if ([string]::IsNullOrWhiteSpace([string]$recObj.previousKind)) { "String" } else { [string]$recObj.previousKind }
                                writtenValue  = [string]$recObj.writtenValue
                            }
                        }
                    }
                }
            }
            catch {
            }
        }
        Import-RuntimeSchemeRecords $otherInstallDir $otherRecs

        if (-not $otherRecs.Contains($schemeName)) { break }
        $otherRec = $otherRecs[$schemeName]
        if (-not [string]::Equals($valStr, [string]$otherRec.writtenValue, [StringComparison]::OrdinalIgnoreCase)) {
            # User manually modified this scheme after the previous installation wrote it
            break
        }

        $snap = [ordered]@{
            keyExisted = $true
            valExisted = [bool]$otherRec.existedBefore
            value      = $otherRec.previousValue
            kind       = if ([string]::IsNullOrWhiteSpace([string]$otherRec.previousKind)) { "String" } else { [string]$otherRec.previousKind }
        }
        if (-not $snap.valExisted -or [string]::IsNullOrWhiteSpace([string]$snap.value)) {
            break
        }
    }
    return $snap
}

function Start-BibataInstance([string]$exePath, [string]$workDir, [string]$extraArgs, [switch]$NoTaskScheduler) {
    $argTokens = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($extraArgs)) {
        foreach ($tok in ($extraArgs -split '\s+')) {
            if (-not [string]::IsNullOrWhiteSpace($tok)) {
                $argTokens.Add($tok)
            }
        }
    }

    $launchedViaTask = $false
    if (-not $NoTaskScheduler) {
        try {
            $taskName = "BibataIceTrailOneShotLaunch"
            $taskArgs = if ($argTokens.Count -gt 0) { $argTokens -join " " } else { $null }
            if ($taskArgs) {
                $action = New-ScheduledTaskAction -Execute $exePath -Argument $taskArgs -WorkingDirectory $workDir
            }
            else {
                $action = New-ScheduledTaskAction -Execute $exePath -WorkingDirectory $workDir
            }
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            Start-Sleep -Milliseconds 800
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            $launchedViaTask = $true
        }
        catch {
            $launchedViaTask = $false
        }
    }

    if (-not $launchedViaTask) {
        if ($argTokens.Count -gt 0) {
            Start-Process -FilePath $exePath -ArgumentList $argTokens.ToArray() -WorkingDirectory $workDir | Out-Null
        }
        else {
            Start-Process -FilePath $exePath -WorkingDirectory $workDir | Out-Null
        }
        Start-Sleep -Milliseconds 500
    }

    $alive = @(Get-BibataProcessesByExe $exePath)
    if ($alive.Count -eq 0) {
        throw "BibataIceTrail failed to stay running after launch: $exePath"
    }
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if (Test-Path "D:\Software") {
        $InstallDir = "D:\Software\Cursors"
    }
    else {
        $InstallDir = Join-Path $env:LOCALAPPDATA "BibataIceGlow"
    }
}
$InstallDir = Resolve-BibataAbsolutePath $InstallDir
if (-not [string]::IsNullOrWhiteSpace($TestCursorZipPath)) {
    $TestCursorZipPath = Resolve-BibataAbsolutePath $TestCursorZipPath
}
if (-not [string]::IsNullOrWhiteSpace($TestSourceOverride)) {
    $TestSourceOverride = Resolve-BibataAbsolutePath $TestSourceOverride
}

Write-Host "Install directory: $InstallDir" -ForegroundColor Cyan

$manifestPath = Join-Path $InstallDir "bibata-ice-glow-manifest.json"
$prevManifest = Read-BibataManifest $manifestPath
$userConfigBackup = $prevManifest.userConfigBackup

$managedCursor = $false
$managedTrail = $false
$managedTrailFiles = New-Object System.Collections.Generic.List[string]
$managedThemeDirs = New-Object System.Collections.Generic.List[string]
$managedCursorDirs = New-Object System.Collections.Generic.List[string]
$managedCursorFiles = New-Object System.Collections.Generic.List[string]
$managedSchemes = New-Object System.Collections.Generic.List[string]
$managedSchemeRecords = New-Object 'System.Collections.Specialized.OrderedDictionary' ([StringComparer]::OrdinalIgnoreCase)
$previousCursorState = $null
$prevTrailExePath = Join-Path (Join-Path $InstallDir "Bibata-Ice-Trail") "BibataIceTrail.exe"
$autoStartManaged = $false

if ($prevManifest) {
    if ($prevManifest.managedCursor) { $managedCursor = $true }
    if ($prevManifest.managedTrail) { $managedTrail = $true }
    if ($prevManifest.autoStartManaged) { $autoStartManaged = $true }
    if (-not [string]::IsNullOrWhiteSpace($prevManifest.trailExePath)) { $prevTrailExePath = [string]$prevManifest.trailExePath }
    if ($prevManifest.managedTrailFiles) {
        foreach ($tf in $prevManifest.managedTrailFiles) { Add-UniquePath $managedTrailFiles ([string]$tf) }
    }
    elseif ($prevManifest.managedTrail -and -not $prevManifest.PSObject.Properties['managedTrailFiles']) {
        Add-UniquePath $managedTrailFiles $prevTrailExePath
        Add-UniquePath $managedTrailFiles (Join-Path $InstallDir 'Bibata-Ice-Trail\BibataIceTrail.cs')
    }
    if ($prevManifest.schemaVersion -lt 3) {
        # Earlier installers listed even pre-existing configs as their own.
        Remove-PathFromList $managedTrailFiles (Join-Path $InstallDir 'Bibata-Ice-Trail\config.ini')
    }
    if ($prevManifest.managedThemeDirs) {
        foreach ($d in $prevManifest.managedThemeDirs) { Add-UniquePath $managedThemeDirs ([string]$d) }
    }
    if ($prevManifest.managedCursorDirs) {
        foreach ($d in $prevManifest.managedCursorDirs) { Add-UniquePath $managedCursorDirs ([string]$d) }
    }
    if ($prevManifest.managedCursorFiles) {
        foreach ($f in $prevManifest.managedCursorFiles) { Add-UniquePath $managedCursorFiles ([string]$f) }
    }
    if ($prevManifest.managedSchemes) {
        foreach ($s in $prevManifest.managedSchemes) {
            if (-not [string]::IsNullOrWhiteSpace($s) -and -not ($managedSchemes -contains $s)) {
                $managedSchemes.Add([string]$s)
            }
        }
    }
    if ($prevManifest.managedSchemeRecords) {
        foreach ($prop in $prevManifest.managedSchemeRecords.PSObject.Properties) {
            $recObj = $prop.Value
            if ($recObj) {
                $managedSchemeRecords[$prop.Name] = [ordered]@{
                    existedBefore = [bool]$recObj.existedBefore
                    previousValue = $recObj.previousValue
                    previousKind  = if ([string]::IsNullOrWhiteSpace([string]$recObj.previousKind)) { "String" } else { [string]$recObj.previousKind }
                    writtenValue  = [string]$recObj.writtenValue
                }
            }
        }
    }
    if ($prevManifest.previousCursorState) {
        $previousCursorState = $prevManifest.previousCursorState
    }
}
Import-RuntimeSchemeRecords $InstallDir $managedSchemeRecords

$roleMap = [ordered]@{
    Arrow       = "Pointer.cur"
    Help        = "Help.cur"
    AppStarting = "Work.ani"
    Wait        = "Busy.ani"
    Crosshair   = "Cross.cur"
    IBeam       = "Text.cur"
    NWPen       = "Handwriting.cur"
    No          = "Unavailable.cur"
    SizeNS      = "Vert.cur"
    SizeWE      = "Horz.cur"
    SizeNWSE    = "Dgn1.cur"
    SizeNESW    = "Dgn2.cur"
    SizeAll     = "Move.cur"
    UpArrow     = "Alternate.cur"
    Hand        = "Link.cur"
    Pin         = "Pin.cur"
    Person      = "Person.cur"
}

$trailStageDir = ""
$stagedCs = ""
$stagedExe = ""
$cursorStageDir = ""
$cursorStageExtract = ""

try {
    # =========================================================================
    # PHASE A: Prepare & verify all candidates in temp staging (zero side effects)
    # =========================================================================

    if (-not $SkipTrail) {
        $repoRoot = $PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($repoRoot)) {
            $repoRoot = (Get-Location).Path
        }
        $srcCs = if (-not [string]::IsNullOrWhiteSpace($TestSourceOverride)) { $TestSourceOverride } else { Join-Path $repoRoot "src\BibataIceTrail.cs" }
        if (-not (Test-Path -LiteralPath $srcCs)) {
            throw "Source file not found: $srcCs. Please run install.ps1 from the cloned repository directory."
        }

        $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        $platform = "x64"
        if (-not (Test-Path $csc)) {
            $csc = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
            $platform = "anycpu"
        }
        if (-not (Test-Path $csc)) {
            throw ".NET Framework 4.x csc.exe not found on this system."
        }

        $trailStageDir = Join-Path $env:TEMP ("bibata_ice_stage_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $trailStageDir -Force | Out-Null

        $stagedCs = Join-Path $trailStageDir "BibataIceTrail.cs"
        $stagedExe = Join-Path $trailStageDir "BibataIceTrail.exe"
        $selfTestLog = Join-Path $trailStageDir "bibata_ice_trail_selftest.log"

        Copy-Item -LiteralPath $srcCs -Destination $stagedCs -Force

        Write-Host "Compiling candidate BibataIceTrail.exe in staging directory..." -ForegroundColor Yellow
        & $csc /nologo /target:winexe /platform:$platform /optimize+ /unsafe /warnaserror /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll "/out:$stagedExe" $stagedCs
        if ($LASTEXITCODE -ne 0) {
            throw "Candidate compilation failed with exit code $LASTEXITCODE; existing installation untouched."
        }

        $testProc = Start-Process -FilePath $stagedExe -ArgumentList @("--self-test", "`"$selfTestLog`"") -Wait -PassThru
        if (Test-Path -LiteralPath $selfTestLog) {
            $report = Get-Content -LiteralPath $selfTestLog -Raw
            Write-Host "Self-test: $($report.Trim())" -ForegroundColor Gray
        }
        if ($testProc.ExitCode -ne 0) {
            throw "Candidate BibataIceTrail --self-test failed with exit code $($testProc.ExitCode); existing installation untouched."
        }
    }

    if (-not $SkipCursor) {
        $themeName = "Bibata-$Style-Ice"
        $themeRoot = Join-Path $InstallDir $themeName
        $zipUrl = "https://github.com/ful1e5/Bibata_Cursor/releases/latest/download/$themeName-Windows.zip"
        $sizeDirName = "$themeName-$Size-Windows"
        $cursorDir = Join-Path $themeRoot $sizeDirName
        $schemeName = "$themeName ($Size)"

        $cursorsKey = Join-Path $RegistryRoot "Control Panel\Cursors"
        $schemesKey = Join-Path $RegistryRoot "Control Panel\Cursors\Schemes"

        $allSizes = @("Regular", "Large", "Extra-Large")
        $desiredSizes = if ($SingleSize) { @($Size) } else { $allSizes }
        $needsExtract = $false
        foreach ($dsz in $desiredSizes) {
            $dszDir = Join-Path $themeRoot "$themeName-$dsz-Windows"
            if (-not (Test-CursorSizeComplete $dszDir $roleMap)) {
                $needsExtract = $true
                break
            }
        }

        if ($needsExtract) {
            $cursorStageDir = Join-Path $env:TEMP ("bibata_cursor_stage_" + [Guid]::NewGuid().ToString("N"))
            $cursorStageExtract = Join-Path $cursorStageDir "extracted"
            New-Item -ItemType Directory -Path $cursorStageExtract -Force | Out-Null
            $stagedZipPath = Join-Path $cursorStageDir "$themeName-Windows.zip"

            if (-not [string]::IsNullOrWhiteSpace($TestCursorZipPath) -and (Test-Path -LiteralPath $TestCursorZipPath)) {
                Copy-Item -LiteralPath $TestCursorZipPath -Destination $stagedZipPath -Force
            }
            else {
                Write-Host "Downloading $themeName from GitHub Releases..." -ForegroundColor Yellow
                if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                    & curl.exe -L --fail --retry 3 -o $stagedZipPath $zipUrl
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to download $zipUrl (curl exit $LASTEXITCODE)."
                    }
                }
                else {
                    Invoke-WebRequest -Uri $zipUrl -OutFile $stagedZipPath -UseBasicParsing
                }
            }

            Write-Host "Extracting cursor package in staging..." -ForegroundColor Yellow
            $prevProgress = $ProgressPreference
            $ProgressPreference = "SilentlyContinue"
            Expand-Archive -Path $stagedZipPath -DestinationPath $cursorStageExtract -Force
            $ProgressPreference = $prevProgress

            $stagedCursorDir = Join-Path $cursorStageExtract $sizeDirName
            foreach ($role in $roleMap.Keys) {
                $rf = Join-Path $stagedCursorDir $roleMap[$role]
                if (-not (Test-Path -LiteralPath $rf)) {
                    throw "Expected cursor file not found after extraction: $rf"
                }
            }

            if ($SingleSize) {
                $stagedSizeDirs = Get-ChildItem -LiteralPath $cursorStageExtract -Directory -Filter "$themeName-*-Windows" -ErrorAction SilentlyContinue
                foreach ($sd in $stagedSizeDirs) {
                    if ($sd.Name -ne $sizeDirName) {
                        Remove-Item -LiteralPath $sd.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            $unusedExtras = @("install.inf", "uninstall.bat", "Zoom-in.cur", "Zoom-out.cur", "Pan.cur", "Grabbing.cur")
            $stagedDirsAfter = Get-ChildItem -LiteralPath $cursorStageExtract -Directory -Filter "$themeName-*-Windows" -ErrorAction SilentlyContinue
            foreach ($sd in $stagedDirsAfter) {
                foreach ($ex in $unusedExtras) {
                    $exPath = Join-Path $sd.FullName $ex
                    if (Test-Path -LiteralPath $exPath) {
                        Remove-Item -LiteralPath $exPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
        else {
            Write-Host "Cursor files already complete for requested size(s) at $themeRoot" -ForegroundColor Green
        }
    }

    # =========================================================================
    # PHASE B: Snapshot live state & commit atomically with full rollback
    # =========================================================================

    $installDirExistedBefore = Test-Path -LiteralPath $InstallDir

    $themeExistedBefore = $false
    $cursorsStateBeforeThisRun = $null
    $schemeSnapBefore = $null
    $createdCursorDirsThisRun = New-Object System.Collections.Generic.List[string]
    $createdCursorFilesThisRun = New-Object System.Collections.Generic.List[string]
    $createdCursorNormSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $cursorBackupDir = ""
    $overwrittenCursorBackups = New-Object System.Collections.Generic.List[object]
    $backedUpCursorNormSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $prunedSchemeRollbacks = New-Object System.Collections.Generic.List[object]
    $prunedSchemeNames = New-Object System.Collections.Generic.List[string]
    $cursorRegistryApplied = $false

    if (-not $SkipCursor) {
        $themeExistedBefore = Test-Path -LiteralPath $themeRoot
        $cursorsStateBeforeThisRun = Snapshot-CursorState $cursorsKey
        if ($null -eq $previousCursorState) {
            $previousCursorState = Resolve-InheritedCursorState $cursorsStateBeforeThisRun $InstallDir
        }
        $schemeSnapBefore = Snapshot-RegValue $schemesKey $schemeName
    }

    $trailDir = Join-Path $InstallDir "Bibata-Ice-Trail"
    $trailDirExistedBefore = Test-Path -LiteralPath $trailDir
    $destCs = Join-Path $trailDir "BibataIceTrail.cs"
    $destExe = Join-Path $trailDir "BibataIceTrail.exe"
    $cfgPath = Join-Path $trailDir "config.ini"
    $exeExistedBefore = $false
    $csExistedBefore = $false
    $cfgExistedBefore = $false
    # Outside the install directory so user backups survive both upgrade and rollback.
    $backupPrefix = Join-Path $env:TEMP ("bibata-trail-rollback-" + [Guid]::NewGuid().ToString("N"))
    $exeBak = "$backupPrefix.exe.bak"
    $csBak = "$backupPrefix.cs.bak"
    $cfgBak = "$backupPrefix.ini.bak"
    $runKey = Join-Path $RegistryRoot "Software\Microsoft\Windows\CurrentVersion\Run"
    $runSnapBefore = $null
    $runningProcs = @()
    $wasRunning = $false
    $trailFilesModified = $false
    $cfgModified = $false
    $runModified = $false

    if (-not $SkipTrail) {
        $exeExistedBefore = Test-Path -LiteralPath $destExe
        $csExistedBefore = Test-Path -LiteralPath $destCs
        $cfgExistedBefore = Test-Path -LiteralPath $cfgPath
        $ownsConfig = -not $cfgExistedBefore -or $managedTrailFiles -contains $cfgPath
        if ($ownsConfig) { $userConfigBackup = $null }
        $runSnapBefore = Snapshot-RegValue $runKey "BibataIceTrail"
        $runningProcs = @(Get-BibataProcessesByExe $destExe)
        $wasRunning = ($runningProcs.Count -gt 0)
    }

    try {
        if (-not $installDirExistedBefore) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }

        if (-not $SkipCursor) {
            if (-not $themeExistedBefore) {
                New-Item -ItemType Directory -Path $themeRoot -Force | Out-Null
                Add-UniquePath $createdCursorDirsThisRun $themeRoot
                Add-UniquePath $managedCursorDirs $themeRoot
            }

            if (-not [string]::IsNullOrWhiteSpace($cursorStageExtract)) {
                $prevManagedFileSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                foreach ($mf in $managedCursorFiles) {
                    $normMf = Normalize-BibataPath $mf
                    if (-not [string]::IsNullOrEmpty($normMf)) {
                        $prevManagedFileSet.Add($normMf) | Out-Null
                    }
                }

                $stageBaseLen = $cursorStageExtract.TrimEnd('\').Length + 1
                $stagedDirs = @(Get-ChildItem -LiteralPath $cursorStageExtract -Directory -Recurse | Sort-Object { $_.FullName.Length })
                foreach ($sd in $stagedDirs) {
                    $rel = $sd.FullName.Substring($stageBaseLen)
                    $dstSub = Join-Path $themeRoot $rel
                    if (-not (Test-Path -LiteralPath $dstSub)) {
                        New-Item -ItemType Directory -Path $dstSub -Force | Out-Null
                        Add-UniquePath $createdCursorDirsThisRun $dstSub
                        Add-UniquePath $managedCursorDirs $dstSub
                    }
                }

                $stagedFiles = @(Get-ChildItem -LiteralPath $cursorStageExtract -File -Recurse)
                foreach ($sf in $stagedFiles) {
                    $rel = $sf.FullName.Substring($stageBaseLen)
                    $dstFile = Join-Path $themeRoot $rel
                    $dstNorm = Normalize-BibataPath $dstFile
                    if ((Test-Path -LiteralPath $dstFile) -and (-not $prevManagedFileSet.Contains($dstNorm))) {
                        # Preserve pre-existing file not owned by previous Bibata manifest
                        continue
                    }
                    $existed = Test-Path -LiteralPath $dstFile
                    if ($existed) {
                        if (-not $createdCursorNormSet.Contains($dstNorm) -and -not $backedUpCursorNormSet.Contains($dstNorm)) {
                            if ([string]::IsNullOrWhiteSpace($cursorBackupDir)) {
                                $cursorBackupDir = Join-Path $env:TEMP ("bibata_cursor_bak_" + [Guid]::NewGuid().ToString("N"))
                                New-Item -ItemType Directory -Path $cursorBackupDir -Force | Out-Null
                            }
                            $bakFile = Join-Path $cursorBackupDir ("bak_" + $overwrittenCursorBackups.Count + ".bin")
                            $origHash = Get-FileSha256 $dstFile
                            [System.IO.File]::Copy($dstFile, $bakFile, $true)
                            $overwrittenCursorBackups.Add([pscustomobject]@{
                                Target = $dstFile
                                Backup = $bakFile
                                Hash   = $origHash
                            })
                            $backedUpCursorNormSet.Add($dstNorm) | Out-Null
                        }
                        Write-FileFreshInode $sf.FullName $dstFile
                    }
                    else {
                        Copy-Item -LiteralPath $sf.FullName -Destination $dstFile -Force
                        Add-UniquePath $createdCursorFilesThisRun $dstFile
                        $createdCursorNormSet.Add($dstNorm) | Out-Null
                    }
                    Add-UniquePath $managedCursorFiles $dstFile
                }

                if (-not $SingleSize) {
                    $themeNormPrefix = (Normalize-BibataPath $themeRoot) + "\"
                    $hashTable = @{}
                    foreach ($mf in @($managedCursorFiles)) {
                        $normMf = Normalize-BibataPath $mf
                        if (-not $normMf.StartsWith($themeNormPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
                        if (-not (Test-Path -LiteralPath $mf -PathType Leaf)) { continue }
                        $fi = Get-Item -LiteralPath $mf -ErrorAction SilentlyContinue
                        if (-not $fi -or $fi.Length -le 65536) { continue }
                        $h = Get-FileSha256 $mf
                        if ($hashTable.ContainsKey($h)) {
                            $target = $hashTable[$h]
                            if ((Normalize-BibataPath $target) -eq $normMf) { continue }
                            if (-not $createdCursorNormSet.Contains($normMf) -and -not $backedUpCursorNormSet.Contains($normMf)) {
                                if ([string]::IsNullOrWhiteSpace($cursorBackupDir)) {
                                    $cursorBackupDir = Join-Path $env:TEMP ("bibata_cursor_bak_" + [Guid]::NewGuid().ToString("N"))
                                    New-Item -ItemType Directory -Path $cursorBackupDir -Force | Out-Null
                                }
                                $bakFile = Join-Path $cursorBackupDir ("bak_" + $overwrittenCursorBackups.Count + ".bin")
                                [System.IO.File]::Copy($mf, $bakFile, $true)
                                $overwrittenCursorBackups.Add([pscustomobject]@{
                                    Target = $mf
                                    Backup = $bakFile
                                    Hash   = $h
                                })
                                $backedUpCursorNormSet.Add($normMf) | Out-Null
                            }
                            $backup = "$mf.dedup.tmp"
                            try {
                                Move-Item -LiteralPath $mf -Destination $backup -Force
                                New-Item -ItemType HardLink -Path $mf -Value $target -ErrorAction Stop | Out-Null
                                Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
                            }
                            catch {
                                if (Test-Path -LiteralPath $backup) {
                                    Move-Item -LiteralPath $backup -Destination $mf -Force -ErrorAction SilentlyContinue
                                }
                            }
                        }
                        else {
                            $hashTable[$h] = $mf
                        }
                    }
                }
            }

            if ($SingleSize) {
                $managedDirNormSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                foreach ($md in $managedCursorDirs) {
                    $nm = Normalize-BibataPath ([string]$md)
                    if (-not [string]::IsNullOrEmpty($nm)) { $managedDirNormSet.Add($nm) | Out-Null }
                }

                $extraSizes = @("Regular", "Large", "Extra-Large") | Where-Object { $_ -ne $Size }
                foreach ($extraSz in $extraSizes) {
                    $extraSizeDir = Join-Path $themeRoot "$themeName-$extraSz-Windows"
                    $extraSchemeName = "$themeName ($extraSz)"
                    if (Test-Path $schemesKey) {
                        $extraSchemeSnap = Snapshot-RegValue $schemesKey $extraSchemeName
                        if ($extraSchemeSnap.valExisted) {
                            if ($managedSchemeRecords.Contains($extraSchemeName)) {
                                $extraRec = $managedSchemeRecords[$extraSchemeName]
                                if ([string]::Equals([string]$extraSchemeSnap.value, [string]$extraRec.writtenValue, [StringComparison]::OrdinalIgnoreCase)) {
                                    $prunedSchemeRollbacks.Add([pscustomobject]@{ Name = $extraSchemeName; Snapshot = $extraSchemeSnap })
                                    if ([bool]$extraRec.existedBefore -and (Test-SchemeValueValid ([string]$extraRec.previousValue))) {
                                        $ek = if ([string]::IsNullOrWhiteSpace([string]$extraRec.previousKind)) { "String" } else { [string]$extraRec.previousKind }
                                        Set-ItemProperty -Path $schemesKey -Name $extraSchemeName -Value ([string]$extraRec.previousValue) -Type $ek
                                    }
                                    else {
                                        Remove-ItemProperty -Path $schemesKey -Name $extraSchemeName -ErrorAction SilentlyContinue
                                    }
                                    $managedSchemeRecords.Remove($extraSchemeName)
                                    for ($si = $managedSchemes.Count - 1; $si -ge 0; $si--) {
                                        if ([string]::Equals([string]$managedSchemes[$si], $extraSchemeName, [StringComparison]::OrdinalIgnoreCase)) {
                                            $managedSchemes.RemoveAt($si)
                                        }
                                    }
                                    $prunedSchemeNames.Add($extraSchemeName)
                                }
                            }
                            elseif (Test-AllSchemePathsUnderDir ([string]$extraSchemeSnap.value) $extraSizeDir) {
                                $prunedSchemeRollbacks.Add([pscustomobject]@{ Name = $extraSchemeName; Snapshot = $extraSchemeSnap })
                                Remove-ItemProperty -Path $schemesKey -Name $extraSchemeName -ErrorAction SilentlyContinue
                                for ($si = $managedSchemes.Count - 1; $si -ge 0; $si--) {
                                    if ([string]::Equals([string]$managedSchemes[$si], $extraSchemeName, [StringComparison]::OrdinalIgnoreCase)) {
                                        $managedSchemes.RemoveAt($si)
                                    }
                                }
                                $prunedSchemeNames.Add($extraSchemeName)
                            }
                        }
                    }
                }

                $referencedFiles = Get-RetainedSchemeFiles $schemesKey $managedSchemeRecords $previousCursorState $roleMap
                foreach ($extraSz in $extraSizes) {
                    $extraSizeDir = Join-Path $themeRoot "$themeName-$extraSz-Windows"
                    $extraDirNorm = Normalize-BibataPath $extraSizeDir
                    $extraPrefix = $extraDirNorm + "\"

                    foreach ($mf in @($managedCursorFiles)) {
                        $normMf = Normalize-BibataPath ([string]$mf)
                        if (-not $normMf.StartsWith($extraPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
                        if ($referencedFiles.Contains($normMf)) { continue }
                        if (Test-Path -LiteralPath $mf -PathType Leaf) {
                            if (-not $createdCursorNormSet.Contains($normMf) -and -not $backedUpCursorNormSet.Contains($normMf)) {
                                if ([string]::IsNullOrWhiteSpace($cursorBackupDir)) {
                                    $cursorBackupDir = Join-Path $env:TEMP ("bibata_cursor_bak_" + [Guid]::NewGuid().ToString("N"))
                                    New-Item -ItemType Directory -Path $cursorBackupDir -Force | Out-Null
                                }
                                $bakFile = Join-Path $cursorBackupDir ("bak_" + $overwrittenCursorBackups.Count + ".bin")
                                $origHash = Get-FileSha256 $mf
                                [System.IO.File]::Copy($mf, $bakFile, $true)
                                $overwrittenCursorBackups.Add([pscustomobject]@{
                                    Target = $mf
                                    Backup = $bakFile
                                    Hash   = $origHash
                                })
                                $backedUpCursorNormSet.Add($normMf) | Out-Null
                            }
                            Remove-Item -LiteralPath $mf -Force -ErrorAction Stop
                        }
                        Remove-PathFromList $managedCursorFiles $mf
                    }

                    if ($managedDirNormSet.Contains($extraDirNorm) -and (Test-Path -LiteralPath $extraSizeDir -PathType Container)) {
                        $remExtra = @(Get-ChildItem -LiteralPath $extraSizeDir -Force -ErrorAction SilentlyContinue)
                        if ($remExtra.Count -eq 0) {
                            Remove-Item -LiteralPath $extraSizeDir -Force -ErrorAction SilentlyContinue
                            Remove-PathFromList $managedCursorDirs $extraSizeDir
                        }
                        else {
                            Write-Host "Preserving non-empty extra size folder with user files: $extraSizeDir" -ForegroundColor Yellow
                        }
                    }
                }
            }

            if (-not (Test-Path $schemesKey)) {
                New-Item -Path $schemesKey -Force | Out-Null
            }
            if (-not (Test-Path $cursorsKey)) {
                New-Item -Path $cursorsKey -Force | Out-Null
            }

            $schemePaths = New-Object System.Collections.Generic.List[string]
            foreach ($role in $roleMap.Keys) {
                $schemePaths.Add((Join-Path $cursorDir $roleMap[$role]))
            }
            $schemeValueStr = $schemePaths -join ","

            $cursorRegistryApplied = $true
            Set-ItemProperty -Path $schemesKey -Name $schemeName -Value $schemeValueStr -Type String
            Set-ItemProperty -Path $cursorsKey -Name "(Default)" -Value $schemeName
            Set-ItemProperty -Path $cursorsKey -Name "Scheme Source" -Value 1 -Type DWord
            foreach ($role in $roleMap.Keys) {
                Set-ItemProperty -Path $cursorsKey -Name $role -Value (Join-Path $cursorDir $roleMap[$role]) -Type String
            }

            if (-not $SkipCursorRefresh) {
                Refresh-WindowsCursors
            }

            $managedCursor = $true
            if (-not $themeExistedBefore) {
                Add-UniquePath $managedThemeDirs $themeRoot
            }
            if (-not ($managedSchemes -contains $schemeName)) {
                $managedSchemes.Add($schemeName)
            }
            if (-not $managedSchemeRecords.Contains($schemeName)) {
                $inheritedSchemeSnap = Resolve-InheritedSchemeSnapshot $schemeName $schemeSnapBefore $InstallDir
                $managedSchemeRecords[$schemeName] = [ordered]@{
                    existedBefore = [bool]$inheritedSchemeSnap.valExisted
                    previousValue = $inheritedSchemeSnap.value
                    previousKind  = if ([string]::IsNullOrWhiteSpace([string]$inheritedSchemeSnap.kind)) { "String" } else { [string]$inheritedSchemeSnap.kind }
                    writtenValue  = $schemeValueStr
                }
            }
            else {
                $existingRec = $managedSchemeRecords[$schemeName]
                $stillMatchesOurs = $schemeSnapBefore.valExisted -and
                    [string]::Equals([string]$schemeSnapBefore.value, [string]$existingRec.writtenValue, [StringComparison]::OrdinalIgnoreCase)
                if (-not $stillMatchesOurs) {
                    $inheritedSchemeSnap = Resolve-InheritedSchemeSnapshot $schemeName $schemeSnapBefore $InstallDir
                    $existingRec.existedBefore = [bool]$inheritedSchemeSnap.valExisted
                    $existingRec.previousValue = $inheritedSchemeSnap.value
                    $existingRec.previousKind = if ([string]::IsNullOrWhiteSpace([string]$inheritedSchemeSnap.kind)) { "String" } else { [string]$inheritedSchemeSnap.kind }
                }
                $existingRec.writtenValue = $schemeValueStr
            }

            Write-Host "Applied cursor scheme: $schemeName" -ForegroundColor Green
        }

        if (-not $SkipTrail) {
            if (-not $trailDirExistedBefore) {
                New-Item -ItemType Directory -Path $trailDir -Force | Out-Null
            }

            if ($exeExistedBefore) { Write-FileFreshInode $destExe $exeBak }
            if ($csExistedBefore) { Write-FileFreshInode $destCs $csBak }
            if ($cfgExistedBefore) { Write-FileFreshInode $cfgPath $cfgBak }

            if ($wasRunning) {
                foreach ($rp in $runningProcs) {
                    Stop-Process -Id $rp.Id -Force -ErrorAction SilentlyContinue
                }
                Start-Sleep -Milliseconds 350
            }

            $trailFilesModified = $true
            Copy-Item -LiteralPath $stagedCs -Destination $destCs -Force
            Copy-Item -LiteralPath $stagedExe -Destination $destExe -Force

            if (-not [string]::IsNullOrWhiteSpace($Palette)) {
                if (-not $ownsConfig -and
                    (-not $userConfigBackup -or (Get-FileSha256 $cfgBak) -ne $userConfigBackup.writtenHash)) {
                    $userConfigBackup = [ordered]@{
                        originalBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($cfgBak))
                        writtenHash   = $null
                    }
                }
                $paletteMap = @{
                    Ice      = "0"
                    Cyan     = "1"
                    Frost    = "2"
                    PinkBlue = "4"
                    Rainbow  = "5"
                }
                $pVal = $paletteMap[$Palette]
                $cfgModified = $true
                if (Test-Path -LiteralPath $cfgPath) {
                    $lines = Get-Content -LiteralPath $cfgPath -Encoding UTF8
                    $updated = $false
                    $outLines = New-Object System.Collections.Generic.List[string]
                    foreach ($line in $lines) {
                        if ($line -match '^\s*Palette\s*=') {
                            $outLines.Add("Palette=$pVal")
                            $updated = $true
                        }
                        else {
                            $outLines.Add($line)
                        }
                    }
                    if (-not $updated) {
                        $outLines.Add("Palette=$pVal")
                    }
                    Set-Content -LiteralPath $cfgPath -Value $outLines -Encoding UTF8
                }
                else {
                    Set-Content -LiteralPath $cfgPath -Value @("[BibataIceTrail]", "Palette=$pVal") -Encoding UTF8
                }
                if ($userConfigBackup) { $userConfigBackup.writtenHash = Get-FileSha256 $cfgPath }
                Write-Host "Configured palette: $Palette (Palette=$pVal)" -ForegroundColor Green
            }

            if (-not $NoAutoStart) {
                if (-not (Test-Path $runKey)) {
                    New-Item -Path $runKey -Force | Out-Null
                }
                $runModified = $true
                Set-ItemProperty -Path $runKey -Name "BibataIceTrail" -Value "`"$destExe`"" -Type String
                $autoStartManaged = $true
                Write-Host "Enabled login auto-start in Run registry." -ForegroundColor Green
            }

            if (-not $NoLaunch) {
                Start-BibataInstance -exePath $destExe -workDir $trailDir -extraArgs $LaunchArgs -NoTaskScheduler:$SkipTaskScheduler
                Write-Host "BibataIceTrail is running silently in the background (toggle with Ctrl+Alt+Shift+G)." -ForegroundColor Green
            }

            $managedTrail = $true
            $prevTrailExePath = $destExe
            Add-UniquePath $managedTrailFiles $destExe
            Add-UniquePath $managedTrailFiles $destCs
            # The running app can create config.ini after a -NoLaunch install.
            if ($ownsConfig) { Add-UniquePath $managedTrailFiles $cfgPath }
        }

        $manifestObj = [ordered]@{
            schemaVersion        = 3
            installDir           = $InstallDir
            managedTrail         = $managedTrail
            trailExePath         = $prevTrailExePath
            managedTrailFiles    = @($managedTrailFiles)
            userConfigBackup     = $userConfigBackup
            autoStartManaged     = $autoStartManaged
            managedCursor        = $managedCursor
            managedThemeDirs     = @($managedThemeDirs)
            managedCursorDirs    = @($managedCursorDirs)
            managedCursorFiles   = @($managedCursorFiles)
            managedSchemes       = @($managedSchemes)
            managedSchemeRecords = $managedSchemeRecords
            previousCursorState  = $previousCursorState
            updatedAt            = (Get-Date).ToString("o")
        }
        Write-BibataJson $manifestPath $manifestObj

        if (-not $SkipCursor) {
            $rtFile = Join-Path $InstallDir "bibata-runtime-schemes.json"
            if (Test-Path -LiteralPath $rtFile -PathType Leaf) {
                try {
                    $runtime = Read-BibataRuntimeSchemes $rtFile
                    if ($runtime.NeedsRepair -or $prunedSchemeNames.Count -gt 0) {
                        $kept = @($runtime.Records | Where-Object { $prunedSchemeNames -notcontains $_.name })
                        if ($kept.Count -eq 0) { Remove-Item -LiteralPath $rtFile -Force }
                        else { Write-BibataJson $rtFile $kept }
                    }
                }
                catch {
                    Write-Warning "Could not update cursor scheme backup '$rtFile': $($_.Exception.Message)"
                }
            }
        }

        if (-not $SkipTrail) {
            if (Test-Path -LiteralPath $exeBak) { Remove-Item -LiteralPath $exeBak -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $csBak) { Remove-Item -LiteralPath $csBak -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $cfgBak) { Remove-Item -LiteralPath $cfgBak -Force -ErrorAction SilentlyContinue }
        }
        if (-not [string]::IsNullOrWhiteSpace($cursorBackupDir) -and (Test-Path -LiteralPath $cursorBackupDir)) {
            Remove-Item -LiteralPath $cursorBackupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Warning "Installation/upgrade failed; rolling back all applied changes: $($_.Exception.Message)"

        if (-not $SkipTrail) {
            $newProcs = @(Get-BibataProcessesByExe $destExe)
            foreach ($np in $newProcs) {
                Stop-Process -Id $np.Id -Force -ErrorAction SilentlyContinue
            }
            if ($newProcs.Count -gt 0) { Start-Sleep -Milliseconds 250 }

            if ($csExistedBefore) {
                Restore-FileBackup $csBak $destCs | Out-Null
            }
            elseif ($trailFilesModified -and (Test-Path -LiteralPath $destCs)) {
                Remove-Item -LiteralPath $destCs -Force -ErrorAction SilentlyContinue
            }

            if ($exeExistedBefore) {
                Restore-FileBackup $exeBak $destExe | Out-Null
            }
            elseif ($trailFilesModified -and (Test-Path -LiteralPath $destExe)) {
                Remove-Item -LiteralPath $destExe -Force -ErrorAction SilentlyContinue
            }

            if ($cfgExistedBefore) {
                Restore-FileBackup $cfgBak $cfgPath | Out-Null
            }
            elseif ($cfgModified -and (Test-Path -LiteralPath $cfgPath)) {
                Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue
            }

            if ($runModified) {
                Restore-RegValue $runKey "BibataIceTrail" $runSnapBefore
            }

            if ($wasRunning -and (Test-Path -LiteralPath $destExe)) {
                try {
                    Start-BibataInstance -exePath $destExe -workDir $trailDir -extraArgs $LaunchArgs -NoTaskScheduler:$SkipTaskScheduler
                    Write-Host "Restored and restarted previous BibataIceTrail version." -ForegroundColor Yellow
                }
                catch {
                    Write-Warning "Failed to restart previous BibataIceTrail version: $($_.Exception.Message)"
                }
            }

            if (-not $trailDirExistedBefore -and (Test-Path -LiteralPath $trailDir)) {
                $remTrail = @(Get-ChildItem -LiteralPath $trailDir -Force -ErrorAction SilentlyContinue)
                if ($remTrail.Count -eq 0) {
                    Remove-Item -LiteralPath $trailDir -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if (-not $SkipCursor) {
            if ($cursorRegistryApplied) {
                try {
                    Restore-CursorState $cursorsKey $cursorsStateBeforeThisRun
                    Restore-RegValue $schemesKey $schemeName $schemeSnapBefore
                    foreach ($pr in $prunedSchemeRollbacks) {
                        Restore-RegValue $schemesKey $pr.Name $pr.Snapshot
                    }
                    if (-not $SkipCursorRefresh) {
                        Refresh-WindowsCursors
                    }
                }
                catch {
                    Write-Warning "Failed to rollback cursor registry state: $($_.Exception.Message)"
                }
            }
            elseif ($prunedSchemeRollbacks.Count -gt 0) {
                foreach ($pr in $prunedSchemeRollbacks) {
                    try { Restore-RegValue $schemesKey $pr.Name $pr.Snapshot } catch {}
                }
            }

            foreach ($cf in $createdCursorFilesThisRun) {
                if (Test-Path -LiteralPath $cf -PathType Leaf) {
                    Remove-Item -LiteralPath $cf -Force -ErrorAction SilentlyContinue
                }
            }

            foreach ($bk in $overwrittenCursorBackups) {
                try {
                    if (Test-Path -LiteralPath $bk.Backup -PathType Leaf) {
                        Write-FileFreshInode $bk.Backup $bk.Target
                        if ((Get-FileSha256 $bk.Target) -eq $bk.Hash) {
                            Remove-Item -LiteralPath $bk.Backup -Force -ErrorAction SilentlyContinue
                        }
                        else {
                            Write-Warning "Cursor file backup hash mismatch for $($bk.Target); keeping backup at $($bk.Backup)"
                        }
                    }
                }
                catch {
                    Write-Warning "Could not restore cursor file $($bk.Target): $($_.Exception.Message); keeping backup at $($bk.Backup)"
                }
            }

            $dirsDesc = @($createdCursorDirsThisRun | Sort-Object { $_.Length } -Descending)
            foreach ($cd in $dirsDesc) {
                if (Test-Path -LiteralPath $cd -PathType Container) {
                    $remDir = @(Get-ChildItem -LiteralPath $cd -Force -ErrorAction SilentlyContinue)
                    if ($remDir.Count -eq 0) {
                        Remove-Item -LiteralPath $cd -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($cursorBackupDir) -and (Test-Path -LiteralPath $cursorBackupDir)) {
                $remBak = @(Get-ChildItem -LiteralPath $cursorBackupDir -Force -ErrorAction SilentlyContinue)
                if ($remBak.Count -eq 0) {
                    Remove-Item -LiteralPath $cursorBackupDir -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if (-not $installDirExistedBefore -and (Test-Path -LiteralPath $InstallDir)) {
            $remRoot = @(Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue)
            if ($remRoot.Count -eq 0) {
                Remove-Item -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue
            }
        }

        throw
    }
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($trailStageDir) -and (Test-Path -LiteralPath $trailStageDir)) {
        Remove-Item -LiteralPath $trailStageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not [string]::IsNullOrWhiteSpace($cursorStageDir) -and (Test-Path -LiteralPath $cursorStageDir)) {
        Remove-Item -LiteralPath $cursorStageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Done! Enjoy Bibata-Modern-Ice + Ice Glow." -ForegroundColor Cyan
