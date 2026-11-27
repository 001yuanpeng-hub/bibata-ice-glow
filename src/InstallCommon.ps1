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

function Get-FileSha256([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "" }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
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

function Stop-BibataProcessesByExe([string]$targetExe) {
    foreach ($p in @(Get-BibataProcessesByExe $targetExe)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}

function Restore-CursorState([string]$cursorsPath, $prevState, [switch]$RemoveKeyIfNotExisted) {
    if (-not $prevState -or -not $prevState.existed) {
        if ($RemoveKeyIfNotExisted -and (Test-Path $cursorsPath)) {
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
