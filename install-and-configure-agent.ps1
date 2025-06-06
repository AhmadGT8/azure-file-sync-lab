param (
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$StorageSyncServiceName,
    [Parameter(Mandatory=$true)][string]$SyncGroupName,
    [Parameter(Mandatory=$true)][string]$StorageAccountName,
    [Parameter(Mandatory=$true)][string]$FileShareName,
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$TenantId,
    [Parameter(Mandatory=$false)][string]$VmLocation,
    [Parameter(Mandatory=$false)][string]$ServerEndpointLocalPath = 'C:\SyncFolder'
)

$transcriptLogPath = Join-Path $env:TEMP "AzureFileSync-CSE-Transcript.txt"

try {
    Start-Transcript -Path $transcriptLogPath -Append
    
    $ErrorActionPreference = 'Stop'
    $global:ProgressPreference = 'SilentlyContinue'
    Write-Host "--- Starting Script Execution (Log: $transcriptLogPath) ---"
    Write-Host "Timestamp: $(Get-Date -Format o)"

    # --- Begin IE ESC Disabling Logic ---
    Write-Host "Executing IE ESC logic..."
    $installationType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType
    if ($installationType -ne 'Server Core') {
        $keyPath1 = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'
        $keyPath2 = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}'
        if (Test-Path $keyPath1) { Set-ItemProperty -Path $keyPath1 -Name 'IsInstalled' -Value 0 -Force }
        if (Test-Path $keyPath2) { Set-ItemProperty -Path $keyPath2 -Name 'IsInstalled' -Value 0 -Force }
        Stop-Process -Name iexplore -ErrorAction SilentlyContinue
    }
    Write-Host "IE ESC logic finished."
    # --- End IE ESC Logic ---

    # --- Begin Module Installation Logic (REVISED) ---
    Write-Host "Ensuring NuGet provider is installed..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force

    # Forcing installation of Az modules to overwrite any corrupted existing modules.
    # The 'if' check has been removed to ensure this runs every time.
    Write-Host "Forcing installation/update of Az.Accounts module (using -Scope CurrentUser)..."
    Install-Module -Name Az.Accounts -Confirm:$false -Force -Scope CurrentUser -SkipPublisherCheck -AllowClobber

    Write-Host "Forcing installation/update of Az.StorageSync module (using -Scope CurrentUser)..."
    Install-Module -Name Az.StorageSync -Confirm:$false -Force -Scope CurrentUser -SkipPublisherCheck -AllowClobber

    Write-Host "Importing Az modules..."
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.StorageSync -ErrorAction Stop
    Write-Host "Az PowerShell modules are ready."
    # --- End Module Installation Logic ---

    # --- Begin Agent Setup Logic (Unchanged from here) ---
    Write-Host "Connecting to Azure via VM Managed Identity..."
    Connect-AzAccount -Identity -SubscriptionId $SubscriptionId -TenantId $TenantId -ErrorAction Stop
    
    Write-Host "Ensuring local path '$ServerEndpointLocalPath' exists..."
    if (-not (Test-Path -Path $ServerEndpointLocalPath)) {
        New-Item -ItemType Directory -Force -Path $ServerEndpointLocalPath
    }

    Write-Host "Determining OS version for agent download..."
    $osVer = [System.Environment]::OSVersion.Version
    $agentUri = switch -regex ($osVer.ToString()){
        '^10.0.17763' { "https://aka.ms/afs/agent/Server2019"; break }
        '^10.0.20348' { "https://aka.ms/afs/agent/Server2022"; break }
        '^10.0.14393' { "https://aka.ms/afs/agent/Server2016"; break }
        '^6.3.9600'   { "https://aka.ms/afs/agent/Server2012R2"; break }
        default { throw "Azure File Sync agent is not supported on OS Version: $osVer" }
    }
    
    $msiTempPath = Join-Path $env:TEMP "StorageSyncAgent.msi"
    $msiLogPath = Join-Path $env:TEMP "afsagentmsi.log"
    Write-Host "Downloading agent to '$msiTempPath'..."
    Invoke-WebRequest -Uri $agentUri -OutFile $msiTempPath -UseBasicParsing
    
    Write-Host "Installing agent (log: '$msiLogPath')..."
    Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", "`"$msiTempPath`"", "/quiet", "/norestart", "/L*V", "`"$msiLogPath`"" -Wait

    Write-Host "Registering server '$($env:COMPUTERNAME)'..."
    Register-AzStorageSyncServer -StorageSyncServiceName $StorageSyncServiceName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    
    Write-Host "Retrieving registered server details..."
    $registeredServer = Get-AzStorageSyncServer -StorageSyncServiceName $StorageSyncServiceName -ResourceGroupName $ResourceGroupName -ServerFriendlyName $env:COMPUTERNAME -ErrorAction Stop
    if (-not $registeredServer) { throw "Failed to retrieve registered server details for '$($env:COMPUTERNAME)'." }

    Write-Host "Retrieving storage account '$StorageAccountName'..."
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
    
    $endpointNameSuffix = ($ServerEndpointLocalPath -replace '[:\s]', '_' -replace '__', '_').Trim('_')
    $serverEndpointName = "$($env:COMPUTERNAME)_$endpointNameSuffix"
    if ($serverEndpointName.Length -gt 128) { $serverEndpointName = $serverEndpointName.Substring(0, 128) }
    
    Write-Host "Creating server endpoint '$serverEndpointName'..."
    New-AzStorageSyncServerEndpoint -ResourceGroupName $ResourceGroupName -StorageSyncServiceName $StorageSyncServiceName -SyncGroupName $SyncGroupName -Name $serverEndpointName -ServerResourceId $registeredServer.ResourceId -StorageAccountResourceId $storageAccount.Id -AzureFileShareName $FileShareName -ServerLocalPath $ServerEndpointLocalPath -ErrorAction Stop
    Write-Host "Server endpoint created successfully."

    Write-Host "--- SCRIPT COMPLETED SUCCESSFULLY ---"
    exit 0

} catch {
    $errorMessage = $_ | Out-String
    Write-Host "---!!! SCRIPT FAILED !!!---"
    Write-Host "Caught an error. See details below."
    Write-Error $errorMessage
    exit 1

} finally {
    Write-Host "--- Entering Finally block. Stopping Transcript. ---"
    Stop-Transcript -ErrorAction SilentlyContinue
}
