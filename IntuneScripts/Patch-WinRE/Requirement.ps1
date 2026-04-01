$StorageDrivers = Get-WindowsDriver -Online -All | Where-Object { $_.Inbox -eq $False -and $_.BootCritical -eq $True }#-and $_.ClassName -eq 'SCSIAdapter' } 
$runningDrivers = Get-WmiObject -Class win32_systemdriver | Where-Object State -eq 'Running'
$MatchedStorageDrivers = @()
$StorageDrivers | ForEach-Object {
    $DrvPath = Split-Path $_.OriginalFileName -Parent
    $BaseName = [IO.Path]::GetFileNameWithoutExtension($_.OriginalFileName)
    $RunningDriver = $runningDrivers | Where-Object Name -eq $BaseName
    if ($runningDriver) { 
        #Write-Output "Matched store [$($_.OriginalFileName)] with running driver [$($RunningDriver.PathName)]"
        $hashStore = Get-FileHash -Path $(Join-Path $DrvPath "$BaseName.sys") -Algorithm SHA256 | Select-Object -ExpandProperty hash
        $hashRunning = Get-FileHash -Path $RunningDriver.pathName -Algorithm SHA256 | Select-Object -ExpandProperty Hash
        if ($hashstore -eq $hashrunning) { 
            #Write-Output "[$($_.driver) / $BaseName] is a match to [$($RunningDriver.pathName)] in the $($_.ClassName) class!" 
            $MatchedStorageDrivers += $_
        } 
    }
}


if ($MatchedStorageDrivers) {
    Write-Output "Matched drivers found"
    exit 0
}
else {
    exit 1
}