$WorkingDirectory = "$($env:TEMP)\WinRE-Stuff"
Start-Transcript "$($env:TEMP)\Winre.log"
#$DriverName = 'iastorvd.inf'
$DriverDir = "$env:temp\DrvTemp"
#Get the driver(s) from the driver store
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
            Write-Output "[$($_.driver) / $BaseName] is a match to [$($RunningDriver.pathName)] in the $($_.ClassName) class!" 
            $MatchedStorageDrivers += $_
        } 
    }
}

#Only run this part if a driver was found, otherwise, it could error
if ($MatchedStorageDrivers) {
    if (!(Test-Path -Path $DriverDir)) {
        New-Item -Path $DriverDir -ItemType Directory
    }
    #This is use to export the driver(s), I suppose Export-WindowsDriver could be used as well
    $MatchedStorageDrivers | ForEach-Object { pnputil.exe /export-driver $_.Driver $DriverDir }
    # a failed Patch-WinRE run leaves an Invalid orphaned mount of winre.wim in the mount dir
    # that blocks every later run at the mount step - and it is invisible to Get-ChildItem 
    # and Get-WindowsImage -Mounted (returns nothing); only Cleanup-Mountpoints clears it, and it
    # leaves valid mounts alone, so run it unconditionally rather than gating on those blind checks.
    Write-Output "Clearing stale/orphaned DISM mount points"
    & dism.exe /Cleanup-Mountpoints
    Remove-Item -Recurse -Force "$WorkingDirectory\Mount\*" -ErrorAction SilentlyContinue
    # PS 5.1 cannot read \\?\Volume{...} paths, so Patch-WinRE's backup step dies whenever
    # WinRE is enabled (wim lives on the recovery volume). Disabling WinRE parks winre.wim at
    # C:\Windows\System32\Recovery (a plain path); Patch-WinRE re-enables it when it completes.
    & reagentc.exe /disable | Out-Null
    & powershell.exe -file $(Join-Path $PSScriptRoot 'Patch-WinRE.ps1') -WorkingDirectory $WorkingDirectory -FilesDriver $DriverDir -RecoveryDriveSizeInGB 2GB -BackupDirectory "$WorkingDirectory\Backups" -MountDirectory "$WorkingDirectory\Mount" -LogDirectory "$WorkingDirectory\Logs"
    Write-Output "Last exit code was: $LASTEXITCODE"
    if ($LASTEXITCODE -eq 0) { 
        if ((Test-Path -LiteralPath "HKLM:\SOFTWARE\WinRE") -ne $true) { New-Item "HKLM:\SOFTWARE\WinRE" -force -ea SilentlyContinue }
        New-ItemProperty -LiteralPath "HKLM:\SOFTWARE\WinRE" -Name 'WinRE-All-Inject' -Value Installed -PropertyType String -Force -ErrorAction SilentlyContinue 
    }
    else { exit $LASTEXITCODE }
}
else { exit 1 }