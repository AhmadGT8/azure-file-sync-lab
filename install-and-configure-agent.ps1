# Final, Combined Script for Azure File Sync Agent Installation and Configuration
# This script performs all steps: IE ESC configuration, module setup from a ZIP, and agent installation.
param (
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$StorageSyncServiceName,
    [Parameter(Mandatory=$true)][string]$SyncGroupName,
    [Parameter(Mandatory=$true)][string]$StorageAccountName,
    [Parameter(Mandatory=$true)][string]$FileShareName,
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$TenantId
)

# Use a reliable path in the system's temp directory for the transcript log file.
$transcriptLogPath = Join-Path $env:TEMP "AzureFileSync-CSE-Transcript.txt"

try {
    # Start-Transcript captures ALL console output (including verbose streams and errors) to a log file for easy debugging.
    Start-Transcript -Path $transcriptLogPath -Append
    
    $ErrorActionPreference = 'Stop'
    $global:ProgressPreference = 'SilentlyContinue'
    Write-Host "--- Starting Script Execution with Pre-Packaged Modules ---"
    Write-Host "Timestamp: $(Get-Date -Format o)"
    
    #================================================================================
    # SECTION 1: PRE-PACKAGED MODULE SETUP
    #================================================================================
    # This section unpacks and loads the PowerShell modules from AzureModules.zip,
    # completely bypassing the problematic Install-Module command.
    
    # The AzureModules.zip file is in the same directory as this script after being downloaded by the Custom Script Extension.
    $modulesZipPath = ".\AzureModules.zip"
    $modulesInstallPath = Join-Path $env:TEMP "Modules"

    Write-Host "Expanding pre-packaged modules from '$modulesZipPath' to '$modulesInstallPath'..."
    Expand-Archive -Path $modulesZipPath -DestinationPath $modulesInstallPath -Force

    Write-Host "Adding '$modulesInstallPath' to the PowerShell module path for this session..."
    $env:PSModulePath = "$modulesInstallPath;" + $env:PSModulePath

    Write-Host "Importing Az modules from pre-packaged location..."
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.StorageSync -ErrorAction Stop
    Write-Host "Az modules imported successfully."
    
    #================================================================================
    # SECTION 2: IE ENHANCED SECURITY CONFIGURATION (ESC)
    #================================================================================
    # This section disables IE ESC for easier server management, as discussed.
    
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

    #================================================================================
    # SECTION 3: AZURE FILE SYNC AGENT INSTALLATION & REGISTRATION
    #================================================================================
    # This is the core logic to download, install, and configure the sync agent.

    Write-Host "Connecting to Azure via VM Managed Identity..."
    Connect-AzAccount -Identity -SubscriptionId $SubscriptionId -TenantId $TenantId -ErrorAction Stop
    
    $ServerEndpointLocalPath = 'C:\SyncFolder'
    Write-Host "Ensuring local path '$ServerEndpointLocalPath' exists..."
    if (-not (Test-Path -Path $ServerEndpointLocalPath)) {
        New-Item -ItemType Directory -Force -Path $ServerEndpointLocalPath
    }

    Write-Host "Determining OS version for agent download..."
    $osVer = [System.Environment]::OSVersion.Version
    $agentUri = switch -regex ($osVer.ToString()){
        '^10.0.17763' { "https://aka.ms/afs/agent/Server2019"; break }
        '^10.0.20348' { "https://aka.ms/afs/agent/Server2022"; break }
        default { throw "OS Version not supported for AFS Agent: $osVer" }
    }
    
    $msiTempPath = Join-Path $env:TEMP "StorageSyncAgent.msi"
    Write-Host "Downloading agent to '$msiTempPath'..."
    Invoke-WebRequest -Uri $agentUri -OutFile $msiTempPath -UseBasicParsing
    
    Write-Host "Installing agent..."
    Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", "`"$msiTempPath`"", "/quiet", "/norestart" -Wait

    Write-Host "Registering server '$($env:COMPUTERNAME)'..."
    Register-AzStorageSyncServer -StorageSyncServiceName $StorageSyncServiceName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    
    $registeredServer = Get-AzStorageSyncServer -StorageSyncServiceName $StorageSyncServiceName -ResourceGroupName $ResourceGroupName -ServerFriendlyName $env:COMPUTERNAME -ErrorAction Stop
    if (-not $registeredServer) { throw "Failed to retrieve registered server details." }

    $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
    
    $endpointNameSuffix = ($ServerEndpointLocalPath -replace '[:\s]', '_' -replace '__', '_').Trim('_')
    $serverEndpointName = "$($env:COMPUTERNAME)_$endpointNameSuffix"
    
    Write-Host "Creating server endpoint '$serverEndpointName'..."
    New-AzStorageSyncServerEndpoint -ResourceGroupName $ResourceGroupName -StorageSyncServiceName $StorageSyncServiceName -SyncGroupName $SyncGroupName -Name $serverEndpointName -ServerResourceId $registeredServer.ResourceId -StorageAccountResourceId $storageAccount.Id -AzureFileShareName $FileShareName -ServerLocalPath $ServerEndpointLocalPath -ErrorAction Stop
    
    Write-Host "--- SCRIPT COMPLETED SUCCESSFULLY ---"
    exit 0

} catch {
    $errorMessage = $_ | Out-String
    Write-Host "---!!! SCRIPT FAILED !!!---"
    Write-Error $errorMessage
    exit 1

} finally {
    Write-Host "--- Stopping Transcript ---"
    Stop-Transcript -ErrorAction SilentlyContinue
}
