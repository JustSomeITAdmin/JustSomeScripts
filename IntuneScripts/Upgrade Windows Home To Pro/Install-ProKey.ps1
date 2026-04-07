$ProductKey = 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX' #replace with your MAK key
$InstallVersion = 'v1'
$PartialKey = $ProductKey.Split('-')[-1]


Get-CimInstance SoftwareLicensingService | Invoke-CimMethod -MethodName InstallProductKey -Arguments @{ProductKey = $ProductKey } | Out-Null
Start-Sleep -Seconds 5
Get-CimInstance SoftwareLicensingService | Invoke-CimMethod -MethodName RefreshLicenseStatus | Out-Null

if (!(Test-Path -Path "HKLM:\SOFTWARE\Intune_Scripts")) {
    New-Item -Path "HKLM:\SOFTWARE\Intune_Scripts" -Force
}
New-ItemProperty -Path "HKLM:\SOFTWARE\Intune_Scripts" -Name "ProKey" -Value "Installed-$InstallVersion" -PropertyType "String" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Intune_Scripts" -Name "PartialKey" -Value "$PartialKey" -PropertyType "String" -Force | Out-Null