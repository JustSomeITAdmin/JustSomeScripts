$startTime = Get-Date
$FileName = "WinPE-Export-Drivers.log"
try {
    $TSEnv = New-Object -COMObject Microsoft.SMS.TSEnvironment 
    $script:LogFilePath = Join-Path -Path $TSEnv.Value("_SMSTSLogPath") -ChildPath $FileName
    $WindowsPath = "$($TSEnv.Value('OSDTargetSystemDrive'))\"
}
catch {
    if (!(Test-Path "$($env:SystemDrive)\WinPELogs")) { New-Item -Path $env:SystemDrive -Name 'WinPELogs' -ItemType Directory -Force | Out-Null }
    $script:LogFilePath = Join-Path -Path "$($env:SystemDrive)\WinPELogs" -ChildPath $FileName
    $WindowsPath = "C:\"
}

function Write-CMLogEntry {
    param(
        [parameter(Mandatory = $true, HelpMessage = "Value added to the log file.")]
        [ValidateNotNullOrEmpty()]
        [string]$Value,
        
        [parameter(HelpMessage = "Severity for the log entry. 1 for Informational, 2 for Warning and 3 for Error.")]
        [ValidateNotNullOrEmpty()]
        [ValidateSet("1", "2", "3")]
        [string]$Severity = '1'
    )
    
    # Construct time stamp for log entry
    if (-not (Test-Path -Path 'variable:global:TimezoneBias')) {
        [string]$global:TimezoneBias = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
        if ($TimezoneBias -match "^-") {
            $TimezoneBias = $TimezoneBias.Replace('-', '+')
        }
        else {
            $TimezoneBias = '-' + $TimezoneBias
        }
    }
    $Time = -join @((Get-Date -Format "HH:mm:ss.fff"), $TimezoneBias)
    
    # Construct date for log entry
    $Date = (Get-Date -Format "MM-dd-yyyy")
    
    # Construct context for log entry
    $Context = $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    
    # Construct final log entry
    $LogText = "<![LOG[$($Value)]LOG]!><time=""$($Time)"" date=""$($Date)"" component=""Export-WinPE"" context=""$($Context)"" type=""$($Severity)"" thread=""$($PID)"" file="""">"
    
    # Add value to log file
    try {
        Out-File -InputObject $LogText -Append -NoClobber -Encoding Default -FilePath $LogFilePath -ErrorAction Stop
    }
    catch [System.Exception] {
        Write-Warning -Message "Unable to append log entry to $LogFilePath file. Error message at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    }
}
function timeDuration() {
    $totalSeconds = [int]$args[0]
    if ($totalSeconds -gt 0) { $time = New-TimeSpan -Seconds $totalSeconds }
    else { $time = New-TimeSpan -Seconds 600 }
    if ($time.Hours -gt 0) {
        if ($time.Hours -eq 1) { $output += "$($time.Hours) Hour" }
        else { $output += "$($time.Hours) Hours" }
    }
    if ($time.Minutes -gt 0) { 
        if ($time.Minutes -eq 1) { $output += " $($time.Minutes) Minute" } 
        else { $output += " $($time.Minutes) Minutes" }
    }
    if ($time.Seconds -gt 0) { 
        if ($time.Seconds -eq 1) { $output += " $($time.Seconds) Second" }
        else { $output += " $($time.Seconds) Seconds" }
    } 
    $output
}

Write-CMLogEntry "Grabbing all the drivers..."
$windrivers = Get-WindowsDriver -Online
$runningDrivers = Get-WmiObject -Class win32_systemdriver | Where-Object State -eq 'Running'
Write-CMLogEntry "Found $($windrivers.Count) imported drivers and $($runningDrivers.Count) running drivers"

$matchedDrivers = [System.Collections.Generic.List[PSCustomObject]]::new()
Write-CMLogEntry "Starting match driver process..."
foreach ($run in $runningDrivers) {
    $runName = $run.Name                       # e.g. "iaStorVD"
    $runPath = $run.PathName                   # e.g. X:\Windows\System32\drivers\iaStorVD.sys
    $baseNoExt = [IO.Path]::GetFileNameWithoutExtension($runPath)

    # get the hash of the running .sys file
    $runHash = (Get-FileHash -Path $runPath -Algorithm SHA256).Hash

    # Find all packages for this driver base name
    $candidates = $windrivers | Where-Object {
        [IO.Path]::GetFileNameWithoutExtension($_.CatalogFile) -ieq $baseNoExt
    }
    $foundOne = $false
    foreach ($pkg in $candidates) {
        # Derive the driver‐store folder from the INF path
        $storeFolder = Split-Path -Path $pkg.OriginalFileName

        # Build the path to the .sys in that folder
        $candidateSys = Join-Path $storeFolder ("$baseNoExt.sys")
        if (-not (Test-Path $candidateSys)) {
            Write-CMLogEntry "Skipping $($pkg.CatalogFile) - no SYS file at $candidateSys" -Severity 2
            continue
        }

        try {
            $candHash = (Get-FileHash -Path $candidateSys -Algorithm SHA256).Hash
        }
        catch {
            Write-CMLogEntry "ERROR: Could not hash $candidateSys : $_" -Severity 3
            continue
        }


        if (Test-Path $candidateSys) {
            $candHash = (Get-FileHash -Path $candidateSys -Algorithm SHA256).Hash
            #We are doing a hash match as different versions of the same driver can be imported
            if ($candHash -eq $runHash) {
                # WOW! (hubble reference)
                $matchedDrivers.Add([PSCustomObject]@{
                        DriverName       = $runName
                        DriverPath       = $runPath
                        CatalogFile      = $pkg.CatalogFile
                        OriginalFileName = $pkg.OriginalFileName
                        ClassName        = $pkg.ClassName
                        ClassGuid        = $pkg.ClassGuid
                    })
                Write-CMLogEntry "Matched $runName -> $($pkg.CatalogFile) (store = $storeFolder)"
                $foundOne = $true
                break
            }
        }
    }
    # You can uncomment this line for extreme verbose messages, but typically not needed
    # if (-not $foundOne) {
    #     Write-CMLogEntry "WARNING: No hash match found for $runName among $($candidates.Count) candidates" -Severity 2
    # }
}
if ($matchedDrivers.Count -eq 0) {
    Write-CMLogEntry "ERROR: No matched drivers at all. Exiting script." -Severity 3
    exit 1
}
Write-CMLogEntry "Completing matching imported and running drivers. Found $($matchedDrivers.count) matched drivers total."
# set up drivers folder
$exportRoot = "$($env:SystemDrive)\ExportedDrivers"

# create it if it doesn't already exist
if (-not (Test-Path $exportRoot)) {
    Write-CMLogEntry "Creating $exportRoot to export drivers"
    New-Item -Path $exportRoot -ItemType Directory | Out-Null
}
Write-CMLogEntry "Starting export process for injection"
foreach ($m in $matchedDrivers) {
    # OriginalFileName is the path to the .inf in its DriverStore folder
    $storeFolder = Split-Path -Path $m.OriginalFileName

    # pull just the leaf folder name (i.e. "iastorvd.inf_amd64_da06297c4b8e9167")
    $leafName = Split-Path -Path $storeFolder -Leaf
    $destFolder = Join-Path $exportRoot $leafName

    # copy the entire folder 
    Copy-Item -Path $storeFolder -Destination $destFolder -Recurse -Force
    Write-CMLogEntry "Copied $storeFolder -> $destFolder"
}

Write-CMLogEntry "Starting DISM injection: /Image:$WindowsPath /Add-Driver /Driver:$exportRoot /Recurse"
& Dism /Image:$WindowsPath /Add-Driver /Driver:$exportRoot /Recurse
if ($LASTEXITCODE -ne 0) {
    Write-CMLogEntry "ERROR: DISM exited with $LASTEXITCODE" -Severity 3
    throw "DISM failed."
}
else {
    Write-CMLogEntry "DISM injection completed successfully."
}
$endTime = Get-Date
$ScriptDuration = timeDuration $((New-TimeSpan -Start $startTime -End $endTime).TotalSeconds)
$ScriptDuration = $ScriptDuration.Trim()
Write-Output "Total export process took: $ScriptDuration"