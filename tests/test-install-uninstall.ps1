[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$installPs1 = Join-Path $repoRoot "install.ps1"
$uninstallPs1 = Join-Path $repoRoot "uninstall.ps1"
. (Join-Path $repoRoot "src\InstallCommon.ps1")

$guid = [Guid]::NewGuid().ToString("N").Substring(0, 10)
$canonicalTemp = Resolve-BibataAbsolutePath $env:TEMP
$testRoot = Join-Path $canonicalTemp ("bibata_regtest_" + $guid)
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

function New-CursorFixtureZip([string]$zipOutPath, [string]$Tag = "v1", [int]$AniSeed = 0, [switch]$AllSizesDistinctAni, [string[]]$Sizes = @("Regular","Large","Extra-Large")) {
    $stage = Join-Path $testRoot "zip_fixture_stage"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    $roles = @(
        "Pointer.cur","Help.cur","Work.ani","Busy.ani","Cross.cur","Text.cur",
        "Handwriting.cur","Unavailable.cur","Vert.cur","Horz.cur","Dgn1.cur",
        "Dgn2.cur","Move.cur","Alternate.cur","Link.cur","Pin.cur","Person.cur",
        "install.inf","uninstall.bat","Zoom-in.cur"
    )
    $sharedAni = [byte[]](1..70000 | ForEach-Object { [byte](($_ + $AniSeed) % 251) })
    foreach ($sz in $Sizes) {
        $d = Join-Path $stage ("Bibata-Modern-Ice-" + $sz + "-Windows")
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        foreach ($r in $roles) {
            $fp = Join-Path $d $r
            if (($r -eq "Busy.ani" -or $r -eq "Work.ani") -and ($AllSizesDistinctAni -or $sz -ne "Extra-Large")) {
                if ($AllSizesDistinctAni) {
                    $szOffset = switch ($sz) { "Regular" { 1 } "Large" { 7 } default { 19 } }
                    $distinctAni = [byte[]](1..70000 | ForEach-Object { [byte](($_ + $AniSeed + $szOffset) % 251) })
                    [System.IO.File]::WriteAllBytes($fp, $distinctAni)
                }
                else {
                    [System.IO.File]::WriteAllBytes($fp, $sharedAni)
                }
            }
            else {
                [System.IO.File]::WriteAllText($fp, "$Tag-$sz-$r")
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
    foreach ($psFile in @($installPs1, $uninstallPs1, (Join-Path $repoRoot 'src\InstallCommon.ps1'), (Join-Path $repoRoot 'src\InstallState.ps1'))) {
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
    $case1OrigArrow = Join-Path $testRoot "case1_orig.cur"
    Set-Content -Path $case1OrigArrow -Value "case1-orig-cur" -Encoding UTF8
    Set-ItemProperty -Path $c1 -Name "(Default)" -Value "OrigUserScheme" -Type String
    Set-ItemProperty -Path $c1 -Name "Scheme Source" -Value 1 -Type DWord
    Set-ItemProperty -Path $c1 -Name "Arrow" -Value $case1OrigArrow -Type String

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
    [IO.File]::WriteAllText("$cfg3.bak", "user backup from before the upgrade")
    $cfg3BackupHash = Get-FileSha256 "$cfg3.bak"
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
    Assert-True ((Get-FileSha256 "$cfg3.bak") -eq $cfg3BackupHash) "Case 3a: Rollback overwrote the user's config.ini.bak"
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
    foreach ($otherRole7 in @("Help", "AppStarting", "Wait", "Crosshair", "IBeam", "NWPen", "No", "SizeNS", "SizeWE", "SizeNWSE", "SizeNESW", "SizeAll", "UpArrow", "Hand", "Pin", "Person")) {
        Set-ItemProperty -Path $c7 -Name $otherRole7 -Value "" -Type String
    }
    & $uninstallPs1 -InstallDir $d7 -RegistryRoot $r7 -SkipCursorRefresh | Out-Null
    Assert-True ((Get-Item $c7).GetValue("Arrow", $null) -eq "C:\UserNew\new.cur") "Case 6b: User-switched cursor overwritten"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d7 "Bibata-Modern-Ice"))) "Case 6b: Managed Bibata dir not cleaned"

    # Locked EXE replacement failure -> rollback & restart old version
    $d8 = Join-Path $testRoot "case6_locked_exe"
    $r8 = Join-Path $regRoot "case8"
    & $installPs1 -InstallDir $d8 -SkipCursor -RegistryRoot $r8 -SkipCursorRefresh -SkipTaskScheduler -LaunchArgs "--instance-name RegCase8_$guid" | Out-Null
    $exe8 = Join-Path $d8 "Bibata-Ice-Trail\BibataIceTrail.exe"
    $hash8Before = Get-FileSha256 $exe8
    $lockStream8 = [System.IO.File]::Open($exe8, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $threw8 = $false
    try {
        & $installPs1 -InstallDir $d8 -SkipCursor -RegistryRoot $r8 -SkipCursorRefresh -SkipTaskScheduler -LaunchArgs "--instance-name RegCase8_$guid" | Out-Null
    }
    catch {
        $threw8 = $true
    }
    finally {
        $lockStream8.Dispose()
    }
    Assert-True $threw8 "Case 6c: Locked EXE replacement should throw"
    Assert-True ((Get-FileSha256 $exe8) -eq $hash8Before) "Case 6c: Locked EXE hash mismatch"
    Assert-True (-not (Test-Path -LiteralPath "$exe8.bak")) "Case 6c: exe.bak left behind"
    $pids8After = @(Get-BibataPidsByPath $exe8)
    Assert-True ($pids8After.Count -eq 1) "Case 6c: Old version not restarted after lock rollback"
    foreach ($procId in $pids8After) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
    Write-Host "PASS Case 6: SkipCursor, user theme switch, and locked EXE rollback all pass" -ForegroundColor Green

    # =========================================================================
    # Case 7 (Issue 1): Real v1 manifest (effba4d) uninstall must preserve personal-notes.txt
    # =========================================================================
    $d9 = Join-Path $testRoot "case7_v1_manifest"
    $r9 = Join-Path $regRoot "case9"
    $theme9 = Join-Path $d9 "Bibata-Modern-Ice"
    New-Item -ItemType Directory -Path $theme9 -Force | Out-Null
    $personalNotes = Join-Path $theme9 "personal-notes.txt"
    Set-Content -Path $personalNotes -Value "keep-these-v1-notes" -Encoding UTF8
    $c9 = Join-Path $r9 "Control Panel\Cursors"
    New-Item -Path (Join-Path $c9 "Schemes") -Force | Out-Null
    Set-ItemProperty -Path $c9 -Name "(Default)" -Value "OrigV1" -Type String
    Set-ItemProperty -Path $c9 -Name "Arrow" -Value "%SystemRoot%\cursors\aero_arrow.cur" -Type ExpandString

    $effba4dInstall = Join-Path $testRoot "effba4d_install.ps1"
    $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
    $gitExe = if ($gitCmd) { $gitCmd.Source } else { "D:\Project\Tools\Git\cmd\git.exe" }
    $generatedGenuineV1 = $false
    if (Test-Path $gitExe) {
        $v1ScriptBytes = & $gitExe -C $repoRoot show "effba4d:install.ps1" 2>$null
        $v1CsBytes = & $gitExe -C $repoRoot show "effba4d:src/BibataIceTrail.cs" 2>$null
        if ($LASTEXITCODE -eq 0 -and $v1ScriptBytes -and $v1CsBytes) {
            $effba4dCs = Join-Path $testRoot "effba4d_BibataIceTrail.cs"
            [System.IO.File]::WriteAllText($effba4dInstall, ($v1ScriptBytes -join "`r`n"), [System.Text.Encoding]::UTF8)
            [System.IO.File]::WriteAllText($effba4dCs, ($v1CsBytes -join "`r`n"), [System.Text.Encoding]::UTF8)
            & $effba4dInstall -InstallDir $d9 -Size Regular -NoLaunch -RegistryRoot $r9 -SkipCursorRefresh -SkipTaskScheduler -TestSourceOverride $effba4dCs -TestCursorZipPath $fixtureZip | Out-Null
            $generatedGenuineV1 = $true
        }
    }
    if (-not $generatedGenuineV1) {
        & $installPs1 -InstallDir $d9 -Size Regular -NoLaunch -RegistryRoot $r9 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
        $v1Fallback = [ordered]@{
            schemaVersion       = 1
            installDir          = $d9
            managedTrail        = $true
            trailExePath        = (Join-Path $d9 "Bibata-Ice-Trail\BibataIceTrail.exe")
            autoStartManaged    = $true
            managedCursor       = $true
            managedThemeDirs    = @($theme9)
            managedSchemes      = @("Bibata-Modern-Ice (Regular)")
            previousCursorState = [ordered]@{ existed = $true; defaultScheme = "OrigV1"; schemeSource = 2; roles = [ordered]@{ Arrow = "%SystemRoot%\cursors\aero_arrow.cur" } }
            updatedAt           = (Get-Date).ToString("o")
        }
        Set-Content -Path (Join-Path $d9 "bibata-ice-glow-manifest.json") -Value ($v1Fallback | ConvertTo-Json -Depth 6) -Encoding UTF8
    }

    $m9 = Get-Content -LiteralPath (Join-Path $d9 "bibata-ice-glow-manifest.json") -Raw | ConvertFrom-Json
    Assert-True ($m9.schemaVersion -eq 1) "Case 7: Expected v1 manifest from effba4d"
    Assert-True ($null -eq $m9.PSObject.Properties["managedCursorFiles"]) "Case 7: v1 manifest must not have managedCursorFiles"

    & $uninstallPs1 -InstallDir $d9 -RegistryRoot $r9 -SkipCursorRefresh | Out-Null
    Assert-True (Test-Path -LiteralPath $personalNotes) "Case 7: personal-notes.txt was deleted by v1 uninstall!"
    Assert-True ((Get-Content -LiteralPath $personalNotes -Raw).Trim() -eq "keep-these-v1-notes") "Case 7: personal-notes.txt content altered!"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $theme9 "Bibata-Modern-Ice-Regular-Windows\Pointer.cur"))) "Case 7: Known Bibata Regular cursor not cleaned in v1 uninstall"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $theme9 "Bibata-Modern-Ice-Regular-Windows"))) "Case 7: Empty Bibata size folder not removed in v1 uninstall"
    Assert-True ((Get-Item $c9).GetValue("", $null) -eq "OrigV1") "Case 7: Pre-install cursor scheme not restored"
    Write-Host "PASS Case 7: Real effba4d v1 manifest uninstall cleans known cursors while keeping personal-notes.txt" -ForegroundColor Green

    # =========================================================================
    # Case 8 (Issue 2): Migration A -> B -> uninstall A -> uninstall B restores orig custom theme,
    #                   plus fallback to Windows default if original custom files disappeared
    # =========================================================================
    $d10orig = Join-Path $testRoot "case8_orig_custom"
    New-Item -ItemType Directory -Path $d10orig -Force | Out-Null
    $origArrow = Join-Path $d10orig "orig_arrow.cur"
    $origHand = Join-Path $d10orig "orig_hand.cur"
    Set-Content -Path $origArrow -Value "orig-arrow" -Encoding UTF8
    Set-Content -Path $origHand -Value "orig-hand" -Encoding UTF8

    $d10A = Join-Path $testRoot "case8_dirA"
    $d10B = Join-Path $testRoot "case8_dirB"
    $r10 = Join-Path $regRoot "case10"
    $c10 = Join-Path $r10 "Control Panel\Cursors"
    New-Item -Path (Join-Path $c10 "Schemes") -Force | Out-Null
    Set-ItemProperty -Path $c10 -Name "(Default)" -Value "OrigCustomTheme8" -Type String
    Set-ItemProperty -Path $c10 -Name "Scheme Source" -Value 1 -Type DWord
    Set-ItemProperty -Path $c10 -Name "Arrow" -Value $origArrow -Type String
    Set-ItemProperty -Path $c10 -Name "Hand" -Value $origHand -Type String
    Set-ItemProperty -Path $c10 -Name "Wait" -Value "%SystemRoot%\cursors\aero_busy.ani" -Type ExpandString
    Set-ItemProperty -Path $c10 -Name "Crosshair" -Value "" -Type String
    Set-ItemProperty -Path $c10 -Name "IBeam" -Value "" -Type String

    & $installPs1 -InstallDir $d10A -NoLaunch -RegistryRoot $r10 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    & $installPs1 -InstallDir $d10B -NoLaunch -RegistryRoot $r10 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null

    # Uninstall A first: B must remain active and usable
    & $uninstallPs1 -InstallDir $d10A -RegistryRoot $r10 -SkipCursorRefresh | Out-Null
    $arrowAfterUninstA = (Get-Item $c10).GetValue("Arrow", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    Assert-True ($arrowAfterUninstA -like "*case8_dirB*Pointer.cur") "Case 8a: Uninstalling A disturbed active B cursor ($arrowAfterUninstA)"
    Assert-True (Test-Path -LiteralPath $arrowAfterUninstA -PathType Leaf) "Case 8a: Active B Pointer.cur missing after uninstalling A"

    # Now uninstall B: must restore OrigCustomTheme8 (inherited across A->B) and all role files must exist!
    & $uninstallPs1 -InstallDir $d10B -RegistryRoot $r10 -SkipCursorRefresh | Out-Null
    $curItem10 = Get-Item $c10
    Assert-True ($curItem10.GetValue("", $null) -eq "OrigCustomTheme8") "Case 8a: Did not restore original custom scheme after A->B migration"
    foreach ($roleCheck in @("Arrow", "Hand", "Wait")) {
        $rv = [string]$curItem10.GetValue($roleCheck, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        Assert-True (-not [string]::IsNullOrWhiteSpace($rv)) "Case 8a: Restored $roleCheck is empty"
        $exp = [Environment]::ExpandEnvironmentVariables($rv)
        Assert-True (Test-Path -LiteralPath $exp -PathType Leaf) "Case 8a: Restored $roleCheck target does not exist on disk ($rv -> $exp)"
    }
    Assert-True ($curItem10.GetValue("Arrow", $null) -eq $origArrow) "Case 8a: Restored Arrow mismatch"
    Assert-True ($curItem10.GetValue("Crosshair", $null) -eq "") "Case 8a: Crosshair empty string not preserved"

    # Case 8b: Fallback to Windows defaults when inherited original files are deleted before uninstall B
    & $installPs1 -InstallDir $d10A -NoLaunch -RegistryRoot $r10 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    & $installPs1 -InstallDir $d10B -NoLaunch -RegistryRoot $r10 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    & $uninstallPs1 -InstallDir $d10A -RegistryRoot $r10 -SkipCursorRefresh | Out-Null
    Remove-Item -LiteralPath $origArrow -Force
    & $uninstallPs1 -InstallDir $d10B -RegistryRoot $r10 -SkipCursorRefresh | Out-Null
    $arrowFallback = [string](Get-Item $c10).GetValue("Arrow", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    Assert-True ($arrowFallback -eq "%SystemRoot%\cursors\aero_arrow.cur") "Case 8b: Should fall back to Windows default aero_arrow.cur, got '$arrowFallback'"
    Assert-True (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($arrowFallback)) -PathType Leaf) "Case 8b: Fallback Windows default cursor file missing"
    Write-Host "PASS Case 8: Migration A->B->uninstall A->uninstall B restores valid custom theme or valid Windows defaults" -ForegroundColor Green

    # =========================================================================
    # Case 9 (Issue 3): Overwritten cursor files + hardlink sibling safety rollback when manifest locked
    # =========================================================================
    $oldZip9 = Join-Path $testRoot "cursor_old.zip"
    $newZip9 = Join-Path $testRoot "cursor_new.zip"
    New-CursorFixtureZip -zipOutPath $oldZip9 -Tag "oldpkg" -AniSeed 3
    New-CursorFixtureZip -zipOutPath $newZip9 -Tag "newpkg" -AniSeed 19 -AllSizesDistinctAni

    # Case 9a: Old Regular (-SingleSize) -> upgrade Large with newZip while manifest locked
    $d11 = Join-Path $testRoot "case9a_cursor_rollback"
    $r11 = Join-Path $regRoot "case11a"
    & $installPs1 -InstallDir $d11 -Size Regular -SingleSize -NoLaunch -RegistryRoot $r11 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $oldZip9 | Out-Null
    $regPtr11 = Join-Path $d11 "Bibata-Modern-Ice\Bibata-Modern-Ice-Regular-Windows\Pointer.cur"
    $regBusy11 = Join-Path $d11 "Bibata-Modern-Ice\Bibata-Modern-Ice-Regular-Windows\Busy.ani"
    $regPtrHashBefore = Get-FileSha256 $regPtr11
    $regBusyHashBefore = Get-FileSha256 $regBusy11
    $manifest11 = Join-Path $d11 "bibata-ice-glow-manifest.json"
    $lockStream11 = [System.IO.File]::Open($manifest11, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $threw11 = $false
    try {
        & $installPs1 -InstallDir $d11 -Size Large -NoLaunch -RegistryRoot $r11 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $newZip9 | Out-Null
    }
    catch {
        $threw11 = $true
    }
    finally {
        $lockStream11.Dispose()
    }
    Assert-True $threw11 "Case 9a: Locked manifest should fail upgrade"
    $c11 = Join-Path $r11 "Control Panel\Cursors"
    Assert-True ((Get-Item $c11).GetValue("", $null) -eq "Bibata-Modern-Ice (Regular)") "Case 9a: Active scheme did not roll back to Regular"
    Assert-True ((Get-FileSha256 $regPtr11) -eq $regPtrHashBefore) "Case 9a: Regular Pointer.cur was NOT rolled back to old content!"
    Assert-True ((Get-FileSha256 $regBusy11) -eq $regBusyHashBefore) "Case 9a: Regular Busy.ani was NOT rolled back to old content!"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d11 "Bibata-Modern-Ice\Bibata-Modern-Ice-Large-Windows"))) "Case 9a: Newly added Large directory was NOT cleaned up on rollback!"

    # Case 9b: Hardlink sibling safety across Regular & Large when Extra-Large triggers newZip overwrite + manifest lock
    $oldZipHL = Join-Path $testRoot "cursor_old_hl.zip"
    New-CursorFixtureZip -zipOutPath $oldZipHL -Tag "oldhl" -AniSeed 5 -Sizes @("Regular","Large")
    $d11b = Join-Path $testRoot "case9b_hardlink_rollback"
    $r11b = Join-Path $regRoot "case11b"
    & $installPs1 -InstallDir $d11b -Size Regular -NoLaunch -RegistryRoot $r11b -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $oldZipHL | Out-Null
    $hlRegBusy = Join-Path $d11b "Bibata-Modern-Ice\Bibata-Modern-Ice-Regular-Windows\Busy.ani"
    $hlLargeBusy = Join-Path $d11b "Bibata-Modern-Ice\Bibata-Modern-Ice-Large-Windows\Busy.ani"
    $hlRegHashBefore = Get-FileSha256 $hlRegBusy
    $hlLargeHashBefore = Get-FileSha256 $hlLargeBusy
    Assert-True ($hlRegHashBefore -eq $hlLargeHashBefore) "Case 9b: Expected shared initial Busy.ani bytes"

    $manifest11b = Join-Path $d11b "bibata-ice-glow-manifest.json"
    $lockStream11b = [System.IO.File]::Open($manifest11b, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $threw11b = $false
    try {
        & $installPs1 -InstallDir $d11b -Size Extra-Large -NoLaunch -RegistryRoot $r11b -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $newZip9 | Out-Null
    }
    catch {
        $threw11b = $true
    }
    finally {
        $lockStream11b.Dispose()
    }
    Assert-True $threw11b "Case 9b: Locked manifest should fail upgrade"
    Assert-True ((Get-FileSha256 $hlRegBusy) -eq $hlRegHashBefore) "Case 9b: Regular Busy.ani corrupted after hardlink rollback"
    Assert-True ((Get-FileSha256 $hlLargeBusy) -eq $hlLargeHashBefore) "Case 9b: Large Busy.ani corrupted after hardlink rollback"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d11b "Bibata-Modern-Ice\Bibata-Modern-Ice-Extra-Large-Windows"))) "Case 9b: Newly added Extra-Large folder not cleaned"
    Write-Host "PASS Case 9: Overwritten cursor files & NTFS hardlink siblings roll back with identical SHA-256" -ForegroundColor Green

    # =========================================================================
    # Case 10 (Issue 4): Pre-existing same-name scheme in Schemes & post-install manual edits
    # =========================================================================
    # 10a: Pre-existing ExpandString scheme -> install -> upgrade -> uninstall restores exact original value & kind
    $d12a = Join-Path $testRoot "case10a_scheme_restore"
    $r12a = Join-Path $regRoot "case12a"
    $c12a = Join-Path $r12a "Control Panel\Cursors"
    $s12a = Join-Path $c12a "Schemes"
    New-Item -Path $s12a -Force | Out-Null
    $origSchemeVal = "%SystemRoot%\cursors\aero_arrow.cur,%SystemRoot%\cursors\aero_helpsel.cur,,"
    Set-ItemProperty -Path $s12a -Name "Bibata-Modern-Ice (Regular)" -Value $origSchemeVal -Type ExpandString
    Set-ItemProperty -Path $c12a -Name "(Default)" -Value "Bibata-Modern-Ice (Regular)" -Type String
    Set-ItemProperty -Path $c12a -Name "Arrow" -Value "%SystemRoot%\cursors\aero_arrow.cur" -Type ExpandString

    & $installPs1 -InstallDir $d12a -Size Regular -NoLaunch -RegistryRoot $r12a -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    # Upgrade once more to verify original record is NOT overwritten by repeat install
    & $installPs1 -InstallDir $d12a -Size Regular -NoLaunch -RegistryRoot $r12a -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    & $uninstallPs1 -InstallDir $d12a -RegistryRoot $r12a -SkipCursorRefresh | Out-Null

    $s12aItem = Get-Item -Path $s12a
    $restoredScheme = $s12aItem.GetValue("Bibata-Modern-Ice (Regular)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $restoredKind = $s12aItem.GetValueKind("Bibata-Modern-Ice (Regular)").ToString()
    Assert-True ($restoredScheme -eq $origSchemeVal) "Case 10a: Pre-existing same-name scheme was not restored (got '$restoredScheme')"
    Assert-True ($restoredKind -eq "ExpandString") "Case 10a: Restored scheme registry kind changed ($restoredKind)"

    # 10b: Fresh install -> user manually edits "Bibata-Modern-Ice (Regular)" -> uninstall keeps user edit
    $d12b = Join-Path $testRoot "case10b_scheme_user_edit"
    $r12b = Join-Path $regRoot "case12b"
    $c12b = Join-Path $r12b "Control Panel\Cursors"
    $s12b = Join-Path $c12b "Schemes"
    New-Item -Path $s12b -Force | Out-Null
    & $installPs1 -InstallDir $d12b -Size Regular -NoLaunch -RegistryRoot $r12b -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $userEditedScheme = "C:\MyEditedCursors\arrow.cur,custom-edited"
    Set-ItemProperty -Path $s12b -Name "Bibata-Modern-Ice (Regular)" -Value $userEditedScheme -Type String
    & $uninstallPs1 -InstallDir $d12b -RegistryRoot $r12b -SkipCursorRefresh | Out-Null
    $actualAfterEdit = (Get-Item -Path $s12b).GetValue("Bibata-Modern-Ice (Regular)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    Assert-True ($actualAfterEdit -eq $userEditedScheme) "Case 10b: Manually edited same-name scheme was deleted/overwritten (got '$actualAfterEdit')"
    Write-Host "PASS Case 10: Pre-existing same-name scheme restored cleanly & manual post-install edits preserved" -ForegroundColor Green

    # =========================================================================
    # Case 11 (Commit 1 #1): Ctrl+Alt+Shift+S (CursorSizeManager) protects user's pre-existing Large scheme
    # =========================================================================
    $d13 = Join-Path $testRoot "case11_hotkey_scheme"
    $r13 = Join-Path $regRoot "case13"
    $c13 = Join-Path $r13 "Control Panel\Cursors"
    $s13 = Join-Path $c13 "Schemes"
    New-Item -Path $s13 -Force | Out-Null
    $origLargeSchemeVal = "%SystemRoot%\cursors\aero_arrow.cur,%SystemRoot%\cursors\aero_helpsel.cur,%SystemRoot%\cursors\aero_working.ani,,"
    Set-ItemProperty -Path $s13 -Name "Bibata-Modern-Ice (Large)" -Value $origLargeSchemeVal -Type ExpandString
    Set-ItemProperty -Path $c13 -Name "(Default)" -Value "OrigBefore11" -Type String
    Set-ItemProperty -Path $c13 -Name "Arrow" -Value "%SystemRoot%\cursors\aero_arrow.cur" -Type ExpandString

    & $installPs1 -InstallDir $d13 -Size Regular -NoLaunch -RegistryRoot $r13 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $exe13 = Join-Path $d13 "Bibata-Ice-Trail\BibataIceTrail.exe"
    $subKey13 = ($c13 -replace '^HKCU:\\', '')

    # Before cycling, Large scheme must remain untouched
    $largeBeforeCycle = (Get-Item -Path $s13).GetValue("Bibata-Modern-Ice (Large)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    Assert-True ($largeBeforeCycle -eq $origLargeSchemeVal) "Case 11a: Regular install altered pre-existing Large scheme"

    # Run actual compiled CursorSizeManager cycling: Regular -> Large -> Extra-Large -> Regular (redirected registry, no desktop refresh)
    foreach ($expectedSize in @("Large", "Extra-Large", "Regular")) {
        $cp = Start-Process -FilePath $exe13 -ArgumentList @("--cycle-cursor-size", "--cursors-reg-key", "`"$subKey13`"", "--no-refresh") -Wait -PassThru
        Assert-True ($cp.ExitCode -eq 0) "Case 11a: --cycle-cursor-size failed on step to $expectedSize (exit $($cp.ExitCode))"
        $curDef = (Get-Item -Path $c13).GetValue("", $null)
        Assert-True ($curDef -eq "Bibata-Modern-Ice ($expectedSize)") "Case 11a: Expected active scheme Bibata-Modern-Ice ($expectedSize), got '$curDef'"
    }
    # Cycle one more time to Large to verify repeated cycling does NOT overwrite the initial backup
    $cpRepeat = Start-Process -FilePath $exe13 -ArgumentList @("--cycle-cursor-size", "--cursors-reg-key", "`"$subKey13`"", "--no-refresh") -Wait -PassThru
    Assert-True ($cpRepeat.ExitCode -eq 0) "Case 11a: Repeat cycle to Large failed"

    & $uninstallPs1 -InstallDir $d13 -RegistryRoot $r13 -SkipCursorRefresh | Out-Null
    $s13Item = Get-Item -Path $s13
    $restoredLarge = $s13Item.GetValue("Bibata-Modern-Ice (Large)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $restoredLargeKind = $s13Item.GetValueKind("Bibata-Modern-Ice (Large)").ToString()
    Assert-True ($restoredLarge -eq $origLargeSchemeVal) "Case 11a: Large scheme not restored after hotkey cycling + uninstall (got '$restoredLarge')"
    Assert-True ($restoredLargeKind -eq "ExpandString") "Case 11a: Large scheme registry kind not restored ($restoredLargeKind)"
    Assert-True ($null -eq $s13Item.GetValue("Bibata-Modern-Ice (Extra-Large)", $null)) "Case 11a: Originally absent Extra-Large scheme was not cleaned up"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d13 "bibata-runtime-schemes.json"))) "Case 11a: Runtime scheme sidecar not cleaned up"

    # Case 11b: User manually edits Large scheme after hotkey cycling -> uninstall preserves user edit
    $d13b = Join-Path $testRoot "case11b_hotkey_user_edit"
    $r13b = Join-Path $regRoot "case13b"
    $c13b = Join-Path $r13b "Control Panel\Cursors"
    $s13b = Join-Path $c13b "Schemes"
    New-Item -Path $s13b -Force | Out-Null
    Set-ItemProperty -Path $s13b -Name "Bibata-Modern-Ice (Large)" -Value $origLargeSchemeVal -Type ExpandString
    & $installPs1 -InstallDir $d13b -Size Regular -NoLaunch -RegistryRoot $r13b -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $exe13b = Join-Path $d13b "Bibata-Ice-Trail\BibataIceTrail.exe"
    $subKey13b = ($c13b -replace '^HKCU:\\', '')
    $cp13b = Start-Process -FilePath $exe13b -ArgumentList @("--cycle-cursor-size", "--cursors-reg-key", "`"$subKey13b`"", "--no-refresh") -Wait -PassThru
    Assert-True ($cp13b.ExitCode -eq 0) "Case 11b: Cycle to Large failed"
    $userEditLarge = "%SystemRoot%\cursors\aero_arrow.cur,%SystemRoot%\cursors\aero_link.cur,,"
    Set-ItemProperty -Path $s13b -Name "Bibata-Modern-Ice (Large)" -Value $userEditLarge -Type String
    & $uninstallPs1 -InstallDir $d13b -RegistryRoot $r13b -SkipCursorRefresh | Out-Null
    $actualEditLarge = (Get-Item -Path $s13b).GetValue("Bibata-Modern-Ice (Large)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    Assert-True ($actualEditLarge -eq $userEditLarge) "Case 11b: User edit on Large scheme lost on uninstall (got '$actualEditLarge')"

    # Case 11c: Backup file locked -> hotkey cycle must NOT overwrite user's pre-existing Large scheme
    $d13c = Join-Path $testRoot "case11c_hotkey_backup_locked"
    $r13c = Join-Path $regRoot "case13c"
    $c13c = Join-Path $r13c "Control Panel\Cursors"
    $s13c = Join-Path $c13c "Schemes"
    New-Item -Path $s13c -Force | Out-Null
    Set-ItemProperty -Path $s13c -Name "Bibata-Modern-Ice (Large)" -Value $origLargeSchemeVal -Type ExpandString
    & $installPs1 -InstallDir $d13c -Size Regular -NoLaunch -RegistryRoot $r13c -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $exe13c = Join-Path $d13c "Bibata-Ice-Trail\BibataIceTrail.exe"
    $subKey13c = ($c13c -replace '^HKCU:\\', '')
    $rtLockPath = Join-Path $d13c "bibata-runtime-schemes.json"
    Set-Content -Path $rtLockPath -Value "[]" -Encoding UTF8
    $lockScript13c = "`$fs = [System.IO.File]::Open('$rtLockPath', 'Open', 'ReadWrite', 'None'); Start-Sleep -Milliseconds 3000; `$fs.Close()"
    $lockProc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-Command", $lockScript13c -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 350
    $cp13c = Start-Process -FilePath $exe13c -ArgumentList @("--cycle-cursor-size", "--cursors-reg-key", "`"$subKey13c`"", "--no-refresh") -Wait -PassThru
    if ($lockProc -and -not $lockProc.HasExited) { $lockProc.WaitForExit(5000) | Out-Null }
    $largeAfterLocked = (Get-Item -Path $s13c).GetValue("Bibata-Modern-Ice (Large)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    Assert-True ($largeAfterLocked -eq $origLargeSchemeVal) "Case 11c: Locked backup still allowed overwriting user's Large scheme (got '$largeAfterLocked')"
    Write-Host "PASS Case 11: Ctrl+Alt+Shift+S protects pre-existing Large scheme, preserves edits, and guards on backup failure" -ForegroundColor Green

    # =========================================================================
    # Case 12 (Commit 1 #2): A -> B migration protects Schemes (with & without original scheme, and manual edit)
    # =========================================================================
    $d14orig = Join-Path $testRoot "case12_orig_custom"
    New-Item -ItemType Directory -Path $d14orig -Force | Out-Null
    $c12Arrow = Join-Path $d14orig "custom_arrow.cur"
    $c12Hand = Join-Path $d14orig "custom_hand.cur"
    Set-Content -Path $c12Arrow -Value "c12-arrow" -Encoding UTF8
    Set-Content -Path $c12Hand -Value "c12-hand" -Encoding UTF8

    # 12a: Pre-existing valid ExpandString Regular scheme -> install A -> install B -> uninstall A -> uninstall B
    $d14A = Join-Path $testRoot "case12a_dirA"
    $d14B = Join-Path $testRoot "case12a_dirB"
    $r14a = Join-Path $regRoot "case14a"
    $c14a = Join-Path $r14a "Control Panel\Cursors"
    $s14a = Join-Path $c14a "Schemes"
    New-Item -Path $s14a -Force | Out-Null
    $origRegScheme12 = "$c12Arrow,%SystemRoot%\cursors\aero_helpsel.cur,,$c12Hand"
    Set-ItemProperty -Path $s14a -Name "Bibata-Modern-Ice (Regular)" -Value $origRegScheme12 -Type ExpandString
    Set-ItemProperty -Path $c14a -Name "(Default)" -Value "OrigCustom12" -Type String
    Set-ItemProperty -Path $c14a -Name "Arrow" -Value $c12Arrow -Type String

    & $installPs1 -InstallDir $d14A -Size Regular -NoLaunch -RegistryRoot $r14a -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    & $installPs1 -InstallDir $d14B -Size Regular -NoLaunch -RegistryRoot $r14a -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    & $uninstallPs1 -InstallDir $d14A -RegistryRoot $r14a -SkipCursorRefresh | Out-Null

    # After uninstalling A, B must remain active & Schemes must point to B (existing files)
    $bArrow14a = (Get-Item -Path $c14a).GetValue("Arrow", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $bScheme14a = (Get-Item -Path $s14a).GetValue("Bibata-Modern-Ice (Regular)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    Assert-True ($bArrow14a -like "*case12a_dirB*Pointer.cur" -and (Test-Path -LiteralPath $bArrow14a -PathType Leaf)) "Case 12a: B Arrow broken after uninstall A"
    Assert-True ($bScheme14a -like "*case12a_dirB*Pointer.cur*") "Case 12a: B Schemes definition disturbed after uninstall A"

    & $uninstallPs1 -InstallDir $d14B -RegistryRoot $r14a -SkipCursorRefresh | Out-Null
    $c14aItem = Get-Item -Path $c14a
    $s14aItem = Get-Item -Path $s14a
    $finalArrow14a = $c14aItem.GetValue("Arrow", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $finalScheme14a = $s14aItem.GetValue("Bibata-Modern-Ice (Regular)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $finalSchemeKind14a = $s14aItem.GetValueKind("Bibata-Modern-Ice (Regular)").ToString()
    Assert-True ($finalArrow14a -eq $c12Arrow -and (Test-Path -LiteralPath $finalArrow14a -PathType Leaf)) "Case 12a: Final Arrow not restored to valid custom file"
    Assert-True ($finalScheme14a -eq $origRegScheme12) "Case 12a: Schemes Regular restored to wrong value ('$finalScheme14a' != '$origRegScheme12')"
    Assert-True ($finalSchemeKind14a -eq "ExpandString") "Case 12a: Schemes Regular kind mismatch ($finalSchemeKind14a)"
    foreach ($seg in ($finalScheme14a -split ',')) {
        if (-not [string]::IsNullOrWhiteSpace($seg)) {
            $expSeg = [Environment]::ExpandEnvironmentVariables($seg.Trim())
            Assert-True (Test-Path -LiteralPath $expSeg -PathType Leaf) "Case 12a: Restored scheme file missing on disk: $expSeg"
        }
    }

    # 12b: Originally NO Regular scheme -> install A -> install B -> uninstall A -> uninstall B -> no dead Regular scheme left
    $d14bA = Join-Path $testRoot "case12b_dirA"
    $d14bB = Join-Path $testRoot "case12b_dirB"
    $r14b = Join-Path $regRoot "case14b"
    $c14b = Join-Path $r14b "Control Panel\Cursors"
    $s14b = Join-Path $c14b "Schemes"
    New-Item -Path $s14b -Force | Out-Null
    Set-ItemProperty -Path $c14b -Name "(Default)" -Value "" -Type String
    Set-ItemProperty -Path $c14b -Name "Arrow" -Value "%SystemRoot%\cursors\aero_arrow.cur" -Type ExpandString

    & $installPs1 -InstallDir $d14bA -Size Regular -NoLaunch -RegistryRoot $r14b -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    & $installPs1 -InstallDir $d14bB -Size Regular -NoLaunch -RegistryRoot $r14b -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    & $uninstallPs1 -InstallDir $d14bA -RegistryRoot $r14b -SkipCursorRefresh | Out-Null
    & $uninstallPs1 -InstallDir $d14bB -RegistryRoot $r14b -SkipCursorRefresh | Out-Null
    $leftover14b = (Get-Item -Path $s14b).GetValue("Bibata-Modern-Ice (Regular)", $null)
    Assert-True ($null -eq $leftover14b) "Case 12b: Originally absent Regular scheme left dead entry '$leftover14b' after A->B uninstall!"

    # 12c: User manually edits Regular scheme after installing A, before installing B -> B inherits user's edit, NOT A's pre-install state
    $d14cA = Join-Path $testRoot "case12c_dirA"
    $d14cB = Join-Path $testRoot "case12c_dirB"
    $r14c = Join-Path $regRoot "case14c"
    $c14c = Join-Path $r14c "Control Panel\Cursors"
    $s14c = Join-Path $c14c "Schemes"
    New-Item -Path $s14c -Force | Out-Null
    Set-ItemProperty -Path $c14c -Name "Arrow" -Value "%SystemRoot%\cursors\aero_arrow.cur" -Type ExpandString
    & $installPs1 -InstallDir $d14cA -Size Regular -NoLaunch -RegistryRoot $r14c -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $manualMidEdit = "$c12Hand,%SystemRoot%\cursors\aero_arrow.cur,,"
    Set-ItemProperty -Path $s14c -Name "Bibata-Modern-Ice (Regular)" -Value $manualMidEdit -Type ExpandString
    & $installPs1 -InstallDir $d14cB -Size Regular -NoLaunch -RegistryRoot $r14c -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    & $uninstallPs1 -InstallDir $d14cA -RegistryRoot $r14c -SkipCursorRefresh | Out-Null
    & $uninstallPs1 -InstallDir $d14cB -RegistryRoot $r14c -SkipCursorRefresh | Out-Null
    $final14c = (Get-Item -Path $s14c).GetValue("Bibata-Modern-Ice (Regular)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    Assert-True ($final14c -eq $manualMidEdit) "Case 12c: User's manual scheme edit between A and B was lost (got '$final14c')"
    Write-Host "PASS Case 12: A->B migration inherits Schemes cleanly, leaves no dead entries, and preserves user edits" -ForegroundColor Green

    # =========================================================================
    # Case 13 (Commit 2 #3): Relative -InstallDir .\portable resolves against caller CWD (with spaces)
    # =========================================================================
    $cwd13 = Join-Path $testRoot "case13 work dir with spaces"
    $otherCwd13 = Join-Path $testRoot "case13 other cwd"
    New-Item -ItemType Directory -Path $cwd13 -Force | Out-Null
    New-Item -ItemType Directory -Path $otherCwd13 -Force | Out-Null
    $r13rel = Join-Path $regRoot "case13rel"
    $c13rel = Join-Path $r13rel "Control Panel\Cursors"
    $run13rel = Join-Path $r13rel "Software\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path (Join-Path $c13rel "Schemes") -Force | Out-Null
    Set-ItemProperty -Path $c13rel -Name "Arrow" -Value "%SystemRoot%\cursors\aero_arrow.cur" -Type ExpandString
    $expectedAbs13 = Join-Path $cwd13 "portable"

    Push-Location -LiteralPath $cwd13
    try {
        & $installPs1 -InstallDir ".\portable" -Size Regular -NoLaunch -RegistryRoot $r13rel -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null

        # Switch to a completely different working directory and verify every registered/manifest path is absolute & valid
        Set-Location -LiteralPath $otherCwd13
        $arrow13 = [string](Get-Item -Path $c13rel).GetValue("Arrow", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $runVal13 = [string](Get-Item -Path $run13rel).GetValue("BibataIceTrail", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $runExe13 = $runVal13.Trim('"')
        Assert-True ([System.IO.Path]::IsPathRooted($arrow13)) "Case 13: Arrow in registry is not rooted ($arrow13)"
        Assert-True ($arrow13.StartsWith($expectedAbs13 + "\", [StringComparison]::OrdinalIgnoreCase)) "Case 13: Arrow does not point under expected abs dir ($arrow13)"
        Assert-True (Test-Path -LiteralPath $arrow13 -PathType Leaf) "Case 13: Arrow target file not found from other CWD ($arrow13)"
        Assert-True ([System.IO.Path]::IsPathRooted($runExe13)) "Case 13: Run entry is not rooted ($runVal13)"
        Assert-True ($runExe13.StartsWith($expectedAbs13 + "\", [StringComparison]::OrdinalIgnoreCase)) "Case 13: Run entry does not point under expected abs dir ($runVal13)"
        Assert-True (Test-Path -LiteralPath $runExe13 -PathType Leaf) "Case 13: Run target EXE not found from other CWD ($runExe13)"

        $m13 = Get-Content -LiteralPath (Join-Path $expectedAbs13 "bibata-ice-glow-manifest.json") -Raw | ConvertFrom-Json
        Assert-True ($m13.installDir -eq $expectedAbs13) "Case 13: Manifest installDir not canonical abs ($($m13.installDir))"
        Assert-True ([System.IO.Path]::IsPathRooted([string]$m13.trailExePath)) "Case 13: Manifest trailExePath not rooted"
        foreach ($mp in (@($m13.managedThemeDirs) + @($m13.managedCursorDirs) + @($m13.managedCursorFiles))) {
            Assert-True ([System.IO.Path]::IsPathRooted([string]$mp)) "Case 13: Managed path in manifest is relative: $mp"
        }

        # Uninstall using relative path from original working directory
        Set-Location -LiteralPath $cwd13
        & $uninstallPs1 -InstallDir ".\portable" -RegistryRoot $r13rel -SkipCursorRefresh | Out-Null
        Assert-True (-not (Test-Path -LiteralPath $expectedAbs13)) "Case 13: Relative-path uninstall did not clean portable dir"
        Assert-True ($null -eq (Get-ItemProperty -Path $run13rel -Name "BibataIceTrail" -ErrorAction SilentlyContinue)) "Case 13: Relative-path uninstall did not clean Run entry"
    }
    finally {
        Pop-Location
    }
    Write-Host "PASS Case 13: Relative -InstallDir resolves to absolute path across registry/Run/manifest and uninstalls cleanly" -ForegroundColor Green

    # =========================================================================
    # Case 14 (Commit 2 #4): Reinstall sizing (3->1, 1->3), missing Help.cur repair, private files in extra dir, idempotency & rollback
    # =========================================================================
    $d14sz = Join-Path $testRoot "case14_reinstall_sizing"
    $r14sz = Join-Path $regRoot "case14sz"
    New-Item -Path (Join-Path $r14sz "Control Panel\Cursors\Schemes") -Force | Out-Null

    # 14a: 3 sizes -> drop private file in Large -> reinstall with -SingleSize (3->1) -> repeat for idempotency
    & $installPs1 -InstallDir $d14sz -Size Regular -NoLaunch -RegistryRoot $r14sz -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $theme14 = Join-Path $d14sz "Bibata-Modern-Ice"
    $regDir14 = Join-Path $theme14 "Bibata-Modern-Ice-Regular-Windows"
    $largeDir14 = Join-Path $theme14 "Bibata-Modern-Ice-Large-Windows"
    $xlDir14 = Join-Path $theme14 "Bibata-Modern-Ice-Extra-Large-Windows"
    Assert-True ((Test-Path -LiteralPath $regDir14) -and (Test-Path -LiteralPath $largeDir14) -and (Test-Path -LiteralPath $xlDir14)) "Case 14a: Initial 3 sizes missing"
    $privInLarge = Join-Path $largeDir14 "my-private-in-large.txt"
    Set-Content -Path $privInLarge -Value "keep-me-on-singlesize" -Encoding UTF8

    & $installPs1 -InstallDir $d14sz -Size Regular -SingleSize -NoLaunch -RegistryRoot $r14sz -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $regDir14 "Pointer.cur")) "Case 14a: Regular missing after 3->1"
    Assert-True (-not (Test-Path -LiteralPath $xlDir14)) "Case 14a: Extra-Large not pruned on 3->1"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $largeDir14 "Pointer.cur"))) "Case 14a: Managed Large cursor files not pruned on 3->1"
    Assert-True (Test-Path -LiteralPath $privInLarge) "Case 14a: Private file inside pruned Large folder was deleted!"
    $m14a1 = Get-Content -LiteralPath (Join-Path $d14sz "bibata-ice-glow-manifest.json") -Raw | ConvertFrom-Json
    Assert-True (@($m14a1.managedCursorFiles | Where-Object { $_ -like "*Large-Windows*" }).Count -eq 0) "Case 14a: Manifest still lists pruned Large/Extra-Large files"

    # Repeat -SingleSize reinstall: must be idempotent
    & $installPs1 -InstallDir $d14sz -Size Regular -SingleSize -NoLaunch -RegistryRoot $r14sz -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    Assert-True (Test-Path -LiteralPath $privInLarge) "Case 14a: Repeat SingleSize deleted private file"
    Assert-True (-not (Test-Path -LiteralPath $xlDir14)) "Case 14a: Repeat SingleSize recreated Extra-Large"

    # 14b: 1 size -> normal reinstall (1->3) -> repeat for idempotency
    & $installPs1 -InstallDir $d14sz -Size Regular -NoLaunch -RegistryRoot $r14sz -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $largeDir14 "Pointer.cur")) "Case 14b: Large not restored on 1->3"
    Assert-True (Test-Path -LiteralPath (Join-Path $xlDir14 "Pointer.cur")) "Case 14b: Extra-Large not restored on 1->3"
    Assert-True (Test-Path -LiteralPath $privInLarge) "Case 14b: Private file lost on 1->3"
    $m14b = Get-Content -LiteralPath (Join-Path $d14sz "bibata-ice-glow-manifest.json") -Raw | ConvertFrom-Json
    Assert-True (@($m14b.managedCursorFiles | Where-Object { $_ -like "*Extra-Large-Windows*" }).Count -eq 17) "Case 14b: Manifest missing restored Extra-Large files"
    & $installPs1 -InstallDir $d14sz -Size Regular -NoLaunch -RegistryRoot $r14sz -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    Assert-True ((Test-Path -LiteralPath (Join-Path $xlDir14 "Help.cur")) -and (Test-Path -LiteralPath $privInLarge)) "Case 14b: Repeat 3-size install inconsistent"

    # 14c: Delete ONLY Help.cur (Pointer.cur remains) -> reinstall repairs Help.cur
    $help14 = Join-Path $regDir14 "Help.cur"
    Remove-Item -LiteralPath $help14 -Force
    Assert-True (-not (Test-Path -LiteralPath $help14)) "Case 14c: Failed to delete Help.cur"
    & $installPs1 -InstallDir $d14sz -Size Regular -NoLaunch -RegistryRoot $r14sz -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    Assert-True (Test-Path -LiteralPath $help14 -PathType Leaf) "Case 14c: Reinstall did not repair missing Help.cur while Pointer.cur existed!"

    # 14d: Rollback of -SingleSize prune when manifest is locked
    $xlPtrHashBefore = Get-FileSha256 (Join-Path $xlDir14 "Pointer.cur")
    $largeBusyHashBefore = Get-FileSha256 (Join-Path $largeDir14 "Busy.ani")
    $manifest14 = Join-Path $d14sz "bibata-ice-glow-manifest.json"
    $lockStream14 = [System.IO.File]::Open($manifest14, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $threw14d = $false
    try {
        & $installPs1 -InstallDir $d14sz -Size Regular -SingleSize -NoLaunch -RegistryRoot $r14sz -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    }
    catch {
        $threw14d = $true
    }
    finally {
        $lockStream14.Dispose()
    }
    Assert-True $threw14d "Case 14d: Locked manifest should fail SingleSize prune"
    Assert-True ((Get-FileSha256 (Join-Path $xlDir14 "Pointer.cur")) -eq $xlPtrHashBefore) "Case 14d: Pruned Extra-Large Pointer.cur not rolled back!"
    Assert-True ((Get-FileSha256 (Join-Path $largeDir14 "Busy.ani")) -eq $largeBusyHashBefore) "Case 14d: Pruned Large Busy.ani not rolled back!"
    Assert-True (Test-Path -LiteralPath $privInLarge) "Case 14d: Private file lost during prune rollback!"
    Write-Host "PASS Case 14: Reinstall 3->1, 1->3, missing Help.cur repair, private file preservation, idempotency & prune rollback all pass" -ForegroundColor Green

    # =========================================================================
    # Case 15 (PR #1): Uninstall -KeepFiles must NOT delete user's mixed scheme or revert custom Hand
    # =========================================================================
    $d15 = Join-Path $testRoot "case15_mixed_scheme"
    $r15 = Join-Path $regRoot "case15"
    $c15 = Join-Path $r15 "Control Panel\Cursors"
    $s15 = Join-Path $c15 "Schemes"
    New-Item -Path $s15 -Force | Out-Null
    $customHand15 = Join-Path $testRoot "case15_my_hand.cur"
    Set-Content -Path $customHand15 -Value "my-custom-hand" -Encoding UTF8
    Set-ItemProperty -Path $c15 -Name "(Default)" -Value "OrigBefore15" -Type String
    Set-ItemProperty -Path $c15 -Name "Arrow" -Value "%SystemRoot%\cursors\aero_arrow.cur" -Type ExpandString

    & $installPs1 -InstallDir $d15 -Size Regular -NoLaunch -RegistryRoot $r15 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $bibataArrow15 = Join-Path $d15 "Bibata-Modern-Ice\Bibata-Modern-Ice-Regular-Windows\Pointer.cur"
    $mixedSchemeVal = "$bibataArrow15,,,,,,,,,,,,,,$customHand15,,"
    Set-ItemProperty -Path $s15 -Name "My Mixed Scheme" -Value $mixedSchemeVal -Type String
    Set-ItemProperty -Path $c15 -Name "(Default)" -Value "My Mixed Scheme" -Type String
    Set-ItemProperty -Path $c15 -Name "Hand" -Value $customHand15 -Type String

    & $uninstallPs1 -InstallDir $d15 -KeepFiles -RegistryRoot $r15 -SkipCursorRefresh | Out-Null
    $c15Item = Get-Item -Path $c15
    $s15Item = Get-Item -Path $s15
    Assert-True ($s15Item.GetValue("My Mixed Scheme", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -eq $mixedSchemeVal) "Case 15: User's 'My Mixed Scheme' was deleted or altered!"
    Assert-True ($c15Item.GetValue("", $null) -eq "My Mixed Scheme") "Case 15: Active '(Default)' scheme was reverted!"
    Assert-True ($c15Item.GetValue("Hand", $null) -eq $customHand15) "Case 15: Active custom Hand cursor was reverted!"
    Assert-True ($c15Item.GetValue("Arrow", $null) -eq $bibataArrow15) "Case 15: Active Bibata Arrow was altered under -KeepFiles!"
    Assert-True ($null -eq $s15Item.GetValue("Bibata-Modern-Ice (Regular)", $null)) "Case 15: Project's own Regular scheme was not cleaned"
    Write-Host "PASS Case 15: Uninstall -KeepFiles preserves user's mixed scheme, active selection, and custom Hand cursor" -ForegroundColor Green

    # =========================================================================
    # Case 16 (PR #2): Editing Large scheme mid-cycle then cycling back to Large preserves latest edit
    # =========================================================================
    $d16 = Join-Path $testRoot "case16_hotkey_reedit"
    $r16 = Join-Path $regRoot "case16"
    $c16 = Join-Path $r16 "Control Panel\Cursors"
    $s16 = Join-Path $c16 "Schemes"
    New-Item -Path $s16 -Force | Out-Null
    $origLarge16 = "%SystemRoot%\cursors\aero_arrow.cur,%SystemRoot%\cursors\aero_helpsel.cur,,"
    $editedLarge16 = "%SystemRoot%\cursors\aero_arrow.cur,%SystemRoot%\cursors\aero_link.cur,%SystemRoot%\cursors\aero_busy.ani,,"
    Set-ItemProperty -Path $s16 -Name "Bibata-Modern-Ice (Large)" -Value $origLarge16 -Type String
    Set-ItemProperty -Path $c16 -Name "Arrow" -Value "%SystemRoot%\cursors\aero_arrow.cur" -Type ExpandString

    & $installPs1 -InstallDir $d16 -Size Regular -NoLaunch -RegistryRoot $r16 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $exe16 = Join-Path $d16 "Bibata-Ice-Trail\BibataIceTrail.exe"
    $subKey16 = ($c16 -replace '^HKCU:\\', '')

    # Regular -> Large -> Extra-Large
    foreach ($szStep in @("Large", "Extra-Large")) {
        $p16 = Start-Process -FilePath $exe16 -ArgumentList @("--cycle-cursor-size", "--cursors-reg-key", "`"$subKey16`"", "--no-refresh") -Wait -PassThru
        Assert-True ($p16.ExitCode -eq 0) "Case 16: Cycle to $szStep failed"
    }
    # User edits saved Large scheme with new value AND ExpandString kind
    Set-ItemProperty -Path $s16 -Name "Bibata-Modern-Ice (Large)" -Value $editedLarge16 -Type ExpandString

    # Continue cycling: Extra-Large -> Regular -> Large (and repeat once more to ensure stable)
    foreach ($szStep in @("Regular", "Large", "Extra-Large", "Regular", "Large")) {
        $p16 = Start-Process -FilePath $exe16 -ArgumentList @("--cycle-cursor-size", "--cursors-reg-key", "`"$subKey16`"", "--no-refresh") -Wait -PassThru
        Assert-True ($p16.ExitCode -eq 0) "Case 16: Post-edit cycle to $szStep failed"
    }

    & $uninstallPs1 -InstallDir $d16 -RegistryRoot $r16 -SkipCursorRefresh | Out-Null
    $s16Item = Get-Item -Path $s16
    $restored16 = $s16Item.GetValue("Bibata-Modern-Ice (Large)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $restoredKind16 = $s16Item.GetValueKind("Bibata-Modern-Ice (Large)").ToString()
    Assert-True ($restored16 -eq $editedLarge16) "Case 16: Latest user edit on Large was lost after cycling back to Large (got '$restored16')"
    Assert-True ($restoredKind16 -eq "ExpandString") "Case 16: Latest user edit registry kind not restored (got '$restoredKind16')"
    Write-Host "PASS Case 16: Cycling back to Large after editing preserves and restores latest user edit & registry kind" -ForegroundColor Green

    # =========================================================================
    # Case 17 (PR #3): A -> B migration with hotkey cycling preserves original pre-existing Large scheme
    # =========================================================================
    $d17orig = Join-Path $testRoot "case17_orig"
    New-Item -ItemType Directory -Path $d17orig -Force | Out-Null
    $origCur17 = Join-Path $d17orig "user_large_arrow.cur"
    Set-Content -Path $origCur17 -Value "user-large-17" -Encoding UTF8
    $origLarge17 = "$origCur17,%SystemRoot%\cursors\aero_helpsel.cur,,"

    # 17a: A (install Regular + hotkey->Large) -> B (install Regular + hotkey->Large) -> uninstall A -> uninstall B
    $d17A = Join-Path $testRoot "case17a_dirA"
    $d17B = Join-Path $testRoot "case17a_dirB"
    $r17a = Join-Path $regRoot "case17a"
    $c17a = Join-Path $r17a "Control Panel\Cursors"
    $s17a = Join-Path $c17a "Schemes"
    New-Item -Path $s17a -Force | Out-Null
    Set-ItemProperty -Path $s17a -Name "Bibata-Modern-Ice (Large)" -Value $origLarge17 -Type ExpandString
    Set-ItemProperty -Path $c17a -Name "Arrow" -Value "%SystemRoot%\cursors\aero_arrow.cur" -Type ExpandString
    $subKey17a = ($c17a -replace '^HKCU:\\', '')

    & $installPs1 -InstallDir $d17A -Size Regular -NoLaunch -RegistryRoot $r17a -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $exe17A = Join-Path $d17A "Bibata-Ice-Trail\BibataIceTrail.exe"
    $p17A = Start-Process -FilePath $exe17A -ArgumentList @("--cycle-cursor-size", "--cursors-reg-key", "`"$subKey17a`"", "--no-refresh") -Wait -PassThru
    Assert-True ($p17A.ExitCode -eq 0) "Case 17a: A hotkey cycle to Large failed"

    & $installPs1 -InstallDir $d17B -Size Regular -NoLaunch -RegistryRoot $r17a -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $exe17B = Join-Path $d17B "Bibata-Ice-Trail\BibataIceTrail.exe"
    $p17B = Start-Process -FilePath $exe17B -ArgumentList @("--cycle-cursor-size", "--cursors-reg-key", "`"$subKey17a`"", "--no-refresh") -Wait -PassThru
    Assert-True ($p17B.ExitCode -eq 0) "Case 17a: B hotkey cycle to Large failed"

    & $uninstallPs1 -InstallDir $d17A -RegistryRoot $r17a -SkipCursorRefresh | Out-Null
    $bLargeAfterA = (Get-Item -Path $s17a).GetValue("Bibata-Modern-Ice (Large)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    Assert-True ($bLargeAfterA -like "*case17a_dirB*Bibata-Modern-Ice-Large-Windows\Pointer.cur*") "Case 17a: Uninstalling A broke B's Large scheme ($bLargeAfterA)"

    & $uninstallPs1 -InstallDir $d17B -RegistryRoot $r17a -SkipCursorRefresh | Out-Null
    $s17aItem = Get-Item -Path $s17a
    $restored17a = $s17aItem.GetValue("Bibata-Modern-Ice (Large)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $restoredKind17a = $s17aItem.GetValueKind("Bibata-Modern-Ice (Large)").ToString()
    Assert-True ($restored17a -eq $origLarge17) "Case 17a: Original Large scheme lost after A->B hotkey migration (got '$restored17a')"
    Assert-True ($restoredKind17a -eq "ExpandString") "Case 17a: Original Large scheme kind mismatch ($restoredKind17a)"

    # 17b: A installs -Size Large directly -> B installs Regular then hotkey->Large -> uninstall A -> uninstall B
    $d17bA = Join-Path $testRoot "case17b_dirA"
    $d17bB = Join-Path $testRoot "case17b_dirB"
    $r17b = Join-Path $regRoot "case17b"
    $c17b = Join-Path $r17b "Control Panel\Cursors"
    $s17b = Join-Path $c17b "Schemes"
    New-Item -Path $s17b -Force | Out-Null
    Set-ItemProperty -Path $s17b -Name "Bibata-Modern-Ice (Large)" -Value $origLarge17 -Type ExpandString
    Set-ItemProperty -Path $c17b -Name "Arrow" -Value "%SystemRoot%\cursors\aero_arrow.cur" -Type ExpandString
    $subKey17b = ($c17b -replace '^HKCU:\\', '')

    & $installPs1 -InstallDir $d17bA -Size Large -NoLaunch -RegistryRoot $r17b -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    & $installPs1 -InstallDir $d17bB -Size Regular -NoLaunch -RegistryRoot $r17b -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $exe17bB = Join-Path $d17bB "Bibata-Ice-Trail\BibataIceTrail.exe"
    $p17bB = Start-Process -FilePath $exe17bB -ArgumentList @("--cycle-cursor-size", "--cursors-reg-key", "`"$subKey17b`"", "--no-refresh") -Wait -PassThru
    Assert-True ($p17bB.ExitCode -eq 0) "Case 17b: B hotkey cycle to Large failed"
    & $uninstallPs1 -InstallDir $d17bA -RegistryRoot $r17b -SkipCursorRefresh | Out-Null
    & $uninstallPs1 -InstallDir $d17bB -RegistryRoot $r17b -SkipCursorRefresh | Out-Null
    $restored17b = (Get-Item -Path $s17b).GetValue("Bibata-Modern-Ice (Large)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    Assert-True ($restored17b -eq $origLarge17) "Case 17b: Original Large scheme lost after A(install Large)->B(hotkey Large) (got '$restored17b')"
    Write-Host "PASS Case 17: A->B migration with size hotkey cycling inherits and restores original Large scheme" -ForegroundColor Green

    # =========================================================================
    # Case 18 (PR #4): -SingleSize reinstall syncs Schemes for pruned sizes (delete / restore / keep user edit)
    # =========================================================================
    # 18a: Project-created Large scheme -> reinstall Regular -SingleSize -> Large scheme removed
    $d18a = Join-Path $testRoot "case18a_prune_delete"
    $r18a = Join-Path $regRoot "case18a"
    $s18a = Join-Path $r18a "Control Panel\Cursors\Schemes"
    New-Item -Path $s18a -Force | Out-Null
    & $installPs1 -InstallDir $d18a -Size Large -NoLaunch -RegistryRoot $r18a -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    Assert-True ($null -ne (Get-Item -Path $s18a).GetValue("Bibata-Modern-Ice (Large)", $null)) "Case 18a: Large scheme not created"
    & $installPs1 -InstallDir $d18a -Size Regular -SingleSize -NoLaunch -RegistryRoot $r18a -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d18a "Bibata-Modern-Ice\Bibata-Modern-Ice-Large-Windows\Pointer.cur"))) "Case 18a: Large files not pruned"
    Assert-True ($null -eq (Get-Item -Path $s18a).GetValue("Bibata-Modern-Ice (Large)", $null)) "Case 18a: Stale Large scheme left pointing to deleted files!"

    # 18b: Pre-existing custom Large scheme -> install Large -> reinstall Regular -SingleSize -> restored to original value & kind
    $d18b = Join-Path $testRoot "case18b_prune_restore"
    $r18b = Join-Path $regRoot "case18b"
    $s18b = Join-Path $r18b "Control Panel\Cursors\Schemes"
    New-Item -Path $s18b -Force | Out-Null
    $origLarge18b = "%SystemRoot%\cursors\aero_arrow.cur,%SystemRoot%\cursors\aero_helpsel.cur,,"
    Set-ItemProperty -Path $s18b -Name "Bibata-Modern-Ice (Large)" -Value $origLarge18b -Type ExpandString
    & $installPs1 -InstallDir $d18b -Size Large -NoLaunch -RegistryRoot $r18b -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    & $installPs1 -InstallDir $d18b -Size Regular -SingleSize -NoLaunch -RegistryRoot $r18b -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $s18bItem = Get-Item -Path $s18b
    Assert-True ($s18bItem.GetValue("Bibata-Modern-Ice (Large)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -eq $origLarge18b) "Case 18b: Taken-over Large scheme not restored on SingleSize prune"
    Assert-True ($s18bItem.GetValueKind("Bibata-Modern-Ice (Large)").ToString() -eq "ExpandString") "Case 18b: Restored Large scheme kind mismatch"

    # 18c: User manually edited Large scheme after install -> reinstall Regular -SingleSize -> keeps user edit
    $d18c = Join-Path $testRoot "case18c_prune_keep_edit"
    $r18c = Join-Path $regRoot "case18c"
    $s18c = Join-Path $r18c "Control Panel\Cursors\Schemes"
    New-Item -Path $s18c -Force | Out-Null
    & $installPs1 -InstallDir $d18c -Size Large -NoLaunch -RegistryRoot $r18c -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $editedLarge18c = "%SystemRoot%\cursors\aero_arrow.cur,%SystemRoot%\cursors\aero_link.cur,,"
    Set-ItemProperty -Path $s18c -Name "Bibata-Modern-Ice (Large)" -Value $editedLarge18c -Type String
    & $installPs1 -InstallDir $d18c -Size Regular -SingleSize -NoLaunch -RegistryRoot $r18c -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    Assert-True ((Get-Item -Path $s18c).GetValue("Bibata-Modern-Ice (Large)", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -eq $editedLarge18c) "Case 18c: User-edited Large scheme lost on SingleSize prune"
    Write-Host "PASS Case 18: -SingleSize reinstall deletes project-created, restores pre-existing, and preserves user-edited pruned schemes" -ForegroundColor Green

    # =========================================================================
    # Case 19 (PR #5): Locked Help.cur makes uninstall fail non-zero, keep retry manifest, and succeed on retry
    # =========================================================================
    $d19 = Join-Path $testRoot "case19_locked_uninstall"
    $r19 = Join-Path $regRoot "case19"
    New-Item -Path (Join-Path $r19 "Control Panel\Cursors\Schemes") -Force | Out-Null
    & $installPs1 -InstallDir $d19 -Size Regular -SingleSize -NoLaunch -RegistryRoot $r19 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $help19 = Join-Path $d19 "Bibata-Modern-Ice\Bibata-Modern-Ice-Regular-Windows\Help.cur"
    $priv19 = Join-Path $d19 "Bibata-Modern-Ice\user-private-19.txt"
    Set-Content -Path $priv19 -Value "keep-on-retry" -Encoding UTF8
    $manifest19 = Join-Path $d19 "bibata-ice-glow-manifest.json"

    # Hold read-only non-delete handle on Help.cur
    $uninstOut19 = Join-Path $testRoot "case19_uninst_out.txt"
    $uninstErr19 = Join-Path $testRoot "case19_uninst_err.txt"
    $lockStream19 = [System.IO.File]::Open($help19, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $uProc1 = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$uninstallPs1`"", "-InstallDir", "`"$d19`"", "-RegistryRoot", "`"$r19`"", "-SkipCursorRefresh") -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $uninstOut19 -RedirectStandardError $uninstErr19
    }
    finally {
        $lockStream19.Dispose()
    }

    $combined19 = ""
    if (Test-Path $uninstOut19) { $combined19 += (Get-Content $uninstOut19 -Raw) }
    if (Test-Path $uninstErr19) { $combined19 += "`n" + (Get-Content $uninstErr19 -Raw) }
    $combined19Flat = ($combined19 -replace '[\r\n]+', '')
    Assert-True ($uProc1.ExitCode -ne 0) "Case 19: Uninstall with locked Help.cur returned exit code 0!"
    Assert-True ($combined19Flat -like "*Help.cur*") "Case 19: Uninstall error output did not identify failed file Help.cur. Output: $combined19"
    Assert-True (Test-Path -LiteralPath $help19 -PathType Leaf) "Case 19: Locked Help.cur unexpectedly vanished"
    Assert-True (Test-Path -LiteralPath $manifest19 -PathType Leaf) "Case 19: Manifest was deleted despite failed deletion of Help.cur!"
    Assert-True (Test-Path -LiteralPath $priv19 -PathType Leaf) "Case 19: Private file deleted on first pass"

    # Now handle is released; retry uninstall -> must clean Help.cur, empty Regular dir, and manifest, while preserving priv19
    $uProc2 = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$uninstallPs1`"", "-InstallDir", "`"$d19`"", "-RegistryRoot", "`"$r19`"", "-SkipCursorRefresh") -Wait -PassThru -WindowStyle Hidden
    Assert-True ($uProc2.ExitCode -eq 0) "Case 19: Retry uninstall after handle release failed (exit $($uProc2.ExitCode))"
    Assert-True (-not (Test-Path -LiteralPath $help19)) "Case 19: Retry uninstall did not remove Help.cur!"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d19 "Bibata-Modern-Ice\Bibata-Modern-Ice-Regular-Windows"))) "Case 19: Retry uninstall did not remove empty Regular dir"
    Assert-True (-not (Test-Path -LiteralPath $manifest19)) "Case 19: Retry uninstall did not remove manifest"
    Assert-True (Test-Path -LiteralPath $priv19 -PathType Leaf) "Case 19: Private file deleted on retry uninstall!"
    Write-Host "PASS Case 19: Locked file causes non-zero uninstall exit, retains manifest, and retry cleans cleanly while preserving private files" -ForegroundColor Green

    # =========================================================================
    # Case 20 (PR #6): Normal uninstall (without -KeepFiles) preserves cursor files referenced by retained mixed schemes
    # =========================================================================
    # 20a: Mixed scheme is currently active
    $d20a = Join-Path $testRoot "case20a_mixed_active"
    $r20a = Join-Path $regRoot "case20a"
    $c20a = Join-Path $r20a "Control Panel\Cursors"
    $s20a = Join-Path $c20a "Schemes"
    New-Item -Path $s20a -Force | Out-Null
    $customHand20a = Join-Path $testRoot "case20a_custom_hand.cur"
    Set-Content -Path $customHand20a -Value "custom-hand-20a" -Encoding UTF8
    Set-ItemProperty -Path $c20a -Name "(Default)" -Value "OrigBefore20a" -Type String
    Set-ItemProperty -Path $c20a -Name "Arrow" -Value "%SystemRoot%\cursors\aero_arrow.cur" -Type ExpandString

    & $installPs1 -InstallDir $d20a -Size Regular -NoLaunch -RegistryRoot $r20a -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $regDir20a = Join-Path $d20a "Bibata-Modern-Ice\Bibata-Modern-Ice-Regular-Windows"
    $largeDir20a = Join-Path $d20a "Bibata-Modern-Ice\Bibata-Modern-Ice-Large-Windows"
    $xlDir20a = Join-Path $d20a "Bibata-Modern-Ice\Bibata-Modern-Ice-Extra-Large-Windows"
    $bibataArrow20a = Join-Path $regDir20a "Pointer.cur"
    $bibataHelp20a = Join-Path $regDir20a "Help.cur"
    $bibataLink20a = Join-Path $regDir20a "Link.cur"
    $arrowHash20a = Get-FileSha256 $bibataArrow20a

    # Keep Bibata Arrow, replace Hand with custom .cur, clear other Bibata roles, save & activate "My Mixed Scheme"
    $mixedVal20a = "$bibataArrow20a,,,,,,,,,,,,,,$customHand20a,,"
    Set-ItemProperty -Path $s20a -Name "My Mixed Scheme" -Value $mixedVal20a -Type String
    Set-ItemProperty -Path $c20a -Name "(Default)" -Value "My Mixed Scheme" -Type String
    Set-ItemProperty -Path $c20a -Name "Arrow" -Value $bibataArrow20a -Type String
    Set-ItemProperty -Path $c20a -Name "Hand" -Value $customHand20a -Type String
    foreach ($clearRole in @("Help", "AppStarting", "Wait", "Crosshair", "IBeam", "NWPen", "No", "SizeNS", "SizeWE", "SizeNWSE", "SizeNESW", "SizeAll", "UpArrow", "Pin", "Person")) {
        Set-ItemProperty -Path $c20a -Name $clearRole -Value "" -Type String
    }

    & $uninstallPs1 -InstallDir $d20a -RegistryRoot $r20a -SkipCursorRefresh | Out-Null
    $c20aItem = Get-Item -Path $c20a
    $s20aItem = Get-Item -Path $s20a
    Assert-True ($c20aItem.GetValue("", $null) -eq "My Mixed Scheme") "Case 20a: Active '(Default)' mixed scheme was altered"
    Assert-True ($c20aItem.GetValue("Hand", $null) -eq $customHand20a) "Case 20a: Active custom Hand was altered"
    Assert-True ($c20aItem.GetValue("Arrow", $null) -eq $bibataArrow20a) "Case 20a: Active mixed Arrow path was altered"
    Assert-True ($s20aItem.GetValue("My Mixed Scheme", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -eq $mixedVal20a) "Case 20a: Saved 'My Mixed Scheme' was altered or deleted"
    Assert-True (Test-Path -LiteralPath $bibataArrow20a -PathType Leaf) "Case 20a: Referenced Pointer.cur was deleted by normal uninstall!"
    Assert-True ((Get-FileSha256 $bibataArrow20a) -eq $arrowHash20a) "Case 20a: Referenced Pointer.cur content changed!"
    Assert-True (Test-Path -LiteralPath $customHand20a -PathType Leaf) "Case 20a: Custom Hand file missing"
    Assert-True (-not (Test-Path -LiteralPath $bibataHelp20a)) "Case 20a: Unreferenced Regular\Help.cur was not cleaned up"
    Assert-True (-not (Test-Path -LiteralPath $bibataLink20a)) "Case 20a: Unreferenced Regular\Link.cur was not cleaned up"
    Assert-True (-not (Test-Path -LiteralPath $largeDir20a)) "Case 20a: Unreferenced Large directory was not cleaned up"
    Assert-True (-not (Test-Path -LiteralPath $xlDir20a)) "Case 20a: Unreferenced Extra-Large directory was not cleaned up"
    Assert-True ($null -eq $s20aItem.GetValue("Bibata-Modern-Ice (Regular)", $null)) "Case 20a: Project Regular scheme was not removed"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d20a "Bibata-Ice-Trail\BibataIceTrail.exe"))) "Case 20a: BibataIceTrail.exe was not cleaned up"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d20a "bibata-ice-glow-manifest.json"))) "Case 20a: Manifest was not cleaned up after successful uninstall"

    # 20b: Mixed scheme is saved, but user switched active cursors to another custom scheme before normal uninstall
    $d20b = Join-Path $testRoot "case20b_mixed_inactive_custom"
    $r20b = Join-Path $regRoot "case20b"
    $c20b = Join-Path $r20b "Control Panel\Cursors"
    $s20b = Join-Path $c20b "Schemes"
    New-Item -Path $s20b -Force | Out-Null
    $customHand20b = Join-Path $testRoot "case20b_custom_hand.cur"
    $otherArrow20b = Join-Path $testRoot "case20b_other_arrow.cur"
    Set-Content -Path $customHand20b -Value "custom-hand-20b" -Encoding UTF8
    Set-Content -Path $otherArrow20b -Value "other-arrow-20b" -Encoding UTF8
    Set-ItemProperty -Path $c20b -Name "(Default)" -Value "OrigBefore20b" -Type String
    Set-ItemProperty -Path $c20b -Name "Arrow" -Value "%SystemRoot%\cursors\aero_arrow.cur" -Type ExpandString

    & $installPs1 -InstallDir $d20b -Size Regular -NoLaunch -RegistryRoot $r20b -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $regDir20b = Join-Path $d20b "Bibata-Modern-Ice\Bibata-Modern-Ice-Regular-Windows"
    $bibataArrow20b = Join-Path $regDir20b "Pointer.cur"
    $bibataHelp20b = Join-Path $regDir20b "Help.cur"
    $mixedVal20b = "$bibataArrow20b,,,,,,,,,,,,,,$customHand20b,,"
    $otherVal20b = "$otherArrow20b,,,,,,,,,,,,,,,,"
    Set-ItemProperty -Path $s20b -Name "My Mixed Scheme" -Value $mixedVal20b -Type String
    Set-ItemProperty -Path $s20b -Name "Other Custom Scheme" -Value $otherVal20b -Type String
    # User switches active scheme to "Other Custom Scheme"
    Set-ItemProperty -Path $c20b -Name "(Default)" -Value "Other Custom Scheme" -Type String
    Set-ItemProperty -Path $c20b -Name "Arrow" -Value $otherArrow20b -Type String
    foreach ($clearRole in @("Help", "AppStarting", "Wait", "Crosshair", "IBeam", "NWPen", "No", "SizeNS", "SizeWE", "SizeNWSE", "SizeNESW", "SizeAll", "UpArrow", "Hand", "Pin", "Person")) {
        Set-ItemProperty -Path $c20b -Name $clearRole -Value "" -Type String
    }

    & $uninstallPs1 -InstallDir $d20b -RegistryRoot $r20b -SkipCursorRefresh | Out-Null
    $c20bItem = Get-Item -Path $c20b
    $s20bItem = Get-Item -Path $s20b
    Assert-True ($c20bItem.GetValue("", $null) -eq "Other Custom Scheme") "Case 20b: Active 'Other Custom Scheme' was altered"
    Assert-True ($c20bItem.GetValue("Arrow", $null) -eq $otherArrow20b) "Case 20b: Active other Arrow was altered"
    Assert-True ($s20bItem.GetValue("My Mixed Scheme", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -eq $mixedVal20b) "Case 20b: Saved inactive 'My Mixed Scheme' was altered or deleted"
    Assert-True (Test-Path -LiteralPath $bibataArrow20b -PathType Leaf) "Case 20b: Pointer.cur referenced by saved inactive 'My Mixed Scheme' was deleted!"
    Assert-True (-not (Test-Path -LiteralPath $bibataHelp20b)) "Case 20b: Unreferenced Regular\Help.cur was not cleaned up"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d20b "Bibata-Modern-Ice\Bibata-Modern-Ice-Large-Windows"))) "Case 20b: Unreferenced Large dir was not cleaned up"
    Assert-True ($null -eq $s20bItem.GetValue("Bibata-Modern-Ice (Regular)", $null)) "Case 20b: Project Regular scheme was not removed"

    # 20c: Mixed scheme is saved, and active scheme is Bibata Regular (restored on uninstall)
    $d20c = Join-Path $testRoot "case20c_mixed_inactive_bibata_active"
    $r20c = Join-Path $regRoot "case20c"
    $c20c = Join-Path $r20c "Control Panel\Cursors"
    $s20c = Join-Path $c20c "Schemes"
    New-Item -Path $s20c -Force | Out-Null
    $baseArrow20c = Join-Path $testRoot "case20c_base_arrow.cur"
    $customHand20c = Join-Path $testRoot "case20c_custom_hand.cur"
    Set-Content -Path $baseArrow20c -Value "base-arrow-20c" -Encoding UTF8
    Set-Content -Path $customHand20c -Value "custom-hand-20c" -Encoding UTF8
    Set-ItemProperty -Path $c20c -Name "(Default)" -Value "BaseScheme20c" -Type String
    Set-ItemProperty -Path $c20c -Name "Arrow" -Value $baseArrow20c -Type String

    & $installPs1 -InstallDir $d20c -Size Regular -NoLaunch -RegistryRoot $r20c -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $regDir20c = Join-Path $d20c "Bibata-Modern-Ice\Bibata-Modern-Ice-Regular-Windows"
    $bibataArrow20c = Join-Path $regDir20c "Pointer.cur"
    $bibataHelp20c = Join-Path $regDir20c "Help.cur"
    $mixedVal20c = "$bibataArrow20c,,,,,,,,,,,,,,$customHand20c,,"
    Set-ItemProperty -Path $s20c -Name "My Mixed Scheme" -Value $mixedVal20c -Type String

    & $uninstallPs1 -InstallDir $d20c -RegistryRoot $r20c -SkipCursorRefresh | Out-Null
    $c20cItem = Get-Item -Path $c20c
    $s20cItem = Get-Item -Path $s20c
    Assert-True ($c20cItem.GetValue("", $null) -eq "BaseScheme20c") "Case 20c: Active Bibata scheme should restore to BaseScheme20c"
    Assert-True ($c20cItem.GetValue("Arrow", $null) -eq $baseArrow20c) "Case 20c: Active Arrow should restore to BaseScheme20c arrow"
    Assert-True ($s20cItem.GetValue("My Mixed Scheme", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -eq $mixedVal20c) "Case 20c: Saved 'My Mixed Scheme' was altered or deleted"
    Assert-True (Test-Path -LiteralPath $bibataArrow20c -PathType Leaf) "Case 20c: Pointer.cur referenced by saved 'My Mixed Scheme' was deleted!"
    Assert-True (-not (Test-Path -LiteralPath $bibataHelp20c)) "Case 20c: Unreferenced Regular\Help.cur was not cleaned up"
    Assert-True ($null -eq $s20cItem.GetValue("Bibata-Modern-Ice (Regular)", $null)) "Case 20c: Project Regular scheme was not removed"
    Write-Host "PASS Case 20: Normal uninstall preserves cursor files referenced by active or saved mixed schemes while cleaning unused files" -ForegroundColor Green

    # =========================================================================
    # Case 21 (PR #7): Normal uninstall preserves user files in Bibata-Ice-Trail root and subdirectories
    # =========================================================================
    $d21 = Join-Path $testRoot "case21_trail_user_files"
    $r21 = Join-Path $regRoot "case21"
    New-Item -Path (Join-Path $r21 "Control Panel\Cursors\Schemes") -Force | Out-Null

    & $installPs1 -InstallDir $d21 -Size Regular -SingleSize -Palette Cyan -NoLaunch -RegistryRoot $r21 -SkipCursorRefresh -SkipTaskScheduler -TestCursorZipPath $fixtureZip | Out-Null
    $trailDir21 = Join-Path $d21 "Bibata-Ice-Trail"
    $rootBackup21 = Join-Path $trailDir21 "my-palette-backup.ini"
    $subBackupDir21 = Join-Path $trailDir21 "backups\custom"
    New-Item -ItemType Directory -Path $subBackupDir21 -Force | Out-Null
    $subBackup21 = Join-Path $subBackupDir21 "nested-backup.ini"
    $rootBackupContent21 = "[UserPaletteBackup]`r`nPalette=3`r`nCustomColor=#11AAFF`r`n"
    $subBackupContent21 = "[NestedBackup]`r`nPreset=2`r`nNote=do-not-delete-on-uninstall`r`n"
    [System.IO.File]::WriteAllText($rootBackup21, $rootBackupContent21, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($subBackup21, $subBackupContent21, [System.Text.Encoding]::UTF8)
    $rootHash21 = Get-FileSha256 $rootBackup21
    $subHash21 = Get-FileSha256 $subBackup21
    $configBackup21 = Join-Path $trailDir21 "config.ini.bak"
    [IO.File]::WriteAllText($configBackup21, "personal backup, different from the live configuration")
    $configBackupHash21 = Get-FileSha256 $configBackup21
    & $installPs1 -InstallDir $d21 -SkipCursor -Palette Rainbow -NoLaunch -RegistryRoot $r21 -SkipCursorRefresh -SkipTaskScheduler | Out-Null
    Assert-True ((Get-FileSha256 $configBackup21) -eq $configBackupHash21) "Case 21: Reinstall changed config.ini.bak"

    & $uninstallPs1 -InstallDir $d21 -RegistryRoot $r21 -SkipCursorRefresh | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $trailDir21 "BibataIceTrail.exe"))) "Case 21: BibataIceTrail.exe was not removed!"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $trailDir21 "config.ini"))) "Case 21: config.ini was not removed!"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d21 "bibata-ice-glow-manifest.json"))) "Case 21: Manifest was not removed!"
    Assert-True (Test-Path -LiteralPath $rootBackup21 -PathType Leaf) "Case 21: Root user file my-palette-backup.ini was deleted by uninstall!"
    Assert-True (Test-Path -LiteralPath $subBackup21 -PathType Leaf) "Case 21: Subdirectory user file backups\custom\nested-backup.ini was deleted by uninstall!"
    Assert-True ((Get-FileSha256 $rootBackup21) -eq $rootHash21) "Case 21: my-palette-backup.ini content changed!"
    Assert-True (([System.IO.File]::ReadAllText($rootBackup21, [System.Text.Encoding]::UTF8)) -eq $rootBackupContent21) "Case 21: my-palette-backup.ini text mismatch!"
    Assert-True ((Get-FileSha256 $subBackup21) -eq $subHash21) "Case 21: nested-backup.ini content changed!"
    Assert-True ((Get-FileSha256 $configBackup21) -eq $configBackupHash21) "Case 21: Uninstall changed config.ini.bak"
    Assert-True (([System.IO.File]::ReadAllText($subBackup21, [System.Text.Encoding]::UTF8)) -eq $subBackupContent21) "Case 21: nested-backup.ini text mismatch!"
    Write-Host "PASS Case 21: Normal uninstall cleans project trail files while preserving user root & nested files in Bibata-Ice-Trail" -ForegroundColor Green

    # Case 22: prune only unreferenced files, even when both saved schemes are inactive.
    $d22 = Join-Path $testRoot "case22_prune_references"
    $r22 = Join-Path $regRoot "case22"
    $s22 = Join-Path $r22 "Control Panel\Cursors\Schemes"
    $install22 = @{ InstallDir = $d22; RegistryRoot = $r22; SkipTrail = $true; SkipCursorRefresh = $true; TestCursorZipPath = $fixtureZip }
    & $installPs1 @install22 -Size Large | Out-Null
    $largeDir22 = Join-Path $d22 "Bibata-Modern-Ice\Bibata-Modern-Ice-Large-Windows"
    $largeArrow22 = Join-Path $largeDir22 "Pointer.cur"
    $largeHash22 = Get-FileSha256 $largeArrow22
    $xlDir22 = Join-Path $d22 "Bibata-Modern-Ice\Bibata-Modern-Ice-Extra-Large-Windows"
    $xlHelp22 = Join-Path $xlDir22 "Help.cur"
    $xlHash22 = Get-FileSha256 $xlHelp22
    $mixed22 = "$largeArrow22,$xlHelp22"
    Set-ItemProperty -Path $s22 -Name "My mixed sizes" -Value $mixed22 -Type String
    $expanded22 = $largeArrow22.Replace($canonicalTemp, "%TEMP%")
    Set-ItemProperty -Path $s22 -Name "My other arrow" -Value $expanded22 -Type ExpandString

    & $installPs1 @install22 -Size Regular -SingleSize | Out-Null
    Assert-True ((Get-Item $s22).GetValue("My mixed sizes") -eq $mixed22) "Case 22: Saved mixed scheme changed"
    Assert-True ((Get-FileSha256 $largeArrow22) -eq $largeHash22) "Case 22: Saved Large arrow changed"
    Assert-True ((Get-FileSha256 $xlHelp22) -eq $xlHash22) "Case 22: Saved Extra-Large Help changed"
    Assert-True (-not (Test-Path (Join-Path $largeDir22 "Help.cur"))) "Case 22: Unreferenced Large Help was not pruned"
    Remove-ItemProperty -Path $s22 -Name "My mixed sizes"
    & $installPs1 @install22 -Size Regular -SingleSize | Out-Null
    Assert-True ((Get-FileSha256 $largeArrow22) -eq $largeHash22) "Case 22: ExpandString reference was lost"
    Assert-True (-not (Test-Path $xlDir22)) "Case 22: Extra-Large was kept after its last reference disappeared"
    Remove-ItemProperty -Path $s22 -Name "My other arrow"
    & $uninstallPs1 -InstallDir $d22 -RegistryRoot $r22 -SkipCursorRefresh | Out-Null
    Assert-True (-not (Test-Path $largeDir22)) "Case 22: Previously retained file was missing from uninstall ownership"
    Write-Host "PASS Case 22: SingleSize preserves saved references across sizes and cleans up after the last reference disappears" -ForegroundColor Green

    # Case 23: a locked manifest must prevent the CLI from reporting a successful uninstall.
    $d23 = Join-Path $testRoot "case23_locked_manifest"
    $r23 = Join-Path $regRoot "case23"
    & $installPs1 -InstallDir $d23 -RegistryRoot $r23 -SingleSize -SkipTrail -SkipCursorRefresh -TestCursorZipPath $fixtureZip | Out-Null
    $manifest23 = Join-Path $d23 "bibata-ice-glow-manifest.json"
    $cursorKey23 = Join-Path $r23 "Control Panel\Cursors"
    $arrow23 = (Get-Item $cursorKey23).GetValue("Arrow")
    $exclusive23 = [IO.File]::Open($manifest23, 'Open', 'Read', 'None')
    try {
        $readFailed23 = $false
        try { & $uninstallPs1 -InstallDir $d23 -RegistryRoot $r23 -SkipCursorRefresh | Out-Null }
        catch { $readFailed23 = $true }
    }
    finally { $exclusive23.Dispose() }
    Assert-True ($readFailed23 -and (Test-Path -LiteralPath $arrow23)) "Case 23: Unreadable manifest allowed cleanup"
    Assert-True ((Get-Item $cursorKey23).GetValue("Arrow") -eq $arrow23) "Case 23: Unreadable manifest changed active cursors"
    $args23 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $uninstallPs1), '-InstallDir', ('"{0}"' -f $d23), '-RegistryRoot', $r23, '-SkipCursorRefresh')
    $out23 = Join-Path $testRoot "case23-out.txt"
    $err23 = Join-Path $testRoot "case23-err.txt"
    $lock23 = [IO.File]::Open($manifest23, 'Open', 'Read', 'Read')
    try {
        $first23 = Start-Process powershell.exe -ArgumentList $args23 -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out23 -RedirectStandardError $err23
    }
    finally { $lock23.Dispose() }
    Assert-True ($first23.ExitCode -ne 0) "Case 23: Locked manifest returned success"
    Assert-True (-not ([IO.File]::ReadAllText($out23).Contains("Uninstall complete."))) "Case 23: False completion message"
    Assert-True (([IO.File]::ReadAllText($err23) -replace '\s','') -like '*bibata-ice-glow-manifest.json*') "Case 23: Error did not name the manifest"
    Assert-True (Test-Path -LiteralPath $manifest23 -PathType Leaf) "Case 23: Retry manifest missing"
    $retry23 = Start-Process powershell.exe -ArgumentList $args23 -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out23 -RedirectStandardError $err23
    Assert-True ($retry23.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $manifest23)) "Case 23: Retry failed to remove released manifest"
    Write-Host "PASS Case 23: Locked manifest returns failure and retry removes it" -ForegroundColor Green

    # Case 24: a config present before the first trail installation belongs to the user.
    foreach ($scenario in 'untouched', 'palette', 'edited', 'edited-before-upgrade', 'legacy-uninstall', 'legacy-upgrade') {
        $d24 = Join-Path $testRoot "case24_$scenario"
        $r24 = Join-Path $regRoot "case24_$scenario"
        $trail24 = New-Item -ItemType Directory -Path (Join-Path $d24 'Bibata-Ice-Trail') -Force
        $cfg24 = Join-Path $trail24.FullName 'config.ini'
        [IO.File]::WriteAllText($cfg24, "[BibataIceTrail]$([char]10)Palette=1$([char]10)ShowTrayIcon=true")
        $expectedHash = Get-FileSha256 $cfg24
        $opts24 = @{ InstallDir=$d24; RegistryRoot=$r24; SkipCursor=$true; NoLaunch=$true; NoAutoStart=$true; SkipTaskScheduler=$true; SkipCursorRefresh=$true }
        & $installPs1 @opts24 | Out-Null
        Assert-True ((Get-FileSha256 $cfg24) -eq $expectedHash) "Case 24: Install modified the supplied configuration"
        if ($scenario -like 'legacy-*') {
            $manifest24 = Join-Path $d24 'bibata-ice-glow-manifest.json'
            $legacy24 = Get-Content $manifest24 -Raw | ConvertFrom-Json
            $legacy24.schemaVersion = 2
            $legacy24.PSObject.Properties.Remove('userConfigBackup')
            $legacy24.managedTrailFiles += $cfg24
            Set-Content -LiteralPath $manifest24 -Value ($legacy24 | ConvertTo-Json -Depth 6) -Encoding UTF8
        }
        if ($scenario -notin 'untouched', 'legacy-uninstall') {
            & $installPs1 @opts24 -Palette Rainbow | Out-Null
            Assert-True ((Get-Content -LiteralPath $cfg24 -Raw) -match 'Palette=5') "Case 24: Requested palette was not applied"
            if ($scenario -like 'edited*') {
                [IO.File]::WriteAllText($cfg24, "[BibataIceTrail]$([char]10)Palette=4$([char]10)CustomColor=#123456")
                $expectedHash = Get-FileSha256 $cfg24
            }
            if ($scenario -ne 'edited') { & $installPs1 @opts24 -Palette Frost | Out-Null }
        }
        & $uninstallPs1 -InstallDir $d24 -RegistryRoot $r24 -SkipCursorRefresh | Out-Null
        Assert-True ((Get-FileSha256 $cfg24) -eq $expectedHash) "Case 24 ($scenario): User config lost or changed"
        Assert-True (-not (Test-Path (Join-Path $trail24.FullName 'BibataIceTrail.exe'))) "Case 24: Managed EXE left behind"
    }
    Write-Host "PASS Case 24: Existing config and later user edits survive install, palette upgrades and uninstall"

    # Case 25: an existing malformed/empty manifest must stop both entry points before mutation.
    $d25 = Join-Path $testRoot 'case25_bad_manifest'
    $r25 = Join-Path $regRoot 'case25'
    $opts25 = @{ InstallDir=$d25; RegistryRoot=$r25; NoLaunch=$true; SkipCursorRefresh=$true; SkipTaskScheduler=$true; TestCursorZipPath=$fixtureZip }
    & $installPs1 @opts25 -SingleSize | Out-Null
    $manifest25 = Join-Path $d25 'bibata-ice-glow-manifest.json'
    $original25 = [IO.File]::ReadAllBytes($manifest25)
    $exe25 = Join-Path $d25 'Bibata-Ice-Trail\BibataIceTrail.exe'
    $exeHash25 = Get-FileSha256 $exe25
    $cur25 = Join-Path $r25 'Control Panel\Cursors'
    $arrow25 = (Get-Item $cur25).GetValue('Arrow')
    $run25 = Join-Path $r25 'Software\Microsoft\Windows\CurrentVersion\Run'
    $startup25 = (Get-Item $run25).GetValue('BibataIceTrail')
    foreach ($bad in '{"schemaVersion":', '', '{}', 'null', '[]') {
        [IO.File]::WriteAllText($manifest25, $bad)
        foreach ($operation in 'install', 'uninstall') {
            $message = ''
            try {
                if ($operation -eq 'install') { & $installPs1 @opts25 -Size Large | Out-Null }
                else { & $uninstallPs1 -InstallDir $d25 -RegistryRoot $r25 -SkipCursorRefresh | Out-Null }
            }
            catch { $message = $_.Exception.Message }
            Assert-True ($message.Contains($manifest25)) "Case 25: $operation did not identify the invalid manifest"
            Assert-True ([IO.File]::ReadAllText($manifest25) -ceq $bad) "Case 25: $operation overwrote the bad manifest"
            Assert-True ((Get-FileSha256 $exe25) -eq $exeHash25 -and (Test-Path -LiteralPath $arrow25)) "Case 25: Managed files changed"
            Assert-True ((Get-Item $cur25).GetValue('Arrow') -eq $arrow25 -and (Get-Item $run25).GetValue('BibataIceTrail') -eq $startup25) "Case 25: Registry changed"
        }
    }
    [IO.File]::WriteAllBytes($manifest25, $original25)
    & $uninstallPs1 -InstallDir $d25 -RegistryRoot $r25 -SkipCursorRefresh | Out-Null
    Assert-True (-not (Test-Path $manifest25)) "Case 25: Valid manifest could not be used for retry"
    Write-Host "PASS Case 25: Invalid manifest stops install and uninstall; restoring the original allows cleanup"

    # Case 26: exercise the actual .NET reader/writer before and after PowerShell prunes its records.
    $d26 = Join-Path $testRoot 'case26_cycle_resize'
    $r26 = Join-Path $regRoot 'case26'
    $c26 = Join-Path $r26 'Control Panel\Cursors'
    $s26 = Join-Path $c26 'Schemes'
    [void](New-Item -Path $s26 -Force)
    $large26 = 'Bibata-Modern-Ice (Large)'
    $xl26 = 'Bibata-Modern-Ice (Extra-Large)'
    $user26 = Join-Path $testRoot 'user26.cur'
    [IO.File]::WriteAllText($user26, 'user cursor')
    Set-ItemProperty -Path $s26 -Name $xl26 -Value $user26 -Type ExpandString
    $opts26 = @{ InstallDir=$d26; RegistryRoot=$r26; NoLaunch=$true; NoAutoStart=$true; SkipCursorRefresh=$true; SkipTaskScheduler=$true; TestCursorZipPath=$fixtureZip }
    & $installPs1 @opts26 | Out-Null
    $exe26 = Join-Path $d26 'Bibata-Ice-Trail\BibataIceTrail.exe'
    $cycleArgs26 = @('--cycle-cursor-size', '--cursors-reg-key', ('"{0}"' -f $c26.Substring(6)), '--no-refresh')
    $side26 = Join-Path $d26 'bibata-runtime-schemes.json'
    foreach ($phase in 'initial', 'expanded') {
        foreach ($name in $large26, $xl26) {
            $process26 = Start-Process $exe26 -ArgumentList $cycleArgs26 -WindowStyle Hidden -Wait -PassThru
            Assert-True ($process26.ExitCode -eq 0 -and (Get-Item $c26).GetValue('') -eq $name) "Case 26: $phase failed to switch to $name"
            $saved26 = (Get-Item $s26).GetValue($name)
            Assert-True (($saved26 -split ',')[0] -eq (Get-Item $c26).GetValue('Arrow')) "Case 26: $phase saved and active $name disagree"
        }
        if ($phase -eq 'initial') {
            $records26 = Get-Content -LiteralPath $side26 -Raw | ConvertFrom-Json
            $wrapped26 = @([ordered]@{ value=$records26; Count=2 })
            [IO.File]::WriteAllText($side26, (ConvertTo-Json -InputObject $wrapped26 -Depth 6))
            & $installPs1 @opts26 | Out-Null
            $flat26 = Get-Content -LiteralPath $side26 -Raw | ConvertFrom-Json
            Assert-True ($flat26.Count -eq 2 -and $flat26[0].name -eq $large26) "Case 26: Existing PowerShell-wrapped records were not repaired"
            & $installPs1 @opts26 -SingleSize | Out-Null
            Assert-True (-not (Test-Path $side26)) "Case 26: Empty backup left after both sizes were pruned"
            Assert-True ((Get-Item $s26).GetValue($xl26) -eq $user26) "Case 26: User's original Extra-Large backup lost"
            & $installPs1 @opts26 | Out-Null
        }
    }
    & $installPs1 @opts26 -SingleSize -Size Large | Out-Null
    $json26 = Get-Content -LiteralPath $side26 -Raw
    $last26 = $json26 | ConvertFrom-Json
    Assert-True ($json26.TrimStart().StartsWith('[') -and @($last26).Count -eq 1 -and $last26[0].name -eq $large26) "Case 26: One remaining record must be a flat JSON array"
    & $uninstallPs1 -InstallDir $d26 -RegistryRoot $r26 -SkipCursorRefresh | Out-Null
    Assert-True ((Get-Item $s26).GetValue($xl26) -eq $user26 -and (Get-Item $s26).GetValueKind($xl26) -eq 'ExpandString') "Case 26: User's saved scheme or type lost on uninstall"
    Write-Host "PASS Case 26: Size cycling registers the correct scheme after repair, prune and expansion"

    # Case 27: only the runtime backup knows the user's original Large scheme.
    $d27 = Join-Path $testRoot 'case27_sidecar'
    $r27 = Join-Path $regRoot 'case27'
    $c27 = Join-Path $r27 'Control Panel\Cursors'
    $s27 = Join-Path $c27 'Schemes'
    [void](New-Item -Path $s27 -Force)
    $large27 = 'Bibata-Modern-Ice (Large)'
    $user27 = Join-Path $testRoot 'case27-user.cur'
    [IO.File]::WriteAllText($user27, 'original cursor')
    Set-ItemProperty -Path $s27 -Name $large27 -Value $user27 -Type ExpandString
    $opts27 = @{ InstallDir=$d27; RegistryRoot=$r27; NoLaunch=$true; SkipCursorRefresh=$true; SkipTaskScheduler=$true; TestCursorZipPath=$fixtureZip }
    & $installPs1 @opts27 | Out-Null
    $exe27 = Join-Path $d27 'Bibata-Ice-Trail\BibataIceTrail.exe'
    $cycle27 = Start-Process $exe27 -ArgumentList @('--cycle-cursor-size','--cursors-reg-key',('"{0}"' -f $c27.Substring(6)),'--no-refresh') -WindowStyle Hidden -Wait -PassThru
    $side27 = Join-Path $d27 'bibata-runtime-schemes.json'
    $manifest27 = Join-Path $d27 'bibata-ice-glow-manifest.json'
    $record27 = Get-Content -LiteralPath $side27 -Raw | ConvertFrom-Json
    Assert-True ($cycle27.ExitCode -eq 0 -and $record27.name -eq $large27 -and $record27.previousValue -eq $user27) "Case 27: Hotkey did not back up the original scheme"
    $valid27 = [IO.File]::ReadAllBytes($side27)
    $saved27 = (Get-Item $s27).GetValue($large27)
    $arrow27 = (Get-Item $c27).GetValue('Arrow')
    $run27 = Join-Path $r27 'Software\Microsoft\Windows\CurrentVersion\Run'
    $startup27 = (Get-Item $run27).GetValue('BibataIceTrail')
    $files27 = @($manifest27, $exe27, $arrow27, $user27)
    $hashes27 = @($files27 | ForEach-Object { Get-FileSha256 $_ }) -join ','
    foreach ($problem in 'truncated', 'missing-original', 'exclusive') {
        if ($problem -eq 'truncated') { [IO.File]::WriteAllText($side27, '[{"name":') }
        elseif ($problem -eq 'missing-original') { [IO.File]::WriteAllText($side27, '[{"name":"Large","existedBefore":true,"writtenValue":"x"}]') }
        else { [IO.File]::WriteAllBytes($side27, $valid27) }
        $sideHash27 = Get-FileSha256 $side27
        $lock27 = if ($problem -eq 'exclusive') { [IO.File]::Open($side27,'Open','Read','None') }
        try {
            foreach ($op in 'install','uninstall') {
                $message27 = ''
                try {
                    if ($op -eq 'install') { & $installPs1 @opts27 -SingleSize -Size Regular | Out-Null }
                    else { & $uninstallPs1 -InstallDir $d27 -RegistryRoot $r27 -SkipCursorRefresh | Out-Null }
                }
                catch { $message27 = $_.Exception.Message }
                Assert-True ($message27.Contains($side27)) "Case 27 ($problem/$op): Missing sidecar error"
                Assert-True ((Get-Item $s27).GetValue($large27) -eq $saved27 -and (Get-Item $c27).GetValue('') -eq $large27 -and (Get-Item $c27).GetValue('Arrow') -eq $arrow27) "Case 27: Cursor state changed"
                Assert-True ((Get-Item $run27).GetValue('BibataIceTrail') -eq $startup27 -and (@($files27 | ForEach-Object { Get-FileSha256 $_ }) -join ',') -eq $hashes27) "Case 27: Startup or files changed"
            }
        }
        finally { if ($lock27) { $lock27.Dispose() } }
        Assert-True ((Get-FileSha256 $side27) -eq $sideHash27) "Case 27: Sidecar was modified"
    }
    $args27 = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $uninstallPs1),'-InstallDir',('"{0}"' -f $d27),'-RegistryRoot',$r27,'-SkipCursorRefresh')
    $out27 = Join-Path $testRoot 'case27-out.txt'
    $err27 = Join-Path $testRoot 'case27-err.txt'
    $lock27 = [IO.File]::Open($side27,'Open','Read','Read')
    try {
        $first27 = Start-Process powershell.exe -ArgumentList $args27 -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out27 -RedirectStandardError $err27
    }
    finally { $lock27.Dispose() }
    Assert-True ($first27.ExitCode -ne 0 -and -not ([IO.File]::ReadAllText($out27).Contains('Uninstall complete.'))) "Case 27: Locked sidecar reported success"
    Assert-True (([IO.File]::ReadAllText($err27) -replace '\s','').Contains('bibata-runtime-schemes.json')) "Case 27: Failure did not identify the sidecar"
    Assert-True ((Test-Path -LiteralPath $manifest27) -and (Get-FileSha256 $side27) -eq $sideHash27) "Case 27: Retry files lost"
    $retry27 = Start-Process powershell.exe -ArgumentList $args27 -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out27 -RedirectStandardError $err27
    Assert-True ($retry27.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $d27)) "Case 27: Retry did not clean the installation"
    Assert-True ((Get-Item $s27).GetValue($large27) -eq $user27 -and (Get-Item $s27).GetValueKind($large27) -eq 'ExpandString') "Case 27: Original same-name scheme lost"
    Write-Host "PASS Case 27: Invalid or unreadable sidecar stops changes; a deletion lock reports failure and retry preserves the original scheme"

    # Case 28: pruning can remove the whole runtime file or rewrite it with one surviving record.
    foreach ($keepSize in 'Regular', 'Extra-Large') {
        $d28 = Join-Path $testRoot "case28_$keepSize"
        $r28 = Join-Path $regRoot "case28_$keepSize"
        $c28 = Join-Path $r28 'Control Panel\Cursors'
        $s28 = Join-Path $c28 'Schemes'
        [void](New-Item -Path $s28 -Force)
        $large28 = 'Bibata-Modern-Ice (Large)'
        $original28 = Join-Path $testRoot 'original28.cur'
        $latest28 = Join-Path $testRoot 'latest28.cur'
        foreach ($file in $original28, $latest28) { [IO.File]::WriteAllText($file, 'user cursor') }
        Set-ItemProperty $s28 $large28 $original28 -Type ExpandString
        $opts28 = @{InstallDir=$d28; RegistryRoot=$r28; NoLaunch=$true; NoAutoStart=$true; SkipTaskScheduler=$true; SkipCursorRefresh=$true; TestCursorZipPath=$fixtureZip}
        & $installPs1 @opts28 | Out-Null
        $exe28 = Join-Path $d28 'Bibata-Ice-Trail\BibataIceTrail.exe'
        $cycleArgs28 = @('--cycle-cursor-size','--cursors-reg-key',('"{0}"' -f $c28.Substring(6)),'--no-refresh')
        $sizes28 = @('Large')
        if ($keepSize -eq 'Extra-Large') { $sizes28 += 'Extra-Large' }
        foreach ($size28 in $sizes28) {
            $cycle28 = Start-Process $exe28 -ArgumentList $cycleArgs28 -WindowStyle Hidden -Wait -PassThru
            Assert-True ($cycle28.ExitCode -eq 0 -and (Get-Item $c28).GetValue('') -eq "Bibata-Modern-Ice ($size28)") "Case 28: Hotkey setup failed"
        }
        $side28 = Join-Path $d28 'bibata-runtime-schemes.json'
        $manifest28 = Join-Path $d28 'bibata-ice-glow-manifest.json'
        $sideBytes28 = [IO.File]::ReadAllBytes($side28)
        $largeValue28 = (Get-Item $s28).GetValue($large28)
        $arrow28 = (Get-Item $c28).GetValue('Arrow')
        $files28 = @($side28, $manifest28, $arrow28, ($largeValue28 -split ',')[0])
        $hashes28 = @($files28 | ForEach-Object { Get-FileSha256 $_ }) -join ','
        foreach ($target28 in $side28, $manifest28) {
            $lock28 = [IO.File]::Open($target28, 'Open', 'Read', 'Read')
            try {
                $error28 = ''
                try { & $installPs1 @opts28 -Size $keepSize -SingleSize -SkipTrail | Out-Null }
                catch { $error28 = $_.Exception.Message }
            }
            finally { $lock28.Dispose() }
            Assert-True ($error28.Length -gt 0) "Case 28 ($keepSize): Locked $target28 reported success"
            if ($target28 -eq $side28) { Assert-True ($error28.Contains($side28)) "Case 28: Missing runtime backup path" }
            Assert-True ((@($files28 | ForEach-Object { Get-FileSha256 $_ }) -join ',') -eq $hashes28) "Case 28: Rollback did not restore files"
            Assert-True ((Get-Item $c28).GetValue('Arrow') -eq $arrow28 -and (Get-Item $s28).GetValue($large28) -eq $largeValue28) "Case 28: Cursor registry changed"
        }
        & $installPs1 @opts28 -Size $keepSize -SingleSize -SkipTrail | Out-Null
        Assert-True ((Get-Item $s28).GetValue($large28) -eq $original28) "Case 28: Unlocked retry lost the original Large scheme"
        # Reproduce the stale file left behind by an older installer after a successful-looking prune.
        [IO.File]::WriteAllBytes($side28, $sideBytes28)
        Set-ItemProperty $s28 $large28 $latest28 -Type String
        if ($keepSize -eq 'Regular') {
            & $installPs1 @opts28 -Size Regular -SingleSize -SkipTrail | Out-Null
            Assert-True (-not (Test-Path $side28)) "Case 28: Retry retained the obsolete Large backup"
        }
        & $installPs1 @opts28 -Size Large -SkipTrail | Out-Null
        & $uninstallPs1 -InstallDir $d28 -RegistryRoot $r28 -SkipCursorRefresh | Out-Null
        Assert-True ((Get-Item $s28).GetValue($large28) -eq $latest28 -and (Get-Item $s28).GetValueKind($large28) -eq 'String') "Case 28: Uninstall rolled back a newer user edit"
        Assert-True (-not (Test-Path $d28)) "Case 28: Installation or transaction backup left behind"
    }
    Write-Host "PASS Case 28: Prune locks roll back both state files; retry and stale-backup recovery preserve the latest Large scheme"

    # Case 29: -CursorZipPath supports extracted local directory, --diagnose outputs environment, and runtime log is cleaned on uninstall
    $d29 = Join-Path $testRoot 'case29_offline_dir_and_diag'
    $r29 = Join-Path $regRoot 'case29'
    $extracted29 = Join-Path $testRoot 'case29_extracted_pkg'
    Expand-Archive -Path $fixtureZip -DestinationPath $extracted29 -Force
    & $installPs1 -InstallDir $d29 -RegistryRoot $r29 -Size Regular -SingleSize -NoLaunch -NoAutoStart -SkipCursorRefresh -SkipTaskScheduler -CursorZipPath $extracted29 | Out-Null
    $exe29 = Join-Path $d29 'Bibata-Ice-Trail\BibataIceTrail.exe'
    $diagFile29 = Join-Path $testRoot 'case29_diag.txt'
    $diagProc29 = Start-Process -FilePath $exe29 -ArgumentList @('--diagnose', ('"{0}"' -f $diagFile29)) -Wait -PassThru -WindowStyle Hidden
    Assert-True ($diagProc29.ExitCode -eq 0 -and (Test-Path -LiteralPath $diagFile29 -PathType Leaf)) "Case 29: --diagnose failed"
    $diagText29 = Get-Content -LiteralPath $diagFile29 -Raw -Encoding UTF8
    Assert-True ($diagText29 -match 'BibataIceTrail Diagnostics' -and $diagText29 -match 'Job:' -and $diagText29 -match 'Monitors') "Case 29: --diagnose output missing expected sections"
    $log29 = Join-Path $d29 'Bibata-Ice-Trail\BibataIceTrail.log'
    [IO.File]::WriteAllText($log29, "sample runtime log line`r`n")
    & $uninstallPs1 -InstallDir $d29 -RegistryRoot $r29 -SkipCursorRefresh | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $log29) -and -not (Test-Path -LiteralPath $d29)) "Case 29: Runtime log or install dir left behind after uninstall"
    Write-Host "PASS Case 29: -CursorZipPath directory mode, --diagnose output, and runtime log cleanup all pass" -ForegroundColor Green

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
