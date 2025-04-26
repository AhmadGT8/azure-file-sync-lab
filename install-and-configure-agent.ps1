param(
  [string] $syncServiceName,
  [string] $fileShareName,
  [string] $serverEndpointPath
)

# 1) Create your folder
New-Item -ItemType Directory -Force -Path $serverEndpointPath

# 2) Install the File Sync agent
# Download & silently install the Azure File Sync Agent
$agentMsiUrl = 'https://github.com/AhmadGT8/azure-file-sync-lab/releases/download/v1.0/StorageSyncAgent.msi'
$msiPath     = "$env:Temp\StorageSyncAgent.msi"
Invoke-WebRequest -Uri $agentMsiUrl -OutFile $msiPath
Start-Process -FilePath 'msiexec.exe' -ArgumentList '/i', $msiPath, '/qn', '/norestart' -Wait


Start-Process msiexec.exe `
  -ArgumentList "/i `"$agentMsi`" /quiet /norestart" -Wait

# wait for the service to appear
Start-Sleep -Seconds 30

# 3) Register the server endpoint
$regTool = "C:\Program Files\Azure\StorageSyncAgent\RegisterStorageSyncAgent.exe"
& $regTool `
  /ResourceGroupName (Get-AzContext).Subscription.Name `
  /StorageSyncServiceName $syncServiceName `
  /SyncGroupName "syncGroup" `
  /AzureFileShareName $fileShareName `
  /ServerLocalPath $serverEndpointPath

Write-Host "Server endpoint registration complete."
