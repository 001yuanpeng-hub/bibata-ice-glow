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

$currentArrow = ""
$currentDefault = ""
if (Test-Path $cursorsKey) {
    $curItem = Get-Item -Path $cursorsKey -ErrorAction SilentlyContinue
    if ($curItem) {
        $aVal = $curItem.GetValue("Arrow", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -ne $aVal) { $currentArrow = [string]$aVal }
        $dVal = $curItem.GetValue("", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -ne $dVal) { $currentDefault = [string]$dVal }
    }
}

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
        $normCurArrow = Normalize-BibataPath $currentArrow
        $stillUsingOurs = ($managedFileNormSet.Contains($normCurArrow)) -or
            (Test-PathUnderAny $currentArrow $managedCursorDirs) -or
            (Test-PathUnderAny $currentArrow $managedDirs) -or
            (($managedSchemes -contains $currentDefault) -and (Test-PathUnderAny $currentArrow $possibleBibataDirs))

        if ($stillUsingOurs) {
            if ($manifest.previousCursorState -and $manifest.previousCursorState.existed) {
                Restore-CursorState $cursorsKey $manifest.previousCursorState
                Write-Host "Restored pre-install cursor configuration." -ForegroundColor Green
            }
            else {
                Restore-WindowsDefaultCursors $cursorsKey
                Write-Host "Restored default Windows mouse pointers." -ForegroundColor Green
            }
            if (-not $SkipCursorRefresh) {
                Refresh-WindowsCursors
            }
        }
        else {
            Write-Host "Current cursor scheme was changed by user ($currentDefault); keeping current cursor settings." -ForegroundColor Yellow
        }

        if (Test-Path $schemesKey) {
            $props = Get-ItemProperty -Path $schemesKey
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -in @("PSPath", "PSParentPath", "PSChildName", "PSDrive", "PSProvider")) { continue }
                $valStr = [string]$p.Value
                $firstPath = ($valStr -split ',')[0]
                $normFirst = Normalize-BibataPath $firstPath
                $isManagedScheme = ($managedFileNormSet.Contains($normFirst)) -or
                    (Test-PathUnderAny $firstPath $managedCursorDirs) -or
                    (Test-PathUnderAny $firstPath $managedDirs) -or
                    (($managedSchemes -contains $p.Name) -and (Test-PathUnderAny $firstPath $possibleBibataDirs))
                if ($isManagedScheme) {
                    Remove-ItemProperty -Path $schemesKey -Name $p.Name -ErrorAction SilentlyContinue
                }
            }
        }

        if (-not $KeepFiles) {
            if ($hasFileManifest) {
                foreach ($mf in $managedCursorFiles) {
                    $mfStr = [string]$mf
                    if (-not [string]::IsNullOrWhiteSpace($mfStr) -and (Test-Path -LiteralPath $mfStr -PathType Leaf)) {
                        Remove-Item -LiteralPath $mfStr -Force -ErrorAction SilentlyContinue
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
                            Remove-Item -LiteralPath $md -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
            else {
                # Legacy v1 manifest
                foreach ($md in $managedDirs) {
                    if (-not [string]::IsNullOrWhiteSpace($md) -and (Test-Path -LiteralPath $md)) {
                        Remove-Item -LiteralPath $md -Recurse -Force -ErrorAction SilentlyContinue
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
    if (Test-PathUnderAny $currentArrow $legacyDirs) {
        Restore-WindowsDefaultCursors $cursorsKey
        if (-not $SkipCursorRefresh) {
            Refresh-WindowsCursors
        }
        Write-Host "Restored default Windows mouse pointers (legacy install was active)." -ForegroundColor Green
    }
    else {
        Write-Host "No install manifest found and active cursors are outside $InstallDir; preserving existing cursor settings." -ForegroundColor Yellow
    }

    if (Test-Path $schemesKey) {
        $props = Get-ItemProperty -Path $schemesKey
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -in @("PSPath", "PSParentPath", "PSChildName", "PSDrive", "PSProvider")) { continue }
            $firstPath = ([string]$p.Value -split ',')[0]
            if (Test-PathUnderAny $firstPath $legacyDirs) {
                Remove-ItemProperty -Path $schemesKey -Name $p.Name -ErrorAction SilentlyContinue
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
    if ($shouldManageTrail -and (Test-Path -LiteralPath $trailDir)) {
        Remove-Item -LiteralPath $trailDir -Recurse -Force -ErrorAction SilentlyContinue
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
