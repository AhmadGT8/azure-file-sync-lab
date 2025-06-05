# MainVmSetup.ps1
param (
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$StorageSyncServiceName,
    [Parameter(Mandatory=$true)][string]$SyncGroupName,
    [Parameter(Mandatory=$true)][string]$StorageAccountName,
    [Parameter(Mandatory=$true)][string]$FileShareName,
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$TenantId,
    [Parameter(Mandatory=$false)][string]$VmLocation, # Included for flexibility, though not directly used in this script's core logic
    [Parameter(Mandatory=$false)][string]$ServerEndpointLocalPath = 'C:\SyncFolder' # Default from your original setup
)

try {
    $ErrorActionPreference = 'Stop' # Ensure script stops on unhandled errors
    $global:ProgressPreference = 'SilentlyContinue' # Reduce progress bar noise in logs
    Write-Host "Starting MainVmSetup.ps1 execution..."
    Write-Host "Parameters received: RG='$ResourceGroupName', SSSvc='$StorageSyncServiceName', SyncGroup='$SyncGroupName', SA='$StorageAccountName', Share='$FileShareName', SubId='$SubscriptionId', TenantId='$TenantId', VMLoc='$VmLocation', LocalPath='$ServerEndpointLocalPath'"

    # --- Begin PrepareServer Logic (IE ESC Disabling) ---
    Write-Host "Executing PrepareServer logic (IE ESC)..."
    $prepareServerLogOutput = @()
    $prepareServerLogOutput += ('Starting PrepareServer logic at ' + (Get-Date -Format o))
    $installationType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType
    $prepareServerLogOutput += ('InstallationType: ' + $installationType)

    if ($installationType -ne 'Server Core') {
        $prepareServerLogOutput += 'Non-Server Core detected. Processing IE ESC.'
        $keyPath1 = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'
        $keyPath2 = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}'

        if (Test-Path $keyPath1) {
            Set-ItemProperty -Path $keyPath1 -Name 'IsInstalled' -Value 0 -Force
            $prepareServerLogOutput += ("Set IsInstalled=0 for $keyPath1.")
        } else {
            $prepareServerLogOutput += ("Registry key not found, skipping: $keyPath1.")
        }

        if (Test-Path $keyPath2) {
            Set-ItemProperty -Path $keyPath2 -Name 'IsInstalled' -Value 0 -Force
            $prepareServerLogOutput += ("Set IsInstalled=0 for $keyPath2.")
        } else {
            $prepareServerLogOutput += ("Registry key not found, skipping: $keyPath2.")
        }
        Stop-Process -Name iexplore -ErrorAction SilentlyContinue
        # Storing $? immediately after the command it relates to.
        $stopProcessSuccess = $?
        $prepareServerLogOutput += ('Attempted to stop iexplore. Success status of Stop-Process: ' + $stopProcessSuccess)
    } else {
        $prepareServerLogOutput += 'Server Core detected. IE ESC configuration skipped.'
    }
    $prepareServerLogOutput += 'PrepareServer logic completed.'
    Write-Output ($prepareServerLogOutput -join [System.Environment]::NewLine)
    Write-Host "PrepareServer logic (IE ESC) finished successfully."
    # --- End PrepareServer Logic ---

    Write-Host "Proceeding to Azure File Sync agent setup."

    # --- Begin Azure File Sync Agent Setup Logic ---
   # Add this command to pre-install the NuGet provider non-interactively
Write-Host "Ensuring NuGet provider is installed to prevent interactive prompts..."
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force

# 1) Install / Import Az.Accounts and Az.StorageSync modules if missing
Write-Host "Checking/Installing Az PowerShell modules..."
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Host "Installing Az.Accounts module..."
    # Using -Scope CurrentUser is still the recommended approach here
    Install-Module -Name Az.Accounts -Confirm:$false -Force -Scope CurrentUser -SkipPublisherCheck -AllowClobber
}
Import-Module Az.Accounts -ErrorAction Stop

