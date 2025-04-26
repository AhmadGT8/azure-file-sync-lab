param(
  [string] $syncServiceName,
  [string] $fileShareName,
  [string] $serverEndpointPath
)

# 1) Create your folder
New-Item -ItemType Directory -Force -Path $serverEndpointPath

# 2) Install the File Sync agent
$agentMsi = "$env:TEMP\StorageSyncAgent.msi"
Invoke-WebRequest `
  -Uri "https://download.microsoft.com/download/9/5/4/9547214F-3A27-4226-9C18-01C8A1711235/StorageSyncAgent.msi" `
  -OutFile $agentMsi

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
