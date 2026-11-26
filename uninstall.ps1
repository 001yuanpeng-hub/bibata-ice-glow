[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [switch]$KeepFiles,
    [string]$RegistryRoot = "HKCU:",
    [switch]$SkipCursorRefresh
)

$ErrorActionPreference = "Stop"

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

function Resolve-BibataAbsolutePath([string]$rawPath) {
    if ([string]::IsNullOrWhiteSpace($rawPath)) { return "" }
    $trimmed = $rawPath.Trim().Trim('"')
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($trimmed)
    $full = [System.IO.Path]::GetFullPath($resolved)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Get-BibataCommandExePath([string]$cmd) {
    if ([string]::IsNullOrWhiteSpace($cmd)) { return "" }
    $t = $cmd.Trim()
    if ($t.StartsWith('"')) {
        $endIdx = $t.IndexOf('"', 1)
        if ($endIdx -gt 1) {
            return $t.Substring(1, $endIdx - 1)
        }
    }
    if ($t -match '^(?i)(.+?\.exe)(?:\s+|$)') {
        return $Matches[1]
    }
    return ($t -split '\s+')[0]
}

function Refresh-WindowsCursors {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BibataCursorRestore {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
}
"@ -ErrorAction SilentlyContinue | Out-Null
    [BibataCursorRestore]::SystemParametersInfo(0x0057, 0, [IntPtr]::Zero, 0x02) | Out-Null
}

function Stop-BibataProcessesByExe([string]$targetExe) {
    $normTarget = Normalize-BibataPath $targetExe
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'BibataIceTrail.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ((Normalize-BibataPath $p.ExecutablePath) -eq $normTarget) {
                Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        $gp = Get-Process -Name "BibataIceTrail" -ErrorAction SilentlyContinue
        foreach ($p in $gp) {
            try {
                if ((Normalize-BibataPath $p.MainModule.FileName) -eq $normTarget) {
                    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
            }
        }
    }
}

function Test-PathUnderAny([string]$candidatePath, [string[]]$roots) {
    $normCand = Normalize-BibataPath $candidatePath
    if ([string]::IsNullOrEmpty($normCand) -or -not $roots) { return $false }
    foreach ($r in $roots) {
        $normRoot = Normalize-BibataPath $r
        if ([string]::IsNullOrEmpty($normRoot)) { continue }
        if ($normCand -eq $normRoot -or $normCand.StartsWith($normRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Restore-CursorState($cursorsPath, $prevState) {
    if (-not $prevState -or -not $prevState.existed) {
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

function Test-CursorStateValid($prevState) {
    if (-not $prevState -or -not $prevState.existed -or -not $prevState.roles) {
        return $false
    }
    $vals = New-Object System.Collections.Generic.List[object]
    if ($prevState.roles -is [System.Collections.IDictionary]) {
        foreach ($roleName in $prevState.roles.Keys) {
            $vals.Add($prevState.roles[$roleName])
        }
    }
    else {
        foreach ($prop in $prevState.roles.PSObject.Properties) {
            $vals.Add($prop.Value)
        }
    }
    foreach ($v in $vals) {
        if ($null -eq $v) { continue }
        $s = [string]$v
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($s)
        if (-not (Test-Path -LiteralPath $expanded -PathType Leaf)) {
            return $false
        }
    }
    return $true
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

function Test-IsBibataSchemeName([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    return ($name -match '^(?i)Bibata-(?:Modern|Original)-Ice \((?:Regular|Large|Extra-Large)\)$')
}

function Test-PathOwnedByInstall([string]$candidatePath, $fileNormSet, [string[]]$cursorDirs, [string[]]$themeDirs, [string[]]$fallbackDirs, [bool]$allowFallback) {
    if ([string]::IsNullOrWhiteSpace($candidatePath)) { return $false }
    $expanded = [Environment]::ExpandEnvironmentVariables($candidatePath.Trim())
    $normCand = Normalize-BibataPath $expanded
    if ([string]::IsNullOrEmpty($normCand)) { return $false }
    if ($fileNormSet -and $fileNormSet.Contains($normCand)) { return $true }
    if (Test-PathUnderAny $expanded $cursorDirs) { return $true }
    if (Test-PathUnderAny $expanded $themeDirs) { return $true }
    if ($allowFallback -and (Test-PathUnderAny $expanded $fallbackDirs)) { return $true }
    return $false
}

function Try-RemoveFileStrict([string]$filePath, $failedList) {
    if ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return $true
    }
    try {
        Remove-Item -LiteralPath $filePath -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $filePath -PathType Leaf) {
            $failedList.Add([pscustomobject]@{ Path = $filePath; Reason = "File still exists after removal attempt." })
            return $false
        }
        return $true
    }
    catch {
        $failedList.Add([pscustomobject]@{ Path = $filePath; Reason = $_.Exception.Message })
        return $false
    }
}

function Try-RemoveEmptyDirStrict([string]$dirPath, $failedList) {
    if ([string]::IsNullOrWhiteSpace($dirPath) -or -not (Test-Path -LiteralPath $dirPath -PathType Container)) {
        return $true
    }
    $rem = @(Get-ChildItem -LiteralPath $dirPath -Force -ErrorAction SilentlyContinue)
    if ($rem.Count -gt 0) {
        return $false
    }
    try {
        Remove-Item -LiteralPath $dirPath -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $dirPath -PathType Container) {
            $failedList.Add([pscustomobject]@{ Path = $dirPath; Reason = "Directory still exists after removal attempt." })
            return $false
        }
        return $true
    }
    catch {
        $failedList.Add([pscustomobject]@{ Path = $dirPath; Reason = $_.Exception.Message })
        return $false
    }
}

function Restore-WindowsDefaultCursors([string]$cursorsPath) {
    if (-not (Test-Path $cursorsPath)) { return }
    Set-ItemProperty -Path $cursorsPath -Name "(Default)" -Value "" -Type String
    Set-ItemProperty -Path $cursorsPath -Name "Scheme Source" -Value 2 -Type DWord

    $defaults = @{
        Arrow       = "%SystemRoot%\cursors\aero_arrow.cur"
        Help        = "%SystemRoot%\cursors\aero_helpsel.cur"
        AppStarting = "%SystemRoot%\cursors\aero_working.ani"
        Wait        = "%SystemRoot%\cursors\aero_busy.ani"
        Crosshair   = ""
        IBeam       = ""
        NWPen       = "%SystemRoot%\cursors\aero_pen.cur"
        No          = "%SystemRoot%\cursors\aero_unavail.cur"
        SizeNS      = "%SystemRoot%\cursors\aero_ns.cur"
        SizeWE      = "%SystemRoot%\cursors\aero_ew.cur"
        SizeNWSE    = "%SystemRoot%\cursors\aero_nwse.cur"
        SizeNESW    = "%SystemRoot%\cursors\aero_nesw.cur"
        SizeAll     = "%SystemRoot%\cursors\aero_move.cur"
        UpArrow     = "%SystemRoot%\cursors\aero_up.cur"
        Hand        = "%SystemRoot%\cursors\aero_link.cur"
    }
    foreach ($role in $defaults.Keys) {
        $v = $defaults[$role]
        $t = if ($v -like "*%*") { "ExpandString" } else { "String" }
        Set-ItemProperty -Path $cursorsPath -Name $role -Value $v -Type $t
    }
    Remove-ItemProperty -Path $cursorsPath -Name "Pin" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $cursorsPath -Name "Person" -ErrorAction SilentlyContinue
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if ((Test-Path "D:\Software\Cursors\bibata-ice-glow-manifest.json") -or (Test-Path "D:\Software\Cursors\Bibata-Ice-Trail")) {
        $InstallDir = "D:\Software\Cursors"
    }
    else {
        $InstallDir = Join-Path $env:LOCALAPPDATA "BibataIceGlow"
    }
}
$InstallDir = Resolve-BibataAbsolutePath $InstallDir

$manifestPath = Join-Path $InstallDir "bibata-ice-glow-manifest.json"
$manifest = $null
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $manifest = $null
    }
}

$trailDir = Join-Path $InstallDir "Bibata-Ice-Trail"
$trailExe = if ($manifest -and -not [string]::IsNullOrWhiteSpace($manifest.trailExePath)) {
    [string]$manifest.trailExePath
}
else {
    Join-Path $trailDir "BibataIceTrail.exe"
}
$shouldManageTrail = (-not $manifest) -or ([bool]$manifest.managedTrail)

# 1. Stop only this installation's BibataIceTrail instance and clean matching auto-start entry
if ($shouldManageTrail) {
    Stop-BibataProcessesByExe $trailExe
    Start-Sleep -Milliseconds 300

    $runKey = Join-Path $RegistryRoot "Software\Microsoft\Windows\CurrentVersion\Run"
    if (Test-Path $runKey) {
        $runRegItem = Get-Item -Path $runKey -ErrorAction SilentlyContinue
        if ($runRegItem) {
            $runVal = $runRegItem.GetValue("BibataIceTrail", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -ne $runVal) {
                $runCmdStr = [Environment]::ExpandEnvironmentVariables([string]$runVal)
                $runExePath = Get-BibataCommandExePath $runCmdStr
                if ((Normalize-BibataPath $runExePath) -eq (Normalize-BibataPath $trailExe)) {
                    Remove-ItemProperty -Path $runKey -Name "BibataIceTrail" -ErrorAction SilentlyContinue
                }
                else {
                    Write-Host "Run entry points to another installation ($runVal); preserving it." -ForegroundColor Yellow
                }
            }
        }
    }
    Write-Host "Stopped BibataIceTrail and checked auto-start entry." -ForegroundColor Green
}

# 2. Restore cursors and clean schemes according to manifest ownership
$cursorsKey = Join-Path $RegistryRoot "Control Panel\Cursors"
$schemesKey = Join-Path $RegistryRoot "Control Panel\Cursors\Schemes"

$cursorRoles = @(
    "Arrow", "Help", "AppStarting", "Wait", "Crosshair", "IBeam",
    "NWPen", "No", "SizeNS", "SizeWE", "SizeNWSE", "SizeNESW",
    "SizeAll", "UpArrow", "Hand", "Pin", "Person"
)
$currentArrow = ""
$currentDefault = ""
$currentActiveRoles = [ordered]@{}
if (Test-Path $cursorsKey) {
    $curItem = Get-Item -Path $cursorsKey -ErrorAction SilentlyContinue
    if ($curItem) {
        $aVal = $curItem.GetValue("Arrow", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -ne $aVal) { $currentArrow = [string]$aVal }
        $dVal = $curItem.GetValue("", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -ne $dVal) { $currentDefault = [string]$dVal }
        foreach ($rName in $cursorRoles) {
            $rv = $curItem.GetValue($rName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -ne $rv -and -not [string]::IsNullOrWhiteSpace([string]$rv)) {
                $currentActiveRoles[$rName] = [string]$rv
            }
        }
    }
}

$failedDeletions = New-Object System.Collections.Generic.List[object]
$remainingManagedCursorFiles = New-Object System.Collections.Generic.List[string]
$remainingManagedCursorDirs = New-Object System.Collections.Generic.List[string]
$remainingManagedThemeDirs = New-Object System.Collections.Generic.List[string]
$retryUseV1Manifest = $false
$trailHasRemaining = $false

if ($manifest) {
    if (-not [bool]$manifest.managedCursor) {
        Write-Host "Cursors were not managed by this installation (-SkipCursor); preserving existing cursor settings and theme files." -ForegroundColor Yellow
    }
    else {
        $managedDirs = @()
        if ($manifest.managedThemeDirs) { $managedDirs = @($manifest.managedThemeDirs) }
        $managedCursorDirs = @()
        if ($manifest.managedCursorDirs) { $managedCursorDirs = @($manifest.managedCursorDirs) }
        $managedCursorFiles = @()
        if ($manifest.managedCursorFiles) { $managedCursorFiles = @($manifest.managedCursorFiles) }
        $managedSchemes = @()
        if ($manifest.managedSchemes) { $managedSchemes = @($manifest.managedSchemes) }
        $hasFileManifest = ($null -ne $manifest.PSObject.Properties["managedCursorFiles"])

        $managedFileNormSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($mf in $managedCursorFiles) {
            $normMf = Normalize-BibataPath ([string]$mf)
            if (-not [string]::IsNullOrEmpty($normMf)) {
                $managedFileNormSet.Add($normMf) | Out-Null
            }
        }

        $possibleBibataDirs = @(
            (Join-Path $InstallDir "Bibata-Modern-Ice"),
            (Join-Path $InstallDir "Bibata-Original-Ice")
        )
        $isBibataDefaultName = ($managedSchemes -contains $currentDefault) -or (Test-IsBibataSchemeName $currentDefault)
        $allowFallback = ($managedSchemes -contains $currentDefault) -or $isBibataDefaultName
        $arrowOwned = Test-PathOwnedByInstall $currentArrow $managedFileNormSet $managedCursorDirs $managedDirs $possibleBibataDirs $allowFallback
        $allActiveRolesOwned = $true
        foreach ($rKey in $currentActiveRoles.Keys) {
            if (-not (Test-PathOwnedByInstall $currentActiveRoles[$rKey] $managedFileNormSet $managedCursorDirs $managedDirs $possibleBibataDirs $allowFallback)) {
                $allActiveRolesOwned = $false
                break
            }
        }
        $stillUsingOurs = $isBibataDefaultName -and $arrowOwned -and $allActiveRolesOwned

        if ($stillUsingOurs) {
            if (Test-CursorStateValid $manifest.previousCursorState) {
                Restore-CursorState $cursorsKey $manifest.previousCursorState
                Write-Host "Restored pre-install cursor configuration." -ForegroundColor Green
            }
            else {
                if ($manifest.previousCursorState -and $manifest.previousCursorState.existed) {
                    Write-Host "Saved pre-install cursor files are no longer available; restoring default Windows mouse pointers." -ForegroundColor Yellow
                }
                else {
                    Write-Host "Restored default Windows mouse pointers." -ForegroundColor Green
                }
                Restore-WindowsDefaultCursors $cursorsKey
            }
            if (-not $SkipCursorRefresh) {
                Refresh-WindowsCursors
            }
        }
        else {
            Write-Host "Current cursor scheme was customized or changed by user ($currentDefault); keeping current cursor settings." -ForegroundColor Yellow
        }

        $schemeRecordMap = @{}
        if ($manifest.managedSchemeRecords) {
            foreach ($prop in $manifest.managedSchemeRecords.PSObject.Properties) {
                $recVal = $prop.Value
                if ($recVal) {
                    $schemeRecordMap[$prop.Name] = [ordered]@{
                        existedBefore  = [bool]$recVal.existedBefore
                        previousValue  = $recVal.previousValue
                        previousKind   = if ([string]::IsNullOrWhiteSpace([string]$recVal.previousKind)) { "String" } else { [string]$recVal.previousKind }
                        writtenValues  = New-Object System.Collections.Generic.List[string]
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$recVal.writtenValue)) {
                        $schemeRecordMap[$prop.Name].writtenValues.Add([string]$recVal.writtenValue)
                    }
                }
            }
        }
        $rtSchemesPath = Join-Path $InstallDir "bibata-runtime-schemes.json"
        if (Test-Path -LiteralPath $rtSchemesPath -PathType Leaf) {
            try {
                $rtList = Get-Content -LiteralPath $rtSchemesPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($rtItem in @($rtList)) {
                    if (-not $rtItem -or [string]::IsNullOrWhiteSpace([string]$rtItem.name)) { continue }
                    $rtName = [string]$rtItem.name
                    $existingKey = $null
                    foreach ($rk in $schemeRecordMap.Keys) {
                        if ([string]::Equals([string]$rk, $rtName, [StringComparison]::OrdinalIgnoreCase)) {
                            $existingKey = $rk
                            break
                        }
                    }
                    if ($null -eq $existingKey) {
                        $schemeRecordMap[$rtName] = [ordered]@{
                            existedBefore = [bool]$rtItem.existedBefore
                            previousValue = $rtItem.previousValue
                            previousKind  = if ([string]::IsNullOrWhiteSpace([string]$rtItem.previousKind)) { "String" } else { [string]$rtItem.previousKind }
                            writtenValues = New-Object System.Collections.Generic.List[string]
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string]$rtItem.writtenValue)) {
                            $schemeRecordMap[$rtName].writtenValues.Add([string]$rtItem.writtenValue)
                        }
                    }
                    else {
                        $existingRec = $schemeRecordMap[$existingKey]
                        $prevMatchedManifestWritten = $false
                        if ([bool]$rtItem.existedBefore) {
                            foreach ($mwv in $existingRec.writtenValues) {
                                if ([string]::Equals([string]$rtItem.previousValue, [string]$mwv, [StringComparison]::OrdinalIgnoreCase)) {
                                    $prevMatchedManifestWritten = $true
                                    break
                                }
                            }
                        }
                        if (-not $prevMatchedManifestWritten) {
                            $existingRec.existedBefore = [bool]$rtItem.existedBefore
                            $existingRec.previousValue = $rtItem.previousValue
                            $existingRec.previousKind = if ([string]::IsNullOrWhiteSpace([string]$rtItem.previousKind)) { "String" } else { [string]$rtItem.previousKind }
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string]$rtItem.writtenValue)) {
                            $existingRec.writtenValues.Add([string]$rtItem.writtenValue)
                        }
                    }
                }
            }
            catch {
            }
        }

        if (Test-Path $schemesKey) {
            $schemesRegItem = Get-Item -Path $schemesKey -ErrorAction SilentlyContinue
            if ($schemesRegItem) {
                $schemeNames = @($schemesRegItem.GetValueNames())
                foreach ($valName in $schemeNames) {
                    if ([string]::IsNullOrEmpty($valName)) { continue }
                    $rawVal = [string]$schemesRegItem.GetValue($valName, "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $matchedKey = $null
                    foreach ($rk in $schemeRecordMap.Keys) {
                        if ([string]::Equals([string]$rk, $valName, [StringComparison]::OrdinalIgnoreCase)) {
                            $matchedKey = $rk
                            break
                        }
                    }

                    if ($null -ne $matchedKey) {
                        $rec = $schemeRecordMap[$matchedKey]
                        $matchesWritten = $false
                        foreach ($wv in $rec.writtenValues) {
                            if ([string]::Equals($rawVal, [string]$wv, [StringComparison]::OrdinalIgnoreCase)) {
                                $matchesWritten = $true
                                break
                            }
                        }
                        if ($matchesWritten) {
                            if ([bool]$rec.existedBefore) {
                                if (Test-SchemeValueValid ([string]$rec.previousValue)) {
                                    $prevKind = if ([string]::IsNullOrWhiteSpace([string]$rec.previousKind)) { "String" } else { [string]$rec.previousKind }
                                    Set-ItemProperty -Path $schemesKey -Name $valName -Value ([string]$rec.previousValue) -Type $prevKind
                                }
                                else {
                                    Write-Host "Saved pre-install scheme '$valName' references missing files; removing dead scheme entry." -ForegroundColor Yellow
                                    Remove-ItemProperty -Path $schemesKey -Name $valName -ErrorAction SilentlyContinue
                                }
                            }
                            else {
                                Remove-ItemProperty -Path $schemesKey -Name $valName -ErrorAction SilentlyContinue
                            }
                        }
                        else {
                            Write-Host "Scheme '$valName' was modified after install; preserving current value." -ForegroundColor Yellow
                        }
                    }
                    else {
                        $isBibataSchemeName = ($managedSchemes -contains $valName) -or (Test-IsBibataSchemeName $valName)
                        if ($isBibataSchemeName) {
                            $parts = $rawVal -split ','
                            $nonEmptyCount = 0
                            $allOwned = $true
                            foreach ($pt in $parts) {
                                if ([string]::IsNullOrWhiteSpace($pt)) { continue }
                                $nonEmptyCount++
                                if (-not (Test-PathOwnedByInstall $pt $managedFileNormSet $managedCursorDirs $managedDirs $possibleBibataDirs ($managedSchemes -contains $valName))) {
                                    $allOwned = $false
                                    break
                                }
                            }
                            if ($nonEmptyCount -gt 0 -and $allOwned) {
                                Remove-ItemProperty -Path $schemesKey -Name $valName -ErrorAction SilentlyContinue
                            }
                        }
                    }
                }
            }
        }

        if (-not $KeepFiles) {
            if ($hasFileManifest) {
                foreach ($mf in $managedCursorFiles) {
                    $mfStr = [string]$mf
                    if (-not [string]::IsNullOrWhiteSpace($mfStr) -and (Test-Path -LiteralPath $mfStr -PathType Leaf)) {
                        if (-not (Try-RemoveFileStrict $mfStr $failedDeletions)) {
                            $remainingManagedCursorFiles.Add($mfStr)
                        }
                    }
                }
                $dirsToCheck = New-Object System.Collections.Generic.List[string]
                foreach ($d in $managedCursorDirs) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$d)) { $dirsToCheck.Add([string]$d) }
                }
                foreach ($d in $managedDirs) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$d) -and -not ($dirsToCheck -contains [string]$d)) {
                        $dirsToCheck.Add([string]$d)
                    }
                }
                $sortedDirs = @($dirsToCheck | Sort-Object { $_.Length } -Descending)
                foreach ($md in $sortedDirs) {
                    if (Test-Path -LiteralPath $md -PathType Container) {
                        $remItems = @(Get-ChildItem -LiteralPath $md -Force -ErrorAction SilentlyContinue)
                        if ($remItems.Count -eq 0) {
                            if (-not (Try-RemoveEmptyDirStrict $md $failedDeletions)) {
                                $remainingManagedCursorDirs.Add($md)
                            }
                        }
                        else {
                            $hasFailedManagedChild = $false
                            foreach ($rf in $remainingManagedCursorFiles) {
                                if (Test-PathUnderAny $rf @($md)) { $hasFailedManagedChild = $true; break }
                            }
                            if (-not $hasFailedManagedChild) {
                                foreach ($rd in $remainingManagedCursorDirs) {
                                    if (Test-PathUnderAny $rd @($md)) { $hasFailedManagedChild = $true; break }
                                }
                            }
                            if ($hasFailedManagedChild) {
                                $remainingManagedCursorDirs.Add($md)
                            }
                        }
                    }
                }
            }
            else {
                # Legacy v1 manifest: clean only known Bibata cursor files inside size folders; preserve any unknown/private files
                $knownBibataFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                foreach ($kf in @(
                    "Pointer.cur", "Help.cur", "Work.ani", "Busy.ani", "Cross.cur", "Text.cur",
                    "Handwriting.cur", "Unavailable.cur", "Vert.cur", "Horz.cur", "Dgn1.cur", "Dgn2.cur",
                    "Move.cur", "Alternate.cur", "Link.cur", "Pin.cur", "Person.cur"
                )) {
                    $knownBibataFiles.Add($kf) | Out-Null
                }
                foreach ($md in $managedDirs) {
                    if ([string]::IsNullOrWhiteSpace($md) -or -not (Test-Path -LiteralPath $md -PathType Container)) { continue }
                    $mdHadFailure = $false
                    $sizeSubDirs = @(Get-ChildItem -LiteralPath $md -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
                        $_.Name -match '^(?i)Bibata-(?:Modern|Original)-Ice-(?:Regular|Large|Extra-Large)-Windows$'
                    })
                    foreach ($sd in $sizeSubDirs) {
                        $filesInSize = @(Get-ChildItem -LiteralPath $sd.FullName -File -Force -ErrorAction SilentlyContinue)
                        foreach ($f in $filesInSize) {
                            if ($knownBibataFiles.Contains($f.Name)) {
                                if (-not (Try-RemoveFileStrict $f.FullName $failedDeletions)) {
                                    $mdHadFailure = $true
                                }
                            }
                        }
                        $remSize = @(Get-ChildItem -LiteralPath $sd.FullName -Force -ErrorAction SilentlyContinue)
                        if ($remSize.Count -eq 0) {
                            if (-not (Try-RemoveEmptyDirStrict $sd.FullName $failedDeletions)) {
                                $mdHadFailure = $true
                            }
                        }
                    }
                    $remTheme = @(Get-ChildItem -LiteralPath $md -Force -ErrorAction SilentlyContinue)
                    if ($remTheme.Count -eq 0) {
                        if (-not (Try-RemoveEmptyDirStrict $md $failedDeletions)) {
                            $mdHadFailure = $true
                        }
                    }
                    else {
                        Write-Host "Preserving non-empty theme directory with unknown/user files (v1 manifest): $md" -ForegroundColor Yellow
                    }
                    if ($mdHadFailure) {
                        $remainingManagedThemeDirs.Add($md)
                        $retryUseV1Manifest = $true
                    }
                }
            }
        }
    }
}
else {
    # Legacy install without manifest: conservative cleanup scoped strictly to InstallDir
    $legacyDirs = @(
        (Join-Path $InstallDir "Bibata-Modern-Ice"),
        (Join-Path $InstallDir "Bibata-Original-Ice")
    )
    $legacyDefaultOk = [string]::IsNullOrWhiteSpace($currentDefault) -or (Test-IsBibataSchemeName $currentDefault)
    $legacyAllRolesInDir = ($currentActiveRoles.Count -gt 0) -and (Test-PathUnderAny $currentArrow $legacyDirs)
    if ($legacyAllRolesInDir) {
        foreach ($rKey in $currentActiveRoles.Keys) {
            if (-not (Test-PathUnderAny $currentActiveRoles[$rKey] $legacyDirs)) {
                $legacyAllRolesInDir = $false
                break
            }
        }
    }
    if ($legacyDefaultOk -and $legacyAllRolesInDir) {
        Restore-WindowsDefaultCursors $cursorsKey
        if (-not $SkipCursorRefresh) {
            Refresh-WindowsCursors
        }
        Write-Host "Restored default Windows mouse pointers (legacy install was active)." -ForegroundColor Green
    }
    else {
        Write-Host "No install manifest found and active cursors are customized or outside $InstallDir; preserving existing cursor settings." -ForegroundColor Yellow
    }

    if (Test-Path $schemesKey) {
        $schemesRegItem = Get-Item -Path $schemesKey -ErrorAction SilentlyContinue
        if ($schemesRegItem) {
            foreach ($valName in @($schemesRegItem.GetValueNames())) {
                if ([string]::IsNullOrEmpty($valName)) { continue }
                if (-not (Test-IsBibataSchemeName $valName)) { continue }
                $rawVal = [string]$schemesRegItem.GetValue($valName, "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $nonEmptyCount = 0
                $allLegacy = $true
                foreach ($pt in ($rawVal -split ',')) {
                    if ([string]::IsNullOrWhiteSpace($pt)) { continue }
                    $nonEmptyCount++
                    if (-not (Test-PathUnderAny $pt $legacyDirs)) { $allLegacy = $false; break }
                }
                if ($nonEmptyCount -gt 0 -and $allLegacy) {
                    Remove-ItemProperty -Path $schemesKey -Name $valName -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if (-not $KeepFiles) {
        foreach ($ld in $legacyDirs) {
            if (Test-Path -LiteralPath $ld) {
                Write-Host "Preserving unowned cursor folder without manifest: $ld (remove manually if unneeded)." -ForegroundColor Yellow
            }
        }
    }
}

# 3. Clean up managed trail files and manifest
if (-not $KeepFiles) {
    if ($shouldManageTrail -and (Test-Path -LiteralPath $trailDir -PathType Container)) {
        $trailFiles = @(Get-ChildItem -LiteralPath $trailDir -File -Recurse -Force -ErrorAction SilentlyContinue)
        foreach ($tf in $trailFiles) {
            if (-not (Try-RemoveFileStrict $tf.FullName $failedDeletions)) {
                $trailHasRemaining = $true
            }
        }
        $trailSubDirs = @(Get-ChildItem -LiteralPath $trailDir -Directory -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($tsd in $trailSubDirs) {
            if (-not (Try-RemoveEmptyDirStrict $tsd.FullName $failedDeletions)) {
                $trailHasRemaining = $true
            }
        }
        if (-not (Try-RemoveEmptyDirStrict $trailDir $failedDeletions)) {
            $trailHasRemaining = $true
        }
    }

    $rtSchemesCleanup = Join-Path $InstallDir "bibata-runtime-schemes.json"
    if (Test-Path -LiteralPath $rtSchemesCleanup -PathType Leaf) {
        Remove-Item -LiteralPath $rtSchemesCleanup -Force -ErrorAction SilentlyContinue
    }

    if ($failedDeletions.Count -gt 0) {
        if ($manifest) {
            $hasRemainingCursor = ($remainingManagedCursorFiles.Count -gt 0) -or ($remainingManagedCursorDirs.Count -gt 0) -or ($remainingManagedThemeDirs.Count -gt 0)
            if ($retryUseV1Manifest) {
                $retryManifest = [ordered]@{
                    schemaVersion       = 1
                    installDir          = $InstallDir
                    managedTrail        = $trailHasRemaining
                    trailExePath        = $trailExe
                    autoStartManaged    = $false
                    managedCursor       = $hasRemainingCursor
                    managedThemeDirs    = @($remainingManagedThemeDirs)
                    managedSchemes      = @()
                    previousCursorState = $null
                    updatedAt           = (Get-Date).ToString("o")
                }
            }
            else {
                $retryManifest = [ordered]@{
                    schemaVersion        = 2
                    installDir           = $InstallDir
                    managedTrail         = $trailHasRemaining
                    trailExePath         = $trailExe
                    autoStartManaged     = $false
                    managedCursor        = $hasRemainingCursor
                    managedThemeDirs     = @($remainingManagedThemeDirs)
                    managedCursorDirs    = @($remainingManagedCursorDirs)
                    managedCursorFiles   = @($remainingManagedCursorFiles)
                    managedSchemes       = @()
                    managedSchemeRecords = [ordered]@{}
                    previousCursorState  = $null
                    updatedAt            = (Get-Date).ToString("o")
                }
            }
            Set-Content -LiteralPath $manifestPath -Value ($retryManifest | ConvertTo-Json -Depth 6) -Encoding UTF8
        }

        $failedListMsg = New-Object System.Collections.Generic.List[string]
        foreach ($fd in $failedDeletions) {
            Write-Warning "Failed to delete $($fd.Path): $($fd.Reason)"
            $failedListMsg.Add("$($fd.Path) ($($fd.Reason))")
        }
        throw "Uninstall incomplete: failed to delete $($failedDeletions.Count) file(s)/folder(s): $($failedListMsg -join '; '). Manifest retained for retry after releasing handles."
    }

    if (Test-Path -LiteralPath $manifestPath) {
        Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $InstallDir) {
        $remaining = @(Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Cleaned up managed files under $InstallDir." -ForegroundColor Green
}

Write-Host "Uninstall complete." -ForegroundColor Cyan
