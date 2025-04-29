param(
  [string] $syncServiceName,
  [string] $syncGroupName,
  [string] $serverEndpointPath,
  [string] $location,
  [string] $fileShareName
)

# 1) Prepare server (disable IE ESC, etc)
$installType = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").InstallationType
if ($installType -ne "Server Core") {
  Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0 -Force
  Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0 -Force
  Stop-Process -Name iexplore -ErrorAction SilentlyContinue
}

# 2) Download & install the MSI for Server 2019
Invoke-WebRequest -Uri https://aka.ms/afs/agent/Server2019 -OutFile "StorageSyncAgent.msi"
Start-Process -FilePath "StorageSyncAgent.msi" -ArgumentList "/quiet" -Wait
Remove-Item -Path ".\StorageSyncAgent.msi" -Force

# 3) Create the local folder
New-Item -ItemType Directory -Force -Path $serverEndpointPath

# 4) Register the agent & create server endpoint
& "$Env:ProgramFiles\Azure\StorageSyncAgent\RegisterStorageSyncAgent.exe" /ServerEndpoint:$syncGroupName:$serverEndpointPath

# 5) (After cloud endpoint exists) register server endpoint
New-Item -ItemType Directory -Force -Path "$serverEndpointPath\_tmp" | Out-Null
$regKey = (az storage sync sync-group server endpoint generate-key `
  --resource-group $env:RESOURCEGROUP `
  --storage-sync-service-name $syncServiceName `
  --sync-group-name $syncGroupName `
  --name "cloudEndpoint").primaryKey
Register-AzStorageSyncServerEndpoint `
  -ResourceGroupName $env:RESOURCEGROUP `
  -StorageSyncServiceName $syncServiceName `
  -SyncGroupName $syncGroupName `
  -ServerEndpointName $syncGroupName `
  -ServerLocalPath $serverEndpointPath `
  -StorageAccountResourceId (Get-AzStorageAccount -ResourceGroupName $env:RESOURCEGROUP -Name $env:STORAGEACCOUNTNAME).Id `
  -AzureFileShareName $fileShareName `
  -AuthenticationKey $regKey
