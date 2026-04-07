$LicenseStatus = Get-CimInstance SoftwareLicensingProduct -Filter "Name like 'Windows%'" | Where-Object { $_.PartialProductKey }
if ($LicenseStatus.LicenseStatus -eq 1) {
    Write-Output "Device is already activated"
     exit 2 
    }
$OEMDesc = Get-CimInstance -ClassName SoftwareLicensingService | Select-Object -ExpandProperty OA3xOriginalProductKeyDescription
$DSRegCmdOuput = dsregcmd /status | select-string 'DomainJoin'
if ($DSRegCmdOuput -match 'YES') { 
    Write-Output "Device is NOT a cloud native system"
    exit 3 
}
if ($null -ne $OEMDesc -and $OEMDesc -ne '' -and $OEMDesc.Length -gt 3) {
    $WindowsEdition = switch -Regex ($OEMDesc) {
        'Professional' { 'Professional' }
        'Core' { 'Home' }
        default { $OEMDesc }
    }
    if ($WindowsEdition -ne 'Home') { 
        Write-Output "Device does not have a Home OEM, but it is a [$WindowsEdition]"
        exit 4 
    }
    Write-Output "$WindowsEdition"
    exit 0
}
else {
    Write-Output "Could not get key [$OEMDesc]: $($Error)"
    exit 5
}
