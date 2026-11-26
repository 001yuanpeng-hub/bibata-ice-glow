[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [switch]$KeepFiles
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if (Test-Path "D:\Software\Cursors") {
        $InstallDir = "D:\Software\Cursors"
    }
    else {
        $InstallDir = Join-Path $env:LOCALAPPDATA "BibataIceGlow"
    }
}

# 1. Stop tray utility & remove auto-start
Get-Process -Name "BibataIceTrail" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Test-Path $runKey) {
    Remove-ItemProperty -Path $runKey -Name "BibataIceTrail" -ErrorAction SilentlyContinue
}
Write-Host "Stopped BibataIceTrail and removed auto-start entry." -ForegroundColor Green

# 2. Restore Windows default cursor scheme
$cursorsKey = "HKCU:\Control Panel\Cursors"
$schemesKey = "HKCU:\Control Panel\Cursors\Schemes"

if (Test-Path $cursorsKey) {
    Set-ItemProperty -Path $cursorsKey -Name "(Default)" -Value "Windows 默认"
    Set-ItemProperty -Path $cursorsKey -Name "Scheme Source" -Value 2 -Type DWord

    $defaults = @{
        Arrow       = "$env:SystemRoot\cursors\aero_arrow.cur"
        Help        = "$env:SystemRoot\cursors\aero_helpsel.cur"
        AppStarting = "$env:SystemRoot\cursors\aero_working.ani"
        Wait        = "$env:SystemRoot\cursors\aero_busy.ani"
        Crosshair   = ""
        IBeam       = ""
        NWPen       = "$env:SystemRoot\cursors\aero_pen.cur"
        No          = "$env:SystemRoot\cursors\aero_unavail.cur"
        SizeNS      = "$env:SystemRoot\cursors\aero_ns.cur"
        SizeWE      = "$env:SystemRoot\cursors\aero_ew.cur"
        SizeNWSE    = "$env:SystemRoot\cursors\aero_nwse.cur"
        SizeNESW    = "$env:SystemRoot\cursors\aero_nesw.cur"
        SizeAll     = "$env:SystemRoot\cursors\aero_move.cur"
        UpArrow     = "$env:SystemRoot\cursors\aero_up.cur"
        Hand        = "$env:SystemRoot\cursors\aero_link.cur"
    }
    foreach ($role in $defaults.Keys) {
        Set-ItemProperty -Path $cursorsKey -Name $role -Value $defaults[$role] -Type String
    }
    Remove-ItemProperty -Path $cursorsKey -Name "Pin" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $cursorsKey -Name "Person" -ErrorAction SilentlyContinue
}

if (Test-Path $schemesKey) {
    $props = Get-ItemProperty -Path $schemesKey
    foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -like "Bibata-*-Ice (*)") {
            Remove-ItemProperty -Path $schemesKey -Name $p.Name -ErrorAction SilentlyContinue
        }
    }
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BibataCursorRestore {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
}
"@ -ErrorAction SilentlyContinue | Out-Null
[BibataCursorRestore]::SystemParametersInfo(0x0057, 0, [IntPtr]::Zero, 0x02) | Out-Null
Write-Host "Restored default Windows mouse pointers." -ForegroundColor Green

# 3. Clean up installed files
if (-not $KeepFiles -and (Test-Path $InstallDir)) {
    $targets = @(
        (Join-Path $InstallDir "Bibata-Ice-Trail"),
        (Join-Path $InstallDir "Bibata-Modern-Ice"),
        (Join-Path $InstallDir "Bibata-Original-Ice")
    )
    foreach ($t in $targets) {
        if (Test-Path $t) {
            Remove-Item -Path $t -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $remaining = Get-ChildItem -Path $InstallDir -ErrorAction SilentlyContinue
    if (-not $remaining) {
        Remove-Item -Path $InstallDir -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Removed installed files under $InstallDir." -ForegroundColor Green
}

Write-Host "Uninstall complete." -ForegroundColor Cyan
