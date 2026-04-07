try {
$RegKey = Get-ItemPropertyValue -LiteralPath 'HKLM:\Software\Intune_Scripts' -Name 'ProKey' -ea Ignore
$PartialKey = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Intune_Scripts" -Name "PartialKey" -ea Ignore
}
catch {
    $RegKey = $null
    $PartialKey = $null
}
$LicenseStatus = Get-CimInstance -Query "Select * FROM SoftwareLicensingProduct WHERE PartialProductKey = '$PartialKey'"
if ($LicenseStatus -and $RegKey -eq 'Installed-v1') {
    Write-Output 'Pro Key is installed'
    exit 0
}
else {
    Write-Output 'Something happened, and activation is not there'
    exit 1
}