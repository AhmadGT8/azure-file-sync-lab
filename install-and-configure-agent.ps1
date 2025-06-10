# Final version of install-and-configure-agent.ps1 (With Specific Cloud Endpoint Retry Logic)
param (
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$StorageSyncServiceName,
    [Parameter(Mandatory=$true)][string]$SyncGroupName,
    [Parameter(Mandatory=$true)][string]$StorageAccountName,
    [Parameter(Mandatory=$true)][string]$FileShareName,
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$TenantId,
    [Parameter(Mandatory=$true)][string]$VmLocation
)

$transcriptLogPath = Join-Path $env:TEMP "AzureFileSync-CSE-Transcript.txt"

try {
    Start-Transcript -Path $transcriptLogPath -Append
    
    $ErrorActionPreference = 'Stop'
    $global:ProgressPreference = 'SilentlyContinue'
    Write-Host "--- Starting Script Execution ---"
    
    #================================================================================
    # SECTION 1: PRE-PACKAGED MODULE SETUP
    #================================================================================
    $modulesZipPath = ".\AzureModules.zip"
    $modulesInstallPath = Join-Path $env:TEMP "Modules"
    Expand-Archive -Path $modulesZipPath -DestinationPath $modulesInstallPath -Force

    $actualModulePath = $modulesInstallPath
    $unzippedItems = Get-ChildItem -Path $modulesInstallPath
    if (($unzippedItems.Count -eq 1) -and ($unzippedItems[0].PSIsContainer)) {
        $actualModulePath = $unzippedItems[0].FullName
    }
    
    $env:PSModulePath = "$actualModulePath;" + $env:PSModulePath

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
    if (-not (Test-Path -Path $ServerEndpointLocalPath)) { New-Item -ItemType Directory -Force -Path $ServerEndpointLocalPath }

    # ... (Agent Download and Install logic is correct and remains the same) ...
    $osVer = [System.Environment]::OSVersion.Version
    $agentUri = switch -regex ($osVer.ToString()){
        '^10.0.17763' { "https://aka.ms/afs/agent/Server2019"; break }
        '^10.0.20348' { "https://aka.ms/afs/agent/Server2022"; break }
        default { throw "OS Version not supported for AFS Agent: $osVer" }
    }
    $msiTempPath = Join-Path $env:TEMP "StorageSyncAgent.msi"
    Invoke-WebRequest -Uri $agentUri -OutFile $msiTempPath -UseBasicParsing
    Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", "`"$msiTempPath`"", "/quiet", "/norestart" -Wait

    Write-Host "Registering server '$($env:COMPUTERNAME)'..."
    Register-AzStorageSyncServer -StorageSyncServiceName $StorageSyncServiceName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    
    $registeredServer = Get-AzStorageSyncServer -StorageSyncServiceName $StorageSyncServiceName -ResourceGroupName $ResourceGroupName | Where-Object { $_.FriendlyName -eq $env:COMPUTERNAME }
    if (-not $registeredServer) { throw "Failed to retrieve registered server details." }

    # --- FINAL FIX: Retry loop to wait for the Cloud Endpoint to be visible ---
    $maxRetries = 8
    $retryDelaySeconds = 20
    $cloudEndpoint = $null
    # The Cloud Endpoint name in the ARM template is 'cloudEndpoint'
    $cloudEndpointName = "cloudEndpoint"

    Write-Host "Verifying Cloud Endpoint '$cloudEndpointName' exists in Sync Group '$SyncGroupName'..."
    for ($i=1; $i -le $maxRetries; $i++) {
        $cloudEndpoint = Get-AzStorageSyncCloudEndpoint -ResourceGroupName $ResourceGroupName -StorageSyncServiceName $StorageSyncServiceName -SyncGroupName $SyncGroupName -Name $cloudEndpointName -ErrorAction SilentlyContinue
        if ($cloudEndpoint) {
            Write-Host "Successfully found Cloud Endpoint '$cloudEndpointName' on attempt $i."
            break
        }
        if ($i -lt $maxRetries) {
             Write-Warning "Cloud Endpoint '$cloudEndpointName' not found on attempt $i. This is likely a propagation delay. Waiting $retryDelaySeconds seconds..."
             Start-Sleep -Seconds $retryDelaySeconds
        } else {
            throw "Failed to find Cloud Endpoint '$cloudEndpointName' in Sync Group '$SyncGroupName' after $maxRetries attempts."
        }
    }
    
    $endpointNameSuffix = ($ServerEndpointLocalPath -replace '[:\s]', '_' -replace '__', '_').Trim('_')
    $serverEndpointName = "$($env:COMPUTERNAME)_$endpointNameSuffix"
    
    Write-Host "Creating server endpoint '$serverEndpointName'..."
    New-AzStorageSyncServerEndpoint -ResourceGroupName $ResourceGroupName `
        -StorageSyncServiceName $StorageSyncServiceName `
        -SyncGroupName $SyncGroupName `
        -Name $serverEndpointName `
        -ServerResourceId $registeredServer.ResourceId `
        -ServerLocalPath $ServerEndpointLocalPath `
        -ErrorAction Stop
    
    Write-Host "--- SCRIPT COMPLETED SUCCESSFULLY ---"
    exit 0

} catch {
    $errorMessage = $_ | Out-String
    Write-Error $errorMessage
    exit 1

} finally {
    Write-Host "--- Stopping Transcript ---"
    Stop-Transcript -ErrorAction SilentlyContinue
}