if (-not (Get-Module -ListAvailable -Name Az.StorageSync)) {
    Write-Host "Installing Az.StorageSync module..."
    Install-Module -Name Az.StorageSync -Confirm:$false -Force -Scope CurrentUser -SkipPublisherCheck -AllowClobber
}
Import-Module Az.StorageSync -ErrorAction Stop
Write-Host "Az PowerShell modules are ready."

    # 2) Connect via the VM's managed identity
    Write-Host "Connecting to Azure via VM Managed Identity (Subscription: $SubscriptionId, Tenant: $TenantId)..."
    Connect-AzAccount -Identity -SubscriptionId $SubscriptionId -TenantId $TenantId -ErrorAction Stop
    Write-Host "Successfully connected to Azure."

    # 3) IE ESC is already handled above.

    # 4) Ensure the local path exists for the server endpoint
    Write-Host "Ensuring local path '$ServerEndpointLocalPath' exists..."
    if (-not (Test-Path -Path $ServerEndpointLocalPath)) {
        New-Item -ItemType Directory -Force -Path $ServerEndpointLocalPath
        Write-Host "Created directory: $ServerEndpointLocalPath"
    } else {
        Write-Host "Directory '$ServerEndpointLocalPath' already exists."
    }

    # 5) Download & install the Azure File Sync agent MSI
    Write-Host "Determining OS version for Azure File Sync agent download..."
    $osVer = [System.Environment]::OSVersion.Version
    $agentUri = $null
    # Using -like for build numbers to be more flexible with minor revisions
    if ($osVer.Major -eq 10 -and $osVer.Minor -eq 0 -and $osVer.Build -eq 17763) { # Windows Server 2019 (10.0.17763.xxxx)
        $agentUri = "https://aka.ms/afs/agent/Server2019"
    } elseif ($osVer.Major -eq 10 -and $osVer.Minor -eq 0 -and $osVer.Build -eq 20348) { # Windows Server 2022 (10.0.20348.xxxx)
        $agentUri = "https://aka.ms/afs/agent/Server2022"
    } elseif ($osVer.Major -eq 10 -and $osVer.Minor -eq 0 -and $osVer.Build -eq 14393) { # Windows Server 2016 (10.0.14393.xxxx)
        $agentUri = "https://aka.ms/afs/agent/Server2016"
    } elseif ($osVer.Major -eq 6 -and $osVer.Minor -eq 3 -and $osVer.Build -eq 9600) { # Windows Server 2012 R2 (6.3.9600.xxxx)
        $agentUri = "https://aka.ms/afs/agent/Server2012R2"
    } else {
        throw [System.PlatformNotSupportedException]::new("Azure File Sync agent is only supported on Windows Server 2012 R2, 2016, 2019, 2022. Detected OS Version: $osVer")
    }
    Write-Host "Agent download URI for OS Version $osVer is: $agentUri"

    $msiTempPath = Join-Path $env:TEMP "StorageSyncAgent.msi"
    $msiLogPath = Join-Path $env:TEMP "afsagentmsi.log"
    Write-Host "Downloading Azure File Sync agent to '$msiTempPath'..."
    Invoke-WebRequest -Uri $agentUri -OutFile $msiTempPath -UseBasicParsing
    Write-Host "Download complete. Installing agent (log: '$msiLogPath')..."
    Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", "`"$msiTempPath`"", "/quiet", "/norestart", "/L*V", "`"$msiLogPath`"" -Wait
    Write-Host "Agent installation process completed. Check MSI log for details."
    # Consider checking MSI exit code or log for success if needed

    # 6) Register this server in the Storage Sync Service
    Write-Host "Registering server '$($env:COMPUTERNAME)' in Storage Sync Service '$StorageSyncServiceName' (Resource Group '$ResourceGroupName')..."
    Register-AzStorageSyncServer -StorageSyncServiceName $StorageSyncServiceName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    Write-Host "Server registration initiated/completed." # Register-AzStorageSyncServer is synchronous

    # Retrieve the registered server object to get its ResourceId
    Write-Host "Retrieving registered server details..."
    $registeredServer = Get-AzStorageSyncServer -StorageSyncServiceName $StorageSyncServiceName -ResourceGroupName $ResourceGroupName -ServerFriendlyName $env:COMPUTERNAME -ErrorAction Stop
    if (-not $registeredServer) {
        throw "Failed to retrieve registered server details for server '$($env:COMPUTERNAME)' after registration attempt."
    }
    Write-Host "Successfully retrieved registered server. ResourceId: $($registeredServer.ResourceId)"

    # 7) Create the server endpoint under that Sync Service / Sync Group
    Write-Host "Retrieving storage account '$StorageAccountName'..."
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
    if (-not $storageAccount) {
        throw "Failed to retrieve storage account '$StorageAccountName' in resource group '$ResourceGroupName'."
    }
    Write-Host "Storage Account ResourceId: $($storageAccount.Id)"

    # Generate a somewhat unique name for the server endpoint to avoid conflicts
    $endpointNameSuffix = ($ServerEndpointLocalPath -replace '[:\s]', '_' -replace '__', '_').Trim('_')
    $serverEndpointName = "$($env:COMPUTERNAME)_$endpointNameSuffix"
    # Truncate if too long (max 128 chars for server endpoint name)
    if ($serverEndpointName.Length -gt 128) { $serverEndpointName = $serverEndpointName.Substring(0, 128) }


    Write-Host "Creating server endpoint '$serverEndpointName' for local path '$ServerEndpointLocalPath' in sync group '$SyncGroupName'..."
    New-AzStorageSyncServerEndpoint `
        -ResourceGroupName $ResourceGroupName `
        -StorageSyncServiceName $StorageSyncServiceName `
        -SyncGroupName $SyncGroupName `
        -Name $serverEndpointName `
        -ServerResourceId $registeredServer.ResourceId `
        -StorageAccountResourceId $storageAccount.Id `
        -AzureFileShareName $FileShareName `
        -ServerLocalPath $ServerEndpointLocalPath `
        -ErrorAction Stop

    Write-Host "Server endpoint '$serverEndpointName' created successfully."
    # --- End Azure File Sync Agent Setup Logic ---

    Write-Host "MainVmSetup.ps1 completed all tasks successfully."
    exit 0 # Explicitly exit with 0 for success

} catch {
    $errorMessage = $_ | Out-String # Catches detailed error information, including line numbers
    Write-Host "ERROR in MainVmSetup.ps1: $errorMessage" -ForegroundColor Red
    Write-Error "ERROR in MainVmSetup.ps1: $errorMessage" # Write to error stream for CSE to pick up
    # You might want to add specific cleanup here if needed (e.g., MSI uninstall on failure)
    exit 1 # Explicitly exit with 1 for failure
} finally {
    # Optional: Clean up downloaded MSI if it still exists and you want to ensure it's gone
    Write-Host "Entering finally block for cleanup..."
    # Check if $msiTempPath is not null or empty before trying to use it
    if (-not ([string]::IsNullOrEmpty($msiTempPath)) -and (Test-Path -LiteralPath $msiTempPath)) {
        Write-Host "Cleaning up temporary MSI file: $msiTempPath"
        Remove-Item -Path $msiTempPath -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "MSI temp file path not defined or file does not exist. Skipping cleanup."
    }
    Write-Host "--- Stopping Transcript ---"
    Stop-Transcript
}
