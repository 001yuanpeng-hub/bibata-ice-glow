[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [ValidateSet("Modern", "Original")]
    [string]$Style = "Modern",
    [ValidateSet("Regular", "Large", "Extra-Large")]
    [string]$Size = "Regular",
    [switch]$SkipCursor,
    [switch]$SkipTrail,
    [switch]$NoAutoStart,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"

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

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if (Test-Path "D:\Software") {
        $InstallDir = "D:\Software\Cursors"
    }
    else {
        $InstallDir = Join-Path $env:LOCALAPPDATA "BibataIceGlow"
    }
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Write-Host "Install directory: $InstallDir" -ForegroundColor Cyan

# 1. Install Bibata Ice Windows cursor theme
if (-not $SkipCursor) {
    $themeName = "Bibata-$Style-Ice"
    $themeRoot = Join-Path $InstallDir $themeName
    $zipUrl = "https://github.com/ful1e5/Bibata_Cursor/releases/latest/download/$themeName-Windows.zip"
    $zipPath = Join-Path $themeRoot "$themeName-Windows.zip"
    $sizeDirName = "$themeName-$Size-Windows"
    $cursorDir = Join-Path $themeRoot $sizeDirName

    New-Item -ItemType Directory -Path $themeRoot -Force | Out-Null

    if (-not (Test-Path (Join-Path $cursorDir "Pointer.cur"))) {
        Write-Host "Downloading $themeName from GitHub Releases..." -ForegroundColor Yellow
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -L --fail --retry 3 -o $zipPath $zipUrl
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to download $zipUrl (curl exit $LASTEXITCODE)."
            }
        }
        else {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        }

        Write-Host "Extracting cursor package..." -ForegroundColor Yellow
        $prevProgress = $ProgressPreference
        $ProgressPreference = "SilentlyContinue"
        Expand-Archive -Path $zipPath -DestinationPath $themeRoot -Force
        $ProgressPreference = $prevProgress

        if (-not (Test-Path (Join-Path $cursorDir "Pointer.cur"))) {
            throw "Expected cursor directory not found after extraction: $cursorDir"
        }
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Host "Cursor files already present at $cursorDir" -ForegroundColor Green
    }

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

    $schemeName = "$themeName ($Size)"
    $schemesKey = "HKCU:\Control Panel\Cursors\Schemes"
    $cursorsKey = "HKCU:\Control Panel\Cursors"

    if (-not (Test-Path $schemesKey)) {
        New-Item -Path $schemesKey -Force | Out-Null
    }

    $schemePaths = New-Object System.Collections.Generic.List[string]
    foreach ($role in $roleMap.Keys) {
        $filePath = Join-Path $cursorDir $roleMap[$role]
        if (-not (Test-Path $filePath)) {
            throw "Missing cursor file for ${role}: $filePath"
        }
        $schemePaths.Add($filePath)
    }

    Set-ItemProperty -Path $schemesKey -Name $schemeName -Value ($schemePaths -join ",") -Type String
    Set-ItemProperty -Path $cursorsKey -Name "(Default)" -Value $schemeName
    Set-ItemProperty -Path $cursorsKey -Name "Scheme Source" -Value 1 -Type DWord
    foreach ($role in $roleMap.Keys) {
        Set-ItemProperty -Path $cursorsKey -Name $role -Value (Join-Path $cursorDir $roleMap[$role]) -Type String
    }

    Refresh-WindowsCursors
    Write-Host "Applied cursor scheme: $schemeName" -ForegroundColor Green
}

# 2. Build, test, and install BibataIceTrail
if (-not $SkipTrail) {
    $repoRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        $repoRoot = (Get-Location).Path
    }
    $srcCs = Join-Path $repoRoot "src\BibataIceTrail.cs"
    if (-not (Test-Path $srcCs)) {
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

    $trailDir = Join-Path $InstallDir "Bibata-Ice-Trail"
    New-Item -ItemType Directory -Path $trailDir -Force | Out-Null
    $destCs = Join-Path $trailDir "BibataIceTrail.cs"
    $destExe = Join-Path $trailDir "BibataIceTrail.exe"

    Get-Process -Name "BibataIceTrail" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300

    Copy-Item -Path $srcCs -Destination $destCs -Force

    Write-Host "Compiling BibataIceTrail.exe with .NET 4.x csc.exe..." -ForegroundColor Yellow
    & $csc /nologo /target:winexe /platform:$platform /optimize+ /unsafe /warnaserror /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /out:$destExe $destCs
    if ($LASTEXITCODE -ne 0) {
        throw "Compilation failed with exit code $LASTEXITCODE."
    }

    $selfTestLog = Join-Path $env:TEMP "bibata_ice_trail_selftest.log"
    if (Test-Path $selfTestLog) { Remove-Item $selfTestLog -Force }
    $testProc = Start-Process -FilePath $destExe -ArgumentList "--self-test", $selfTestLog -Wait -PassThru
    if (Test-Path $selfTestLog) {
        $report = Get-Content -Path $selfTestLog -Raw
        Remove-Item $selfTestLog -Force -ErrorAction SilentlyContinue
        Write-Host "Self-test: $($report.Trim())" -ForegroundColor Gray
    }
    if ($testProc.ExitCode -ne 0) {
        throw "BibataIceTrail --self-test failed with exit code $($testProc.ExitCode)."
    }

    if (-not $NoAutoStart) {
        $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        if (-not (Test-Path $runKey)) {
            New-Item -Path $runKey -Force | Out-Null
        }
        Set-ItemProperty -Path $runKey -Name "BibataIceTrail" -Value "`"$destExe`"" -Type String
        Write-Host "Enabled login auto-start in HKCU Run." -ForegroundColor Green
    }

    if (-not $NoLaunch) {
        $launched = $false
        try {
            $taskName = "BibataIceTrailOneShotLaunch"
            $action = New-ScheduledTaskAction -Execute $destExe -WorkingDirectory $trailDir
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            Start-Sleep -Seconds 1
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            $launched = $true
        }
        catch {
            $launched = $false
        }

        if (-not $launched) {
            Start-Process -FilePath $destExe -WorkingDirectory $trailDir
        }
        Write-Host "BibataIceTrail is running silently in the background (toggle with Ctrl+Alt+Shift+G)." -ForegroundColor Green
    }
}

Write-Host "Done! Enjoy Bibata-Modern-Ice + Ice Glow." -ForegroundColor Cyan
