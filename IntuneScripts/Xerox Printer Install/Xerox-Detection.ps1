<#
    Intune Win32 custom detection script for the Xerox Printer Install app.

    Deliberately "self-clearing" so the app stays re-runnable from Company Portal: the install writes a
    marker, this script reports "installed" the first time it sees it AND deletes it, so the next Intune
    detection cycle reports "not installed" -> Company Portal shows Install again.

    IMPORTANT:
      * Deploy the app as AVAILABLE, never Required (a Required app would reinstall every detection cycle).
      * The key + value name below MUST match the Set-ADTRegistryKey call at the end of
        Invoke-AppDeployToolkit.ps1 (Post-Install).
      * In Intune, set "Run this detection script using the logged-on credentials" = No, and
        "Run script as 32-bit process" = No (the marker lives in the 64-bit registry view).
#>

$RegPath  = 'HKLM:\SOFTWARE\IntunePrinters'
$RegName  = 'XeroxPrinter'

try {
    $marker = Get-ItemPropertyValue -LiteralPath $RegPath -Name $RegName -ErrorAction Ignore
}
catch {
    $marker = $null
}

if ($null -ne $marker) {
    # Marker present -> report installed, then clear it so the app is offered again next cycle.
    Write-Output 'Installed'
    Remove-ItemProperty -LiteralPath $RegPath -Name $RegName -Force -ErrorAction SilentlyContinue
    exit 0
}
else {
    # Marker absent -> not installed.
    exit 1
}
