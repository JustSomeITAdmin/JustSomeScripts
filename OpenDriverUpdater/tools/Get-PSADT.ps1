<#
.SYNOPSIS
    Fetches PSAppDeployToolkit 4.2 into the package so it becomes a complete, deployable PSADT package.

.DESCRIPTION
    The PSADT module and Invoke-AppDeployToolkit.exe are NOT committed to the repo (see .gitignore) - run this once
    after cloning, and again whenever you want to move to a newer PSADT.

    It needs NO PowerShellGet / Install-Module and never imports the module: it reads the PowerShell Gallery's v2 feed
    directly, downloads the module's nupkg (a plain zip), expands it, and copies the module folder plus the launcher
    .exe the module ships inside itself (opt\Frontend\v4) into the package root. That makes it work on a stock Windows
    PowerShell 5.1 box whose built-in PowerShellGet 1.0.0.1 has no -AllowPrerelease - which matters because this
    package requires PSADT 4.2, a release candidate until 4.2.0 ships. The script prefers the newest STABLE release
    that meets -MinimumVersion and, when none exists yet, takes the newest prerelease (rc1 today, rc2 automatically the
    day it is published, GA automatically once released). This repo's own Invoke-AppDeployToolkit.ps1 is untouched.

.PARAMETER MinimumVersion
    Lowest acceptable PSADT version. 4.2.0 is required (the launcher targets DeployAppScriptVersion 4.2.0).

.PARAMETER Version
    Pin an exact Gallery version instead, e.g. '4.2.0-rc1' or '4.2.0-rc2'. Overrides the automatic selection.

.EXAMPLE
    .\tools\Get-PSADT.ps1
.EXAMPLE
    .\tools\Get-PSADT.ps1 -Version 4.2.0-rc2
#>
[CmdletBinding()]
param(
    [string]$MinimumVersion = '4.2.0',
    [string]$Version
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$repo = Split-Path $PSScriptRoot -Parent

# --- Pick a version from the Gallery v2 feed (lists every version, prereleases included) ------------------------------
Write-Host 'Querying the PowerShell Gallery for PSAppDeployToolkit versions...'
$feed = @(Invoke-RestMethod "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='PSAppDeployToolkit'")
$entries = foreach ($e in $feed) {
    $v = "$($e.properties.Version)"
    $pre = if ($v -match '-(.+)$') { $matches[1] } else { '' }
    [pscustomobject]@{
        Version = $v
        Base    = [version]($v -replace '-.*$')
        IsPre   = [bool]$pre
        PreNum  = $(if ($pre -match '(\d+)$') { [int]$matches[1] } else { 0 })   # rc2 > rc1
        Src     = $e.content.src
    }
}
if ($Version) {
    $pick = $entries | Where-Object Version -eq $Version | Select-Object -First 1
    if (-not $pick) { throw "PSAppDeployToolkit $Version is not on the PowerShell Gallery. Available: $(($entries.Version | Select-Object -First 8) -join ', ')" }
}
else {
    $cands  = $entries | Where-Object { $_.Base -ge [version]$MinimumVersion }
    $stable = $cands | Where-Object { -not $_.IsPre } | Sort-Object Base -Descending | Select-Object -First 1
    $pick   = if ($stable) { $stable } else {
        $cands | Where-Object IsPre | Sort-Object -Property @{ Expression = 'Base'; Descending = $true }, @{ Expression = 'PreNum'; Descending = $true } | Select-Object -First 1
    }
    if (-not $pick) { throw "No PSAppDeployToolkit >= $MinimumVersion on the PowerShell Gallery." }
}
Write-Host "Selected PSAppDeployToolkit $($pick.Version)$(if ($pick.IsPre) { '  (prerelease - 4.2 is a release candidate until 4.2.0 ships; this package needs 4.2)' })"

# --- Download the nupkg (a zip), expand it, copy the module folder + the launcher .exe it ships into the package -----
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "odu-psadt-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
try {
    $null = New-Item -ItemType Directory -Path $tmp -Force
    $zip = Join-Path $tmp 'PSAppDeployToolkit.zip'     # Expand-Archive insists on a .zip extension
    Write-Host "Downloading $($pick.Src) ..."
    Invoke-WebRequest -Uri $pick.Src -OutFile $zip -UseBasicParsing
    $modSrc = Join-Path $tmp 'PSAppDeployToolkit'
    Expand-Archive -Path $zip -DestinationPath $modSrc -Force
    Get-ChildItem $modSrc -Recurse -File | Unblock-File -ErrorAction SilentlyContinue      # strip Mark-of-the-Web
    Get-ChildItem $modSrc | Where-Object Name -in '_rels', 'package', '[Content_Types].xml', 'PSAppDeployToolkit.nuspec' | Remove-Item -Recurse -Force
    if (-not (Test-Path (Join-Path $modSrc 'PSAppDeployToolkit.psd1'))) { throw 'The downloaded package does not contain PSAppDeployToolkit.psd1 at its root - unexpected nupkg layout.' }

    # The module ships its own launcher under opt\Frontend\v4 (the same file New-ADTTemplate would copy out).
    $exe = Get-ChildItem $modSrc -Recurse -Filter 'Invoke-AppDeployToolkit.exe' | Sort-Object { $_.FullName -notmatch '\\v4\\' } | Select-Object -First 1
    if (-not $exe) { throw 'Invoke-AppDeployToolkit.exe was not found inside the downloaded module.' }

    Remove-Item (Join-Path $repo 'PSAppDeployToolkit') -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item $modSrc (Join-Path $repo 'PSAppDeployToolkit') -Recurse -Force
    Copy-Item $exe.FullName (Join-Path $repo 'Invoke-AppDeployToolkit.exe') -Force
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue   # nothing was loaded from here, so nothing is locked
}
Write-Host "Done. PSAppDeployToolkit $($pick.Version) + Invoke-AppDeployToolkit.exe are in place. The package is ready to deploy."
