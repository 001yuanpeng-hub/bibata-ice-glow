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
    if ($null -ne $prevState.schemeSource) {
        Set-ItemProperty -Path $cursorsPath -Name "Scheme Source" -Value ([int]$prevState.schemeSource) -Type DWord
    }
    if ($prevState.roles) {
        foreach ($prop in $prevState.roles.PSObject.Properties) {
            $roleName = $prop.Name
            $roleVal = $prop.Value
            if ($null -eq $roleVal) {
                Remove-ItemProperty -Path $cursorsPath -Name $roleName -ErrorAction SilentlyContinue
            }
            else {
                $valStr = [string]$roleVal
                $regType = if ($valStr -like "*%*") { "ExpandString" } else { "String" }
                Set-ItemProperty -Path $cursorsPath -Name $roleName -Value $valStr -Type $regType
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
if (Test-Path $manifestPath) {
    try {
        $manifest = Get-Content -Path $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
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

# 1. Stop only our BibataIceTrail instance and remove matching auto-start entry
Stop-BibataProcessesByExe $trailExe
Start-Sleep -Milliseconds 300

$runKey = Join-Path $RegistryRoot "Software\Microsoft\Windows\CurrentVersion\Run"
if (Test-Path $runKey) {
    $runItem = Get-ItemProperty -Path $runKey -Name "BibataIceTrail" -ErrorAction SilentlyContinue
    if ($runItem) {
        $runVal = [string]$runItem.BibataIceTrail
        if (-not $manifest -or $manifest.autoStartManaged -or ((Normalize-BibataPath $runVal) -eq (Normalize-BibataPath $trailExe))) {
            Remove-ItemProperty -Path $runKey -Name "BibataIceTrail" -ErrorAction SilentlyContinue
        }
    }
}
Write-Host "Stopped BibataIceTrail and cleaned matching auto-start entry." -ForegroundColor Green

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
        $managedSchemes = @()
        if ($manifest.managedSchemes) { $managedSchemes = @($manifest.managedSchemes) }

        # Fallback root check when managedDirs was empty (e.g., reused existing Bibata dir)
        $possibleBibataDirs = @(
            (Join-Path $InstallDir "Bibata-Modern-Ice"),
            (Join-Path $InstallDir "Bibata-Original-Ice")
        )
        $stillUsingOurs = (Test-PathUnderAny $currentArrow $managedDirs) -or
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
                if ((Test-PathUnderAny $firstPath $managedDirs) -or (($managedSchemes -contains $p.Name) -and (Test-PathUnderAny $firstPath $possibleBibataDirs))) {
                    Remove-ItemProperty -Path $schemesKey -Name $p.Name -ErrorAction SilentlyContinue
                }
            }
        }

        if (-not $KeepFiles) {
            foreach ($md in $managedDirs) {
                if (-not [string]::IsNullOrWhiteSpace($md) -and (Test-Path $md)) {
                    Remove-Item -Path $md -Recurse -Force -ErrorAction SilentlyContinue
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
            if (Test-Path $ld) {
                Write-Host "Preserving unowned cursor folder without manifest: $ld (remove manually if unneeded)." -ForegroundColor Yellow
            }
        }
    }
}

# 3. Clean up managed trail files and manifest
if (-not $KeepFiles) {
    $shouldRemoveTrail = (-not $manifest) -or ([bool]$manifest.managedTrail)
    if ($shouldRemoveTrail -and (Test-Path $trailDir)) {
        Remove-Item -Path $trailDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $manifestPath) {
        Remove-Item -Path $manifestPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $InstallDir) {
        $remaining = Get-ChildItem -Path $InstallDir -ErrorAction SilentlyContinue
        if (-not $remaining) {
            Remove-Item -Path $InstallDir -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Cleaned up managed files under $InstallDir." -ForegroundColor Green
}

Write-Host "Uninstall complete." -ForegroundColor Cyan
