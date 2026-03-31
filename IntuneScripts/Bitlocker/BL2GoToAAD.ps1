'*******************' | Add-Content 'C:\ProgramData\Intune_Scripts\Bitlocker2Go.log'
"[$(get-date -Format 'MM/dd/yyyy hh:mm:ss')] New Bitlocker To Go encryption detected. Scanning drives..." | Add-Content 'C:\ProgramData\Intune_Scripts\Bitlocker2Go.log'
$USBDisks = Get-disk | Where-Object BusType -eq usb
$usbLetters = @()
foreach ($USBDisk in $USBDisks) {
    $usbLetters += Get-Partition -DiskId $USBDisk.Path | Where-Object driveletter -match '[A-Z]' | Select-Object -ExpandProperty DriveLetter
}

foreach ($USBDriveLetter in $usbLetters) {
    Start-Sleep -Seconds 2
    $BLV = Get-BitLockerVolume -MountPoint "$($USBDriveLetter):"
    if ($BLV.VolumeStatus -match 'Decrypted') { 
        "[$(get-date -Format 'MM/dd/yyyy hh:mm:ss')] It seems [$($USBDriveLetter):] is not encrpyted, so skipping..." | Add-Content 'C:\ProgramData\Intune_Scripts\Bitlocker2Go.log'
        continue 
    }
    "[$(get-date -Format 'MM/dd/yyyy hh:mm:ss')] We would be backing up [$($USBDriveLetter):] with protector [$(($BLV.KeyProtector | Where-Object { $_.RecoveryPassword }).KeyProtectorId)]" | Add-Content 'C:\ProgramData\EGR\Bitlocker2Go.log'
    BackupToAAD-BitLockerKeyProtector -MountPoint "$($USBDriveLetter):" -KeyProtectorId $(($BLV.KeyProtector | Where-Object { $_.RecoveryPassword }).KeyProtectorId) -ErrorAction Continue
}
'*******************' | Add-Content 'C:\ProgramData\Intune_Scripts\Bitlocker2Go.log'