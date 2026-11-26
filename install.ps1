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

function Add-UniquePath($list, [string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return }
    $normP = Normalize-BibataPath $p
    foreach ($existing in $list) {
        if ((Normalize-BibataPath $existing) -eq $normP) { return }
    }
    $list.Add([string]$p)
}

function Get-FileSha256([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "" }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
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

Write-Host "Install directory: $InstallDir" -ForegroundColor Cyan

$manifestPath = Join-Path $InstallDir "bibata-ice-glow-manifest.json"
$prevManifest = $null
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $prevManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $prevManifest = $null
    }
}

$managedCursor = $false
$managedTrail = $false
$managedThemeDirs = New-Object System.Collections.Generic.List[string]
$managedCursorDirs = New-Object System.Collections.Generic.List[string]
$managedCursorFiles = New-Object System.Collections.Generic.List[string]
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
    if ($prevManifest.previousCursorState) {
        $previousCursorState = $prevManifest.previousCursorState
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

        if (-not (Test-Path -LiteralPath (Join-Path $cursorDir "Pointer.cur"))) {
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
            foreach ($role in $roleMap.Keys) {
                $rf = Join-Path $cursorDir $roleMap[$role]
                if (-not (Test-Path -LiteralPath $rf)) {
                    throw "Missing cursor file for ${role}: $rf"
                }
            }
            Write-Host "Cursor files already present at $cursorDir" -ForegroundColor Green
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
    $cursorRegistryApplied = $false

    if (-not $SkipCursor) {
        $themeExistedBefore = Test-Path -LiteralPath $themeRoot
        $cursorsStateBeforeThisRun = Snapshot-CursorState $cursorsKey
        if ($null -eq $previousCursorState) {
            $previousCursorState = $cursorsStateBeforeThisRun
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
    $exeBak = "$destExe.bak"
    $csBak = "$destCs.bak"
    $cfgBak = "$cfgPath.bak"
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
                    Copy-Item -LiteralPath $sf.FullName -Destination $dstFile -Force
                    if (-not $existed) {
                        Add-UniquePath $createdCursorFilesThisRun $dstFile
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

            $cursorRegistryApplied = $true
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
            if (-not $themeExistedBefore) {
                Add-UniquePath $managedThemeDirs $themeRoot
            }
            if (-not ($managedSchemes -contains $schemeName)) {
                $managedSchemes.Add($schemeName)
            }

            Write-Host "Applied cursor scheme: $schemeName" -ForegroundColor Green
        }

        if (-not $SkipTrail) {
            if (-not $trailDirExistedBefore) {
                New-Item -ItemType Directory -Path $trailDir -Force | Out-Null
            }

            if ($exeExistedBefore) { [System.IO.File]::Copy($destExe, $exeBak, $true) }
            if ($csExistedBefore) { [System.IO.File]::Copy($destCs, $csBak, $true) }
            if ($cfgExistedBefore) { [System.IO.File]::Copy($cfgPath, $cfgBak, $true) }

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
        }

        $manifestObj = [ordered]@{
            schemaVersion       = 2
            installDir          = $InstallDir
            managedTrail        = $managedTrail
            trailExePath        = $prevTrailExePath
            autoStartManaged    = $autoStartManaged
            managedCursor       = $managedCursor
            managedThemeDirs    = @($managedThemeDirs)
            managedCursorDirs   = @($managedCursorDirs)
            managedCursorFiles  = @($managedCursorFiles)
            managedSchemes      = @($managedSchemes)
            previousCursorState = $previousCursorState
            updatedAt           = (Get-Date).ToString("o")
        }
        $manifestJson = $manifestObj | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $manifestPath -Value $manifestJson -Encoding UTF8

        if (-not $SkipTrail) {
            if (Test-Path -LiteralPath $exeBak) { Remove-Item -LiteralPath $exeBak -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $csBak) { Remove-Item -LiteralPath $csBak -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $cfgBak) { Remove-Item -LiteralPath $cfgBak -Force -ErrorAction SilentlyContinue }
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
                    if (-not $SkipCursorRefresh) {
                        Refresh-WindowsCursors
                    }
                }
                catch {
                    Write-Warning "Failed to rollback cursor registry state: $($_.Exception.Message)"
                }
            }

            foreach ($cf in $createdCursorFilesThisRun) {
                if (Test-Path -LiteralPath $cf -PathType Leaf) {
                    Remove-Item -LiteralPath $cf -Force -ErrorAction SilentlyContinue
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
