<#
.SYNOPSIS
  Read a saved Windows event log (.evtx) and emit selected records as JSON.

  Called by the Python evtx parser. Reads with Get-WinEvent -FilterHashtable so
  we can filter by level on the way in (default: Critical/Error/Warning), then
  writes a JSON array to -Out (UTF-8). Timestamps are converted to true UTC.

  We build the JSON array by hand (serialize each record, join with commas) to
  dodge PowerShell 5.1's habit of unwrapping single-element arrays.
#>
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Out,
    # Comma-separated levels (1=Critical 2=Error 3=Warning 4=Info 0=LogAlways).
    # A string, split here, because array params don't bind cleanly via -File.
    [string]$Levels = '1,2,3',
    [int]$Max = 20000
)

$ErrorActionPreference = 'Stop'

$levelInts = @()
if ($Levels -and $Levels.Trim()) {
    $levelInts = $Levels.Split(',') | ForEach-Object { [int]$_.Trim() }
}

function Write-Json([string]$json) {
    Set-Content -Path $Out -Value $json -Encoding UTF8
}

$records = New-Object System.Collections.ArrayList
try {
    $filter = @{ Path = $Path }
    if ($levelInts.Count -gt 0) { $filter['Level'] = $levelInts }
    $events = Get-WinEvent -FilterHashtable $filter -MaxEvents $Max -ErrorAction Stop

    foreach ($e in $events) {
        $obj = [pscustomobject]@{
            TimeCreated      = $e.TimeCreated.ToUniversalTime().ToString('o')
            Id               = $e.Id
            Level            = $e.Level
            LevelDisplayName = $e.LevelDisplayName
            Provider         = $e.ProviderName
            RecordId         = $e.RecordId
            Message          = $e.Message
        }
        [void]$records.Add(($obj | ConvertTo-Json -Depth 4 -Compress))
    }
}
catch {
    # "No events found matching the filter" is normal (a clean log) -> empty array.
    if ($_.Exception.Message -match 'No events were found') {
        Write-Json '[]'
        exit 0
    }
    Write-Json ((@{ error = $_.Exception.Message } | ConvertTo-Json -Compress))
    exit 2
}

Write-Json ('[' + ($records -join ',') + ']')
exit 0
