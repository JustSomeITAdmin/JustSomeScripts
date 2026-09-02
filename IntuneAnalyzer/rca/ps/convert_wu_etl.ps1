<#
.SYNOPSIS
  Merge WindowsUpdate *.etl traces into a readable WindowsUpdate.log via the
  built-in Get-WindowsUpdateLog decoder. Called on demand by the ETL loader.
#>
param(
    [Parameter(Mandatory = $true)][string]$EtlDir,
    [Parameter(Mandatory = $true)][string]$Out
)
$ErrorActionPreference = 'Stop'
try {
    # Suppress the cmdlet's verbose per-file report; we only need the log file.
    Get-WindowsUpdateLog -ETLPath $EtlDir -LogPath $Out *> $null
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 2
}
if (Test-Path $Out) {
    Write-Output "OK $((Get-Item $Out).Length)"
}
else {
    Write-Output "ERROR: no output produced"
    exit 3
}
