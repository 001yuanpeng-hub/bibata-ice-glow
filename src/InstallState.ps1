function Read-BibataManifest([string]$path) {
    if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) { return $null }
    try {
        $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        $state = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if ($json.Trim() -notlike '{*}' -or $state.schemaVersion -notin @(1, 2, 3) -or
            $state.managedCursor -isnot [bool] -or $state.managedTrail -isnot [bool]) {
            throw "Expected an installation manifest with cursor and trail ownership information."
        }
        return $state
    }
    catch {
        throw "Cannot read installation manifest '$path': $($_.Exception.Message)"
    }
}

function Write-BibataFileAtomically([string]$path, [byte[]]$bytes, $backupPath = [System.Management.Automation.Language.NullString]::Value) {
    $temp = Join-Path ([IO.Path]::GetDirectoryName($path)) ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, $bytes)
        if ([IO.File]::Exists($path)) {
            [IO.File]::Replace($temp, $path, $backupPath)
        }
        else {
            [IO.File]::Move($temp, $path)
        }
    }
    finally {
        [IO.File]::Delete($temp)
    }
}

function Write-BibataJson([string]$path, $value, $backupPath = [System.Management.Automation.Language.NullString]::Value) {
    $json = ConvertTo-Json -InputObject $value -Depth 6
    Write-BibataFileAtomically $path ([Text.Encoding]::UTF8.GetBytes($json)) $backupPath
}

function Read-BibataRuntimeSchemes([string]$path) {
    if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) { return $null }
    try {
        $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        # Preserve the root array, including empty and single-record backups, on both PowerShell versions.
        $options = @{}
        if ($PSVersionTable.PSVersion.Major -ge 7) { $options.NoEnumerate = $true }
        $records = ConvertFrom-Json -InputObject $json -ErrorAction Stop @options
        if ($records -isnot [array]) { throw "Expected an array of cursor scheme records." }
        $needsRepair = $false
        while ($records.Count -eq 1 -and $null -ne $records[0] -and
               $records[0].PSObject.Properties['value'] -and $records[0].PSObject.Properties['Count']) {
            # Older single-size installs serialized the PowerShell array wrapper.
            $wrapper = $records[0]
            $items = $wrapper.value
            # Windows PowerShell can nest the wrapper on successive saves.
            if ($null -eq $items -or $wrapper.Count -ne $items.Count -or
                ($items -isnot [array] -and -not $items.PSObject.Properties['value'])) { throw "Invalid cursor scheme array wrapper." }
            $records = @($items)
            $needsRepair = $true
        }
        foreach ($record in $records) {
            if ($record -isnot [pscustomobject] -or $record.name -isnot [string] -or [string]::IsNullOrWhiteSpace($record.name) -or
                $record.existedBefore -isnot [bool] -or ($record.existedBefore -and $record.previousValue -isnot [string]) -or
                $record.writtenValue -isnot [string] -or [string]::IsNullOrWhiteSpace($record.writtenValue)) {
                throw "Invalid cursor scheme backup record."
            }
        }
        return [pscustomobject]@{ Records = $records; NeedsRepair = $needsRepair }
    }
    catch {
        throw "Cannot read cursor scheme backup '$path': $($_.Exception.Message)"
    }
}
