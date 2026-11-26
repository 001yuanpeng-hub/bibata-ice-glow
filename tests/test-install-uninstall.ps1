[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$installPs1 = Join-Path $repoRoot "install.ps1"
$uninstallPs1 = Join-Path $repoRoot "uninstall.ps1"

$guid = [Guid]::NewGuid().ToString("N").Substring(0, 10)
$testRoot = Join-Path $env:TEMP ("bibata_regtest_" + $guid)
$regRoot = "HKCU:\Software\BibataIceGlowRegTest_$guid"
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
New-Item -Path $regRoot -Force | Out-Null

function Get-FileSha256([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

function Get-BibataPidsByPath([string]$exePath) {
    $norm = [System.IO.Path]::GetFullPath($exePath).TrimEnd('\').ToLowerInvariant()
    $pids = New-Object System.Collections.Generic.List[int]
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'BibataIceTrail.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if ($p.ExecutablePath) {
            try {
                $pNorm = [System.IO.Path]::GetFullPath($p.ExecutablePath).TrimEnd('\').ToLowerInvariant()
                if ($pNorm -eq $norm) {
                    $pids.Add([int]$p.ProcessId)
                }
            }
            catch {
            }
        }
    }
    return @($pids)
}

function Stop-AllTestInstances([string]$dirRoot) {
    $norm = [System.IO.Path]::GetFullPath($dirRoot).TrimEnd('\').ToLowerInvariant()
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'BibataIceTrail.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if ($p.ExecutablePath) {
            try {
                $pNorm = [System.IO.Path]::GetFullPath($p.ExecutablePath).TrimEnd('\').ToLowerInvariant()
                if ($pNorm.StartsWith($norm, [StringComparison]::OrdinalIgnoreCase)) {
                    Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
            }
        }
    }
}

function Assert-True([bool]$cond, [string]$msg) {
    if (-not $cond) { throw "ASSERTION FAILED: $msg" }
}

function New-CursorFixtureZip([string]$zipOutPath) {
    $stage = Join-Path $testRoot "zip_fixture_stage"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    $roles = @(
        "Pointer.cur","Help.cur","Work.ani","Busy.ani","Cross.cur","Text.cur",
        "Handwriting.cur","Unavailable.cur","Vert.cur","Horz.cur","Dgn1.cur",
        "Dgn2.cur","Move.cur","Alternate.cur","Link.cur","Pin.cur","Person.cur",
        "install.inf","uninstall.bat","Zoom-in.cur"
    )
    $sharedAni = [byte[]](1..70000 | ForEach-Object { [byte]($_ % 251) })
    foreach ($sz in @("Regular","Large","Extra-Large")) {
        $d = Join-Path $stage ("Bibata-Modern-Ice-" + $sz + "-Windows")
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        foreach ($r in $roles) {
            $fp = Join-Path $d $r
            if (($r -eq "Busy.ani" -or $r -eq "Work.ani") -and ($sz -ne "Extra-Large")) {
                [System.IO.File]::WriteAllBytes($fp, $sharedAni)
            }
            else {
                [System.IO.File]::WriteAllText($fp, "$sz-$r")
            }
        }
    }
    if (Test-Path $zipOutPath) { Remove-Item $zipOutPath -Force }
    Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipOutPath -Force
}

$realExePath = "D:\Software\Cursors\Bibata-Ice-Trail\BibataIceTrail.exe"
$realPidsBefore = @(if (Test-Path $realExePath) { Get-BibataPidsByPath $realExePath } else { @() }) -join ","
$realArrowBefore = $null
$realCursorKey = Get-Item "HKCU:\Control Panel\Cursors" -ErrorAction SilentlyContinue
if ($realCursorKey) {
    $realArrowBefore = $realCursorKey.GetValue("Arrow", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}
$realRunBefore = $null
$realRunKey = Get-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue
if ($realRunKey) {
    $realRunBefore = $realRunKey.GetValue("BibataIceTrail", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

$lockProc = $null
try {
    # PowerShell syntax validation
    foreach ($psFile in @($installPs1, $uninstallPs1)) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($psFile, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-True ($errors.Count -eq 0) "PowerShell syntax error in $psFile"
    }
    Write-Host "PASS 0: PowerShell AST parse clean" -ForegroundColor Green

    $fixtureZip = Join-Path $testRoot "Bibata-Modern-Ice-Windows.zip"
    New-CursorFixtureZip $fixtureZip

    # =========================================================================
    # Case 1: Pre-existing Bibata-Modern-Ice + private files + pre-existing Large
    #         -> install missing Regular (also test -SingleSize) -> uninstall
    # =========================================================================
    $d1 = Join-Path $testRoot "case1_private_files"
    $r1 = Join-Path $regRoot "case1"
    $theme1 = Join-Path $d1 "Bibata-Modern-Ice"
    $large1 = Join-Path $theme1 "Bibata-Modern-Ice-Large-Windows"
    New-Item -ItemType Directory -Path $large1 -Force | Out-Null
    $privTxt = Join-Path $theme1 "my-existing-file.txt"
    $privInf = Join-Path $large1 "install.inf"
    $privCur = Join-Path $large1 "Pointer.cur"
    Set-Content -Path $privTxt -Value "private-keep-me" -Encoding UTF8
    Set-Content -Path $privInf -Value "private-inf" -Encoding UTF8
    Set-Content -Path $privCur -Value "user-large-pointer" -Encoding UTF8

    $c1 = Join-Path $r1 "Control Panel\Cursors"
    $s1 = Join-Path $c1 "Schemes"
    New-Item -Path $s1 -Force | Out-Null
    Set-ItemProperty -Path $c1 -Name "(Default)" -Value "OrigUserScheme" -Type String
    Set-ItemProperty -Path $c1 -Name "Scheme Source" -Value 1 -Type DWord
    Set-ItemProperty -Path $c1 -Name "Arrow" -Value "C:\PreExisting\orig.cur" -Type String

    & $installPs1 -InstallDir $d1 -Size Regular -SingleSize -NoLaunch -RegistryRoot $r1 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null

    Assert-True (Test-Path -LiteralPath $privTxt) "Case 1: Private file missing after install"
    Assert-True ((Get-Content -LiteralPath $privTxt -Raw).Trim() -eq "private-keep-me") "Case 1: Private file content altered"
    Assert-True (Test-Path -LiteralPath $large1) "Case 1: -SingleSize deleted pre-existing Large directory!"
    Assert-True (Test-Path -LiteralPath $privInf) "Case 1: Unused extra cleanup deleted pre-existing Large\install.inf!"
    Assert-True ((Get-Content -LiteralPath $privCur -Raw).Trim() -eq "user-large-pointer") "Case 1: Overwrote pre-existing Large\Pointer.cur!"
    Assert-True (Test-Path -LiteralPath (Join-Path $theme1 "Bibata-Modern-Ice-Regular-Windows\Pointer.cur")) "Case 1: Missing Regular cursor not installed"

    & $uninstallPs1 -InstallDir $d1 -RegistryRoot $r1 -SkipCursorRefresh | Out-Null

    Assert-True (Test-Path -LiteralPath $privTxt) "Case 1: Private file deleted on uninstall!"
    Assert-True (Test-Path -LiteralPath $large1) "Case 1: Pre-existing Large dir deleted on uninstall!"
    Assert-True (Test-Path -LiteralPath $privInf) "Case 1: Pre-existing Large\install.inf deleted on uninstall!"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $theme1 "Bibata-Modern-Ice-Regular-Windows"))) "Case 1: Newly added Regular dir not removed on uninstall"
    Assert-True ((Get-Item $c1).GetValue("", $null) -eq "OrigUserScheme") "Case 1: Pre-install cursor scheme not restored"
    Write-Host "PASS Case 1: Pre-existing theme dir private files & Large size preserved across SingleSize install + uninstall" -ForegroundColor Green

    # =========================================================================
    # Case 2: First-time full install with candidate --self-test failure -> zero cursor changes
    # =========================================================================
    $d2 = Join-Path $testRoot "case2_selftest_fail"
    $r2 = Join-Path $regRoot "case2"
    $c2 = Join-Path $r2 "Control Panel\Cursors"
    $s2 = Join-Path $c2 "Schemes"
    New-Item -Path $s2 -Force | Out-Null
    Set-ItemProperty -Path $c2 -Name "(Default)" -Value "CustomUserScheme" -Type String
    Set-ItemProperty -Path $c2 -Name "Scheme Source" -Value 1 -Type DWord
    Set-ItemProperty -Path $c2 -Name "Arrow" -Value "C:\MyCursors\custom_arrow.cur" -Type String
    Set-ItemProperty -Path $c2 -Name "Hand" -Value "C:\MyCursors\custom_hand.cur" -Type String
    Set-ItemProperty -Path $c2 -Name "Wait" -Value "%SystemRoot%\cursors\aero_busy.ani" -Type ExpandString

    $badSelfTestSrc = Join-Path $testRoot "BadSelfTest.cs"
    Set-Content -Path $badSelfTestSrc -Value "using System; class BadSelf { static int Main(string[] a) { return 7; } }" -Encoding UTF8

    $threw2 = $false
    try {
        & $installPs1 -InstallDir $d2 -Size Regular -RegistryRoot $r2 -SkipCursorRefresh -SkipTaskScheduler -TestSourceOverride $badSelfTestSrc -TestCursorZipPath $fixtureZip | Out-Null
    }
    catch {
        $threw2 = $true
    }
    Assert-True $threw2 "Case 2: Candidate self-test failure should have thrown"
    $curItem2 = Get-Item $c2
    Assert-True ($curItem2.GetValue("", $null) -eq "CustomUserScheme") "Case 2: Default scheme was overwritten before self-test!"
    Assert-True ($curItem2.GetValue("Arrow", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -eq "C:\MyCursors\custom_arrow.cur") "Case 2: Arrow was overwritten!"
    Assert-True ($curItem2.GetValue("Hand", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -eq "C:\MyCursors\custom_hand.cur") "Case 2: Hand was overwritten!"
    Assert-True ($curItem2.GetValue("Wait", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -eq "%SystemRoot%\cursors\aero_busy.ani") "Case 2: Wait was overwritten!"
    Assert-True ($null -eq $curItem2.GetValue("Pin", $null)) "Case 2: Pin was added!"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d2 "bibata-ice-glow-manifest.json"))) "Case 2: Manifest should not exist after failed first install"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d2 "Bibata-Modern-Ice"))) "Case 2: Cursor files should not exist after failed first install"
    Write-Host "PASS Case 2: First install self-test failure leaves user cursor scheme & roles untouched" -ForegroundColor Green

    # =========================================================================
    # Case 3a: Upgrade from Palette=0 + NoAutoStart with -Palette Rainbow + AutoStart
    #          -> candidate passes --self-test but fails normal launch -> full rollback
    # =========================================================================
    $d3 = Join-Path $testRoot "case3_upgrade_rollback"
    $r3 = Join-Path $regRoot "case3"
    $run3 = Join-Path $r3 "Software\Microsoft\Windows\CurrentVersion\Run"

    & $installPs1 -InstallDir $d3 -SkipCursor -NoAutoStart -Palette Ice -RegistryRoot $r3 -SkipCursorRefresh -SkipTaskScheduler -LaunchArgs "--instance-name RegCase3_$guid" | Out-Null

    $exe3 = Join-Path $d3 "Bibata-Ice-Trail\BibataIceTrail.exe"
    $cfg3 = Join-Path $d3 "Bibata-Ice-Trail\config.ini"
    Assert-True (Test-Path -LiteralPath $cfg3) "Case 3a: Initial config.ini missing"
    Assert-True ((Get-Content -LiteralPath $cfg3 -Raw) -match "Palette=0") "Case 3a: Initial Palette=0 missing"
    Assert-True ($null -eq (Get-ItemProperty -Path $run3 -Name "BibataIceTrail" -ErrorAction SilentlyContinue)) "Case 3a: Run entry should initially be absent"

    $exe3HashBefore = Get-FileSha256 $exe3
    $cfg3HashBefore = Get-FileSha256 $cfg3
    $pids3Before = @(Get-BibataPidsByPath $exe3)
    Assert-True ($pids3Before.Count -eq 1) "Case 3a: Initial instance not running"

    $failLaunchSrc = Join-Path $testRoot "FailLaunch.cs"
    Set-Content -Path $failLaunchSrc -Value @"
using System;
class FailLaunch {
    static int Main(string[] args) {
        if (args != null && args.Length > 0 && args[0] == "--self-test") return 0;
        return 1;
    }
}
"@ -Encoding UTF8

    $threw3a = $false
    try {
        & $installPs1 -InstallDir $d3 -SkipCursor -Palette Rainbow -RegistryRoot $r3 -SkipCursorRefresh -SkipTaskScheduler -TestSourceOverride $failLaunchSrc -LaunchArgs "--instance-name RegCase3_$guid" | Out-Null
    }
    catch {
        $threw3a = $true
    }
    Assert-True $threw3a "Case 3a: Launch failure should have thrown"
    Assert-True ((Get-FileSha256 $exe3) -eq $exe3HashBefore) "Case 3a: Old EXE hash mismatch after rollback!"
    Assert-True ((Get-FileSha256 $cfg3) -eq $cfg3HashBefore) "Case 3a: config.ini hash mismatch after rollback!"
    Assert-True ((Get-Content -LiteralPath $cfg3 -Raw) -match "Palette=0") "Case 3a: config.ini not rolled back to Palette=0!"
    Assert-True (-not (Test-Path -LiteralPath "$exe3.bak")) "Case 3a: exe.bak not cleaned after verified rollback"
    Assert-True (-not (Test-Path -LiteralPath "$cfg3.bak")) "Case 3a: config.ini.bak not cleaned after verified rollback"
    Assert-True ($null -eq (Get-ItemProperty -Path $run3 -Name "BibataIceTrail" -ErrorAction SilentlyContinue)) "Case 3a: Newly added Run entry not removed on rollback!"
    $pids3After = @(Get-BibataPidsByPath $exe3)
    Assert-True ($pids3After.Count -eq 1) "Case 3a: Old BibataIceTrail process not restarted after rollback!"
    foreach ($procId in $pids3After) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
    Write-Host "PASS Case 3a: Launch failure restores old EXE hash, config.ini hash, removes added Run entry, and restarts old EXE" -ForegroundColor Green

    # =========================================================================
    # Case 3b: Upgrade when config.ini did NOT exist and Run had a prior value -> rollback deletes config & restores Run
    # =========================================================================
    Remove-Item -LiteralPath $cfg3 -Force
    New-Item -Path $run3 -Force | Out-Null
    Set-ItemProperty -Path $run3 -Name "BibataIceTrail" -Value '"C:\Custom\Existing.exe" --flag' -Type String

    $threw3b = $false
    try {
        & $installPs1 -InstallDir $d3 -SkipCursor -NoLaunch:$false -Palette Rainbow -RegistryRoot $r3 -SkipCursorRefresh -SkipTaskScheduler -TestSourceOverride $failLaunchSrc -LaunchArgs "--instance-name RegCase3b_$guid" | Out-Null
    }
    catch {
        $threw3b = $true
    }
    Assert-True $threw3b "Case 3b: Launch failure should have thrown"
    Assert-True (-not (Test-Path -LiteralPath $cfg3)) "Case 3b: config.ini was created and NOT deleted on rollback!"
    Assert-True (((Get-Item $run3).GetValue("BibataIceTrail", $null)) -eq '"C:\Custom\Existing.exe" --flag') "Case 3b: Original Run value not restored!"
    Write-Host "PASS Case 3b: Rollback removes newly created config.ini and restores prior Run value" -ForegroundColor Green

    # =========================================================================
    # Case 4: Migration A -> B (with spaces) -> uninstall A keeps B's Run entry verbatim
    #         Also test missing-manifest A -> uninstall A still keeps B's Run entry verbatim
    # =========================================================================
    $dirA = Join-Path $testRoot "case4_dirA"
    $dirB = Join-Path $testRoot "case4 dir B with spaces"
    $r4 = Join-Path $regRoot "case4"
    $run4 = Join-Path $r4 "Software\Microsoft\Windows\CurrentVersion\Run"

    & $installPs1 -InstallDir $dirA -SkipCursor -NoLaunch -RegistryRoot $r4 -SkipCursorRefresh -SkipTaskScheduler | Out-Null
    & $installPs1 -InstallDir $dirB -SkipCursor -NoLaunch -RegistryRoot $r4 -SkipCursorRefresh -SkipTaskScheduler | Out-Null

    $expectedRunB = '"' + (Join-Path $dirB "Bibata-Ice-Trail\BibataIceTrail.exe") + '"'
    Assert-True (((Get-Item $run4).GetValue("BibataIceTrail", $null)) -eq $expectedRunB) "Case 4: Run does not point to B before uninstall A"

    & $uninstallPs1 -InstallDir $dirA -RegistryRoot $r4 -SkipCursorRefresh | Out-Null
    $actualRunAfterA = (Get-Item $run4).GetValue("BibataIceTrail", $null)
    Assert-True ($actualRunAfterA -eq $expectedRunB) "Case 4: Uninstalling A deleted or altered B's Run entry ($actualRunAfterA)!"

    # Repeat missing-manifest legacy uninstall of A2 while Run points to B (with unquoted + args edge case)
    $dirA2 = Join-Path $testRoot "case4_legacyA"
    New-Item -ItemType Directory -Path (Join-Path $dirA2 "Bibata-Ice-Trail") -Force | Out-Null
    Set-Content -Path (Join-Path $dirA2 "Bibata-Ice-Trail\BibataIceTrail.exe") -Value "dummy"
    $runWithArgsB = "$expectedRunB --show-tray"
    Set-ItemProperty -Path $run4 -Name "BibataIceTrail" -Value $runWithArgsB -Type String
    & $uninstallPs1 -InstallDir $dirA2 -RegistryRoot $r4 -SkipCursorRefresh | Out-Null
    Assert-True (((Get-Item $run4).GetValue("BibataIceTrail", $null)) -eq $runWithArgsB) "Case 4: Missing-manifest uninstall A deleted B's Run entry!"

    # Now uninstall B itself -> should remove B's Run entry cleanly (testing quoted + args parsing)
    & $uninstallPs1 -InstallDir $dirB -RegistryRoot $r4 -SkipCursorRefresh | Out-Null
    Assert-True ($null -eq (Get-ItemProperty -Path $run4 -Name "BibataIceTrail" -ErrorAction SilentlyContinue)) "Case 4: Uninstalling B did not remove B's own Run entry!"
    Write-Host "PASS Case 4: Uninstalling A preserves migrated B Run entry verbatim (with & without manifest/spaces/args)" -ForegroundColor Green

    # =========================================================================
    # Case 5: Full install where cursor applies, then trail launch fails -> Phase B rollback restores cursors & deletes cursor files
    # =========================================================================
    $d5 = Join-Path $testRoot "case5_cursor_then_trail_fail"
    $r5 = Join-Path $regRoot "case5"
    $c5 = Join-Path $r5 "Control Panel\Cursors"
    $s5 = Join-Path $c5 "Schemes"
    New-Item -Path $s5 -Force | Out-Null
    Set-ItemProperty -Path $c5 -Name "(Default)" -Value "UserOrig5" -Type String
    Set-ItemProperty -Path $c5 -Name "Scheme Source" -Value 1 -Type DWord
    Set-ItemProperty -Path $c5 -Name "Arrow" -Value "C:\Orig5\arrow.cur" -Type String

    $threw5 = $false
    try {
        & $installPs1 -InstallDir $d5 -Size Regular -RegistryRoot $r5 -SkipCursorRefresh -SkipTaskScheduler -TestSourceOverride $failLaunchSrc -TestCursorZipPath $fixtureZip | Out-Null
    }
    catch {
        $threw5 = $true
    }
    Assert-True $threw5 "Case 5: Expected launch failure"
    Assert-True ((Get-Item $c5).GetValue("", $null) -eq "UserOrig5") "Case 5: Cursor scheme not rolled back after trail launch failure"
    Assert-True ((Get-Item $c5).GetValue("Arrow", $null) -eq "C:\Orig5\arrow.cur") "Case 5: Arrow not rolled back"
    Assert-True ($null -eq (Get-ItemProperty -Path $s5 -Name "Bibata-Modern-Ice (Regular)" -ErrorAction SilentlyContinue)) "Case 5: Newly added scheme not rolled back"
    Assert-True (-not (Test-Path -LiteralPath $d5)) "Case 5: Newly created install dir not cleaned up after Phase B rollback"
    Write-Host "PASS Case 5: Phase B rollback cleans cursor files & restores cursor registry on late trail launch failure" -ForegroundColor Green

    # =========================================================================
    # Case 6: SkipCursor + third-party cursor preservation, user theme switch, and locked-EXE rollback
    # =========================================================================
    $d6 = Join-Path $testRoot "case6_skipcursor"
    $r6 = Join-Path $regRoot "case6"
    $tpDir = Join-Path $d6 "ThirdPartyTheme"
    New-Item -ItemType Directory -Path $tpDir -Force | Out-Null
    $tpArrow = Join-Path $tpDir "custom_arrow.cur"
    Set-Content -Path $tpArrow -Value "tp-arrow"
    $c6 = Join-Path $r6 "Control Panel\Cursors"
    $s6 = Join-Path $c6 "Schemes"
    New-Item -Path $s6 -Force | Out-Null
    Set-ItemProperty -Path $c6 -Name "(Default)" -Value "MyCustomTheme" -Type String
    Set-ItemProperty -Path $c6 -Name "Arrow" -Value $tpArrow -Type String

    & $installPs1 -InstallDir $d6 -SkipCursor -NoLaunch -RegistryRoot $r6 -SkipCursorRefresh -SkipTaskScheduler | Out-Null
    & $uninstallPs1 -InstallDir $d6 -RegistryRoot $r6 -SkipCursorRefresh | Out-Null
    Assert-True ((Get-Item $c6).GetValue("Arrow", $null) -eq $tpArrow) "Case 6a: Third-party cursor lost on SkipCursor uninstall"
    Assert-True (Test-Path -LiteralPath $tpArrow) "Case 6a: Third-party file deleted on SkipCursor uninstall"

    # Full install -> user switches scheme -> uninstall keeps user scheme
    $d7 = Join-Path $testRoot "case6_user_switch"
    $r7 = Join-Path $regRoot "case7"
    $c7 = Join-Path $r7 "Control Panel\Cursors"
    New-Item -Path (Join-Path $c7 "Schemes") -Force | Out-Null
    Set-ItemProperty -Path $c7 -Name "(Default)" -Value "Before7" -Type String
    Set-ItemProperty -Path $c7 -Name "Arrow" -Value "C:\Before7.cur" -Type String
    & $installPs1 -InstallDir $d7 -NoLaunch -RegistryRoot $r7 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    Set-ItemProperty -Path $c7 -Name "(Default)" -Value "UserNewTheme" -Type String
    Set-ItemProperty -Path $c7 -Name "Arrow" -Value "C:\UserNew\new.cur" -Type String
    & $uninstallPs1 -InstallDir $d7 -RegistryRoot $r7 -SkipCursorRefresh | Out-Null
    Assert-True ((Get-Item $c7).GetValue("Arrow", $null) -eq "C:\UserNew\new.cur") "Case 6b: User-switched cursor overwritten"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d7 "Bibata-Modern-Ice"))) "Case 6b: Managed Bibata dir not cleaned"

    # Locked EXE replacement failure -> rollback & restart old version
    $d8 = Join-Path $testRoot "case6_locked_exe"
    $r8 = Join-Path $regRoot "case8"
    & $installPs1 -InstallDir $d8 -SkipCursor -RegistryRoot $r8 -SkipCursorRefresh -SkipTaskScheduler -LaunchArgs "--instance-name RegCase8_$guid" | Out-Null
    $exe8 = Join-Path $d8 "Bibata-Ice-Trail\BibataIceTrail.exe"
    $hash8Before = Get-FileSha256 $exe8
    $lockScript = "`$fs = [System.IO.File]::Open('$exe8', 'Open', 'Read', 'Read'); Start-Sleep -Milliseconds 3000; `$fs.Close()"
    $lockProc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-Command", $lockScript -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 350
    $threw8 = $false
    try {
        & $installPs1 -InstallDir $d8 -SkipCursor -RegistryRoot $r8 -SkipCursorRefresh -SkipTaskScheduler -LaunchArgs "--instance-name RegCase8_$guid" | Out-Null
    }
    catch {
        $threw8 = $true
    }
    Assert-True $threw8 "Case 6c: Locked EXE replacement should throw"
    if ($lockProc -and -not $lockProc.HasExited) { $lockProc.WaitForExit(5000) | Out-Null }
    Assert-True ((Get-FileSha256 $exe8) -eq $hash8Before) "Case 6c: Locked EXE hash mismatch"
    Assert-True (-not (Test-Path -LiteralPath "$exe8.bak")) "Case 6c: exe.bak left behind"
    $pids8After = @(Get-BibataPidsByPath $exe8)
    Assert-True ($pids8After.Count -eq 1) "Case 6c: Old version not restarted after lock rollback"
    foreach ($procId in $pids8After) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
    Write-Host "PASS Case 6: SkipCursor, user theme switch, and locked EXE rollback all pass" -ForegroundColor Green

    # =========================================================================
    # Isolation check: real installation, cursor registry, and Run entry untouched
    # =========================================================================
    $realPidsAfter = @(if (Test-Path $realExePath) { Get-BibataPidsByPath $realExePath } else { @() }) -join ","
    $realArrowAfter = $null
    $realCursorKeyAfter = Get-Item "HKCU:\Control Panel\Cursors" -ErrorAction SilentlyContinue
    if ($realCursorKeyAfter) {
        $realArrowAfter = $realCursorKeyAfter.GetValue("Arrow", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    $realRunAfter = $null
    $realRunKeyAfter = Get-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue
    if ($realRunKeyAfter) {
        $realRunAfter = $realRunKeyAfter.GetValue("BibataIceTrail", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    Assert-True ($realPidsAfter -eq $realPidsBefore) "Isolation failed: real PID changed ($realPidsBefore -> $realPidsAfter)"
    Assert-True ($realArrowAfter -eq $realArrowBefore) "Isolation failed: real Arrow changed ($realArrowBefore -> $realArrowAfter)"
    Assert-True ($realRunAfter -eq $realRunBefore) "Isolation failed: real Run entry changed ($realRunBefore -> $realRunAfter)"
    Write-Host "PASS Isolation Check: Real PIDs=[$realPidsAfter], Arrow=[$realArrowAfter], Run=[$realRunAfter] untouched." -ForegroundColor Cyan
}
finally {
    if ($lockProc -and -not $lockProc.HasExited) { Stop-Process -Id $lockProc.Id -Force -ErrorAction SilentlyContinue }
    Stop-AllTestInstances $testRoot
    Start-Sleep -Milliseconds 200
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $regRoot) { Remove-Item -Path $regRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
