try {
    $taskName = Get-ScheduledTask -TaskName "BL2GOEscrowtoAAD" -ErrorAction Stop
    $ScriptCheck = Test-Path 'C:\ProgramData\Intune_Scripts\BL2GoToAAD.ps1'
    if ($taskName -and $ScriptCheck) {
        if ($taskName.Principal.UserId -eq 'SYSTEM' -and $taskName.State -eq 'Ready' ) {
            Write-Output "Task is created, everything checks out"
            exit 0
        }
        else {
            Write-Output "Task is not properly configured"
            exit 1
        }
    }
    else {
        Write-Output "Something bad happened"
        exit 1
    }
}
catch {
    Write-Output "Seems task may not be created"
    exit 1
}