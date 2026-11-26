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

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Write-Host "Install directory: $InstallDir" -ForegroundColor Cyan

$manifestPath = Join-Path $InstallDir "bibata-ice-glow-manifest.json"
$prevManifest = $null
if (Test-Path $manifestPath) {
    try {
        $prevManifest = Get-Content -Path $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $prevManifest = $null
    }
}

$managedCursor = $false
$managedTrail = $false
$managedThemeDirs = New-Object System.Collections.Generic.List[string]
$managedSchemes = New-Object System.Collections.Generic.List[string]
$previousCursorState = $null
$prevTrailExePath = Join-Path (Join-Path $InstallDir "Bibata-Ice-Trail") "BibataIceTrail.exe"
$autoStartManaged = $false

if ($prevManifest) {
    if ($prevManifest.managedCursor) { $managedCursor = $true }
    if ($prevManifest.managedTrail) { $managedTrail = $true }
    if ($prevManifest.autoStartManaged) { $autoStartManaged = $true }
    if (-not [string]::IsNullOrWhiteSpace($prevManifest.trailExePath)) { $prevTrailExePath = [string]$prevManifest.trailExePath }
    if ($prevManifest.managedThemeDirs) {
        foreach ($d in $prevManifest.managedThemeDirs) {
            if (-not [string]::IsNullOrWhiteSpace($d) -and -not ($managedThemeDirs -contains $d)) {
                $managedThemeDirs.Add([string]$d)
            }
        }
    }
    if ($prevManifest.managedSchemes) {
        foreach ($s in $prevManifest.managedSchemes) {
            if (-not [string]::IsNullOrWhiteSpace($s) -and -not ($managedSchemes -contains $s)) {
                $managedSchemes.Add([string]$s)
            }
        }
    }
    if ($prevManifest.previousCursorState) {
        $previousCursorState = $prevManifest.previousCursorState
    }
}

# 1. Install Bibata Ice Windows cursor theme
if (-not $SkipCursor) {
    $themeName = "Bibata-$Style-Ice"
    $themeRoot = Join-Path $InstallDir $themeName
    $themeExistedBefore = Test-Path $themeRoot
    $zipUrl = "https://github.com/ful1e5/Bibata_Cursor/releases/latest/download/$themeName-Windows.zip"
    $zipPath = Join-Path $themeRoot "$themeName-Windows.zip"
    $sizeDirName = "$themeName-$Size-Windows"
    $cursorDir = Join-Path $themeRoot $sizeDirName
    $downloadedByUs = $false

    $cursorsKey = Join-Path $RegistryRoot "Control Panel\Cursors"
    $schemesKey = Join-Path $RegistryRoot "Control Panel\Cursors\Schemes"

    if ($null -eq $previousCursorState) {
        $previousCursorState = Snapshot-CursorState $cursorsKey
    }

    New-Item -ItemType Directory -Path $themeRoot -Force | Out-Null

    if (-not (Test-Path (Join-Path $cursorDir "Pointer.cur"))) {
        if (-not [string]::IsNullOrWhiteSpace($TestCursorZipPath) -and (Test-Path $TestCursorZipPath)) {
            Copy-Item -Path $TestCursorZipPath -Destination $zipPath -Force
        }
        else {
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
        $downloadedByUs = $true
    }
    else {
        Write-Host "Cursor files already present at $cursorDir" -ForegroundColor Green
    }

    $sizeDirs = Get-ChildItem -Path $themeRoot -Directory -Filter "$themeName-*-Windows" -ErrorAction SilentlyContinue
    if ($SingleSize) {
        foreach ($sd in $sizeDirs) {
            if ($sd.Name -ne $sizeDirName) {
                Remove-Item -Path $sd.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $sizeDirs = @($sizeDirs | Where-Object { $_.Name -eq $sizeDirName })
    }

    $unusedExtras = @("install.inf", "uninstall.bat", "Zoom-in.cur", "Zoom-out.cur", "Pan.cur", "Grabbing.cur")
    $hashTable = @{}
    foreach ($sd in $sizeDirs) {
        foreach ($ex in $unusedExtras) {
            $exPath = Join-Path $sd.FullName $ex
            if (Test-Path $exPath) {
                Remove-Item -Path $exPath -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $SingleSize) {
            $curFiles = Get-ChildItem -Path $sd.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 65536 }
            foreach ($cf in $curFiles) {
                $h = (Get-FileHash -Path $cf.FullName -Algorithm SHA256).Hash
                if ($hashTable.ContainsKey($h)) {
                    $target = $hashTable[$h]
                    $backup = "$($cf.FullName).dedup.tmp"
                    try {
                        Move-Item -Path $cf.FullName -Destination $backup -Force
                        New-Item -ItemType HardLink -Path $cf.FullName -Value $target -ErrorAction Stop | Out-Null
                        Remove-Item -Path $backup -Force -ErrorAction SilentlyContinue
                    }
                    catch {
                        if (Test-Path $backup) {
                            Move-Item -Path $backup -Destination $cf.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                else {
                    $hashTable[$h] = $cf.FullName
                }
            }
        }
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

    if (-not (Test-Path $schemesKey)) {
        New-Item -Path $schemesKey -Force | Out-Null
    }
    if (-not (Test-Path $cursorsKey)) {
        New-Item -Path $cursorsKey -Force | Out-Null
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

    if (-not $SkipCursorRefresh) {
        Refresh-WindowsCursors
    }

    $managedCursor = $true
    if (($downloadedByUs -or -not $themeExistedBefore) -and -not ($managedThemeDirs -contains $themeRoot)) {
        $managedThemeDirs.Add($themeRoot)
    }
    if (-not ($managedSchemes -contains $schemeName)) {
        $managedSchemes.Add($schemeName)
    }

    Write-Host "Applied cursor scheme: $schemeName" -ForegroundColor Green
}

# 2. Build, self-test in temp staging, and atomically upgrade/install BibataIceTrail
if (-not $SkipTrail) {
    $repoRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        $repoRoot = (Get-Location).Path
    }
    $srcCs = if (-not [string]::IsNullOrWhiteSpace($TestSourceOverride)) { $TestSourceOverride } else { Join-Path $repoRoot "src\BibataIceTrail.cs" }
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

    $stageDir = Join-Path $env:TEMP ("bibata_ice_stage_" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    $trailDir = Join-Path $InstallDir "Bibata-Ice-Trail"
    New-Item -ItemType Directory -Path $trailDir -Force | Out-Null
    $destCs = Join-Path $trailDir "BibataIceTrail.cs"
    $destExe = Join-Path $trailDir "BibataIceTrail.exe"

    $stagedCs = Join-Path $stageDir "BibataIceTrail.cs"
    $stagedExe = Join-Path $stageDir "BibataIceTrail.exe"
    $selfTestLog = Join-Path $stageDir "bibata_ice_trail_selftest.log"

    try {
        Copy-Item -Path $srcCs -Destination $stagedCs -Force

        Write-Host "Compiling candidate BibataIceTrail.exe in staging directory..." -ForegroundColor Yellow
        & $csc /nologo /target:winexe /platform:$platform /optimize+ /unsafe /warnaserror /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll "/out:$stagedExe" $stagedCs
        if ($LASTEXITCODE -ne 0) {
            throw "Candidate compilation failed with exit code $LASTEXITCODE; existing installation untouched."
        }

        $testProc = Start-Process -FilePath $stagedExe -ArgumentList "--self-test", $selfTestLog -Wait -PassThru
        if (Test-Path $selfTestLog) {
            $report = Get-Content -Path $selfTestLog -Raw
            Write-Host "Self-test: $($report.Trim())" -ForegroundColor Gray
        }
        if ($testProc.ExitCode -ne 0) {
            throw "Candidate BibataIceTrail --self-test failed with exit code $($testProc.ExitCode); existing installation untouched."
        }

        $runningProcs = @(Get-BibataProcessesByExe $destExe)
        $wasRunning = ($runningProcs.Count -gt 0)

        $exeBak = "$destExe.bak"
        $csBak = "$destCs.bak"
        if (Test-Path $destExe) { Copy-Item -Path $destExe -Destination $exeBak -Force }
        if (Test-Path $destCs) { Copy-Item -Path $destCs -Destination $csBak -Force }

        try {
            if ($wasRunning) {
                foreach ($rp in $runningProcs) {
                    Stop-Process -Id $rp.Id -Force -ErrorAction SilentlyContinue
                }
                Start-Sleep -Milliseconds 350
            }

            Copy-Item -Path $stagedCs -Destination $destCs -Force
            Copy-Item -Path $stagedExe -Destination $destExe -Force

            if (-not [string]::IsNullOrWhiteSpace($Palette)) {
                $paletteMap = @{
                    Ice      = "0"
                    Cyan     = "1"
                    Frost    = "2"
                    PinkBlue = "4"
                    Rainbow  = "5"
                }
                $pVal = $paletteMap[$Palette]
                $cfgPath = Join-Path $trailDir "config.ini"
                if (Test-Path $cfgPath) {
                    $lines = Get-Content -Path $cfgPath -Encoding UTF8
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
                    Set-Content -Path $cfgPath -Value $outLines -Encoding UTF8
                }
                else {
                    Set-Content -Path $cfgPath -Value @("[BibataIceTrail]", "Palette=$pVal") -Encoding UTF8
                }
                Write-Host "Configured palette: $Palette (Palette=$pVal)" -ForegroundColor Green
            }

            if (-not $NoAutoStart) {
                $runKey = Join-Path $RegistryRoot "Software\Microsoft\Windows\CurrentVersion\Run"
                if (-not (Test-Path $runKey)) {
                    New-Item -Path $runKey -Force | Out-Null
                }
                Set-ItemProperty -Path $runKey -Name "BibataIceTrail" -Value "`"$destExe`"" -Type String
                $autoStartManaged = $true
                Write-Host "Enabled login auto-start in Run registry." -ForegroundColor Green
            }

            if (-not $NoLaunch) {
                Start-BibataInstance -exePath $destExe -workDir $trailDir -extraArgs $LaunchArgs -NoTaskScheduler:$SkipTaskScheduler
                Write-Host "BibataIceTrail is running silently in the background (toggle with Ctrl+Alt+Shift+G)." -ForegroundColor Green
            }

            Remove-Item -Path $exeBak -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $csBak -Force -ErrorAction SilentlyContinue
            $managedTrail = $true
            $prevTrailExePath = $destExe
        }
        catch {
            Write-Warning "Upgrade replacement or launch failed; rolling back to previous version: $($_.Exception.Message)"
            if (Test-Path $csBak) {
                Copy-Item -Path $csBak -Destination $destCs -Force -ErrorAction SilentlyContinue
                Remove-Item -Path $csBak -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path $exeBak) {
                try {
                    Copy-Item -Path $exeBak -Destination $destExe -Force -ErrorAction Stop
                }
                catch {
                    Write-Warning "Could not overwrite locked target during rollback: $($_.Exception.Message)"
                }
                Remove-Item -Path $exeBak -Force -ErrorAction SilentlyContinue
            }
            if ($wasRunning -and (Test-Path $destExe)) {
                try {
                    Start-BibataInstance -exePath $destExe -workDir $trailDir -extraArgs $LaunchArgs -NoTaskScheduler:$SkipTaskScheduler
                    Write-Host "Restored and restarted previous BibataIceTrail version." -ForegroundColor Yellow
                }
                catch {
                    Write-Warning "Failed to restart previous BibataIceTrail version: $($_.Exception.Message)"
                }
            }
            throw
        }
    }
    finally {
        if (Test-Path $stageDir) {
            Remove-Item -Path $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$manifestObj = [ordered]@{
    schemaVersion       = 1
    installDir          = $InstallDir
    managedTrail        = $managedTrail
    trailExePath        = $prevTrailExePath
    autoStartManaged    = $autoStartManaged
    managedCursor       = $managedCursor
    managedThemeDirs    = @($managedThemeDirs)
    managedSchemes      = @($managedSchemes)
    previousCursorState = $previousCursorState
    updatedAt           = (Get-Date).ToString("o")
}
$manifestJson = $manifestObj | ConvertTo-Json -Depth 6
Set-Content -Path $manifestPath -Value $manifestJson -Encoding UTF8

Write-Host "Done! Enjoy Bibata-Modern-Ice + Ice Glow." -ForegroundColor Cyan
