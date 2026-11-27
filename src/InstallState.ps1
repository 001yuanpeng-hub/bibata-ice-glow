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

function Write-BibataFileAtomically([string]$path, [byte[]]$bytes) {
    $temp = Join-Path ([IO.Path]::GetDirectoryName($path)) ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, $bytes)
        if ([IO.File]::Exists($path)) {
            [IO.File]::Replace($temp, $path, [System.Management.Automation.Language.NullString]::Value)
        }
        else {
            [IO.File]::Move($temp, $path)
        }
    }
    finally {
        [IO.File]::Delete($temp)
    }
}

function Write-BibataJson([string]$path, $value) {
    $json = ConvertTo-Json -InputObject $value -Depth 6
    Write-BibataFileAtomically $path ([Text.Encoding]::UTF8.GetBytes($json))
}

function Read-BibataRuntimeSchemes([string]$path) {
    $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
    $parsed = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    # Assign before enumerating: Windows PowerShell 5.1 emits the JSON array as one pipeline object.
    $records = @($parsed)
    $needsRepair = $false
    while ($records.Count -eq 1 -and $null -ne $records[0] -and
           $records[0].PSObject.Properties['value'] -and $records[0].PSObject.Properties['Count']) {
        # Older single-size installs serialized the PowerShell array wrapper.
        $records = @($records[0].value)
        $needsRepair = $true
    }
    foreach ($record in $records) {
        if ([string]::IsNullOrWhiteSpace($record.name) -or $record.existedBefore -isnot [bool]) {
            throw "Invalid cursor scheme backup '$path'."
        }
    }
    return [pscustomobject]@{ Records = $records; NeedsRepair = $needsRepair }
}
