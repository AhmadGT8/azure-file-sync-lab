param (
    [string]$SyncServiceName,
    [string]$SyncGroupName,
    [string]$ServerEndpointPath
)

$ErrorActionPreference = "Stop"

# Create the local sync folder
New-Item -ItemType Directory -Force -Path $ServerEndpointPath

# Add dummy content
Set-Content -Path (Join-Path $ServerEndpointPath "readme.txt") -Value "Test data for Azure File Sync"

# Download and install the Azure File Sync Agent
Invoke-WebRequest -Uri https://aka.ms/afsagent -OutFile "$env:TEMP\\StorageSyncAgent.msi"
Start-Process msiexec.exe -Wait -ArgumentList \"/i $env:TEMP\\StorageSyncAgent.msi /quiet\"

# Register the server with the Storage Sync Service
$resourceGroup = (Invoke-RestMethod -Headers @{Metadata="true"} -Method GET -Uri http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01).resourceGroupName
$subscriptionId = (Invoke-RestMethod -Headers @{Metadata="true"} -Method GET -Uri http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01).subscriptionId

$registrationKey = az storagesync sync-group server endpoint generate-auth-token `
    --resource-group $resourceGroup `
    --storage-sync-service $SyncServiceName `
    --sync-group-name $SyncGroupName `
    --name $env:COMPUTERNAME `
    --subscription $subscriptionId `
    --query 'authToken' -o tsv

$regTool = \"C:\\Program Files\\Azure\\StorageSyncAgent\\RegisterStorageSyncAgent.exe\"
Start-Process -Wait -FilePath $regTool -ArgumentList \"/key:$registrationKey\"

# Create the server endpoint
az storagesync sync-group server endpoint create `
    --resource-group $resourceGroup `
    --storage-sync-service $SyncServiceName `
    --sync-group-name $SyncGroupName `
    --server-resource-id $(az resource show --resource-group $resourceGroup --name $env:COMPUTERNAME --resource-type Microsoft.Compute/virtualMachines --query id -o tsv) `
    --server-local-path $ServerEndpointPath
