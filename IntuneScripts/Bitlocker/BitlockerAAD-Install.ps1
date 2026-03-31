# Bitlocker To Go - Escrow to AAD Install Script
# Downloads PSInvoker64.exe and registers scheduled task

$scriptSavePath = "C:\ProgramData\Intune_Scripts"

# Create directory if it doesn't exist
if (-not (Test-Path $scriptSavePath)) {
    New-Item -ItemType Directory -Path $scriptSavePath -Force
}

# Copy the main script
Copy-Item "$(Join-Path $PSScriptRoot 'BL2GoToAAD.ps1')" -Destination $scriptSavePath -Force

# Download PSInvoker64.exe if not present
# This runs PowerShell scripts hidden in 64-bit mode
if (-not (Test-Path "$scriptSavePath\PSInvoker64.exe")) {
    $URI = 'https://github.com/JustSomeITAdmin/JustSomeScripts/raw/main/bin/Invoke-AppDeployToolkit.exe'
    $hashCheck = "F36C52BFDB14918B6ACC55C5D0CF13E0AB28AAEA913D244110C05FDEB1844E5C"
    try {
        Start-BitsTransfer -Source $URI -Destination "$env:TEMP\PSInvoker64.exe"
        if ((Get-FileHash -Path "$env:TEMP\PSInvoker64.exe" -Algorithm SHA256).Hash -eq $hashCheck) {
            Copy-Item -Path "$env:TEMP\PSInvoker64.exe" -Destination "$scriptSavePath\PSInvoker64.exe"
        }
        else {
            Write-Output "Hash mismatch - PSInvoker64.exe download failed verification"
            exit 1
        }
    }
    catch {
        Write-Output "Failed to download PSInvoker64.exe: $_"
        exit 1
    }
}
Unblock-File -Path "$scriptSavePath\PSInvoker64.exe" -ErrorAction SilentlyContinue

# Register the scheduled task
Register-ScheduledTask -xml (Get-Content "$(Join-Path $PSScriptRoot 'BL2GOEscrowtoAAD.xml')" | Out-String) -TaskName "BL2GOEscrowtoAAD" -Force
