# Final version of install-and-configure-agent.ps1 (Pre-Packaged Method with ZIP structure fix)
param (
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$StorageSyncServiceName,
    [Parameter(Mandatory=$true)][string]$SyncGroupName,
    [Parameter(Mandatory=$true)][string]$StorageAccountName,
    [Parameter(Mandatory=$true)][string]$FileShareName,
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$TenantId
)

$transcriptLogPath = Join-Path $env:TEMP "AzureFileSync-CSE-Transcript.txt"

try {
    Start-Transcript -Path $transcriptLogPath -Append
    
    $ErrorActionPreference = 'Stop'
    $global:ProgressPreference = 'SilentlyContinue'
    Write-Host "--- Starting Script Execution with Pre-Packaged Modules ---"
    
    #================================================================================
    # SECTION 1: PRE-PACKAGED MODULE SETUP
    #================================================================================
    $modulesZipPath = ".\AzureModules.zip"
    $modulesInstallPath = Join-Path $env:TEMP "Modules"

    Write-Host "Expanding pre-packaged modules from '$modulesZipPath' to '$modulesInstallPath'..."
    Expand-Archive -Path $modulesZipPath -DestinationPath $modulesInstallPath -Force

    # --- Logic to handle a common zipping mistake (nested parent folder) ---
    $actualModulePath = $modulesInstallPath
    $potentialNestedPath = Join-Path $modulesInstallPath "AzureModules"
    if (Test-Path $potentialNestedPath) {
        Write-Warning "Detected a nested 'AzureModules' folder. Adjusting module path to point to the nested folder."
        $actualModulePath = $potentialNestedPath
    }
    # Log the contents of the final module path for debugging
    Write-Host "Listing contents of final module path '$actualModulePath':"
    Get-ChildItem -Path $actualModulePath | Select-Object Name | Out-String | Write-Host
    # --- End nested folder logic ---

    Write-Host "Adding '$actualModulePath' to the PowerShell module path for this session..."
    $env:PSModulePath = "$actualModulePath;" + $env:PSModulePath

    Write-Host "Importing Az modules from pre-packaged location..."
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.StorageSync -ErrorAction Stop
    Write-Host "Az modules imported successfully."
    
    #================================================================================
    # SECTION 2: IE ENHANCED SECURITY CONFIGURATION (ESC)
    #================================================================================
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
