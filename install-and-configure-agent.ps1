param(
  [string] $location,
  [string] $storageSyncSvc,
  [string] $syncGroupName,
  [string] $storageAccountName,
  [string] $azureFileShareName
)

# 1) Prepare the server
$installType = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").InstallationType
if ($installType -ne "Server Core") {
  # Disable IE ESC for Admins
  Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0 -Force
  # Disable IE ESC for Users
  Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0 -Force
  Stop-Process -Name iexplore -ErrorAction SilentlyContinue
}

# 2) Download & install the Azure File Sync agent for Server 2019
$msiUrl = "https://aka.ms/afs/agent/Server2019"
$msiPath = Join-Path $env:TEMP "StorageSyncAgent.msi"
Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath
Start-Process -FilePath $msiPath -ArgumentList "/quiet","/norestart" -Wait

# 3) Create local sync folder
$serverEndpointPath = "C:\SyncFolder"
if (-not (Test-Path $serverEndpointPath)) {
  New-Item -Path $serverEndpointPath -ItemType Directory -Force | Out-Null
}

# 4) Register this server with your Storage Sync Service & Sync Group
#    (RegisterStorageSyncServer is installed with the MSI)
& "C:\Program Files\Azure\StorageSyncAgent\RegisterStorageSyncAgent.exe" `
  -ResourceGroupName $location `
  -StorageSyncServiceName $storageSyncSvc `
  -SyncGroupName $syncGroupName

# 5) Install the server endpoint into that Sync Group
New-AzStorageSyncServerEndpoint `
  -ResourceGroupName $location `
  -StorageSyncServiceName $storageSyncSvc `
  -SyncGroupName $syncGroupName `
  -Name "serverEndpoint" `
  -StorageAccountResourceId (Get-AzStorageAccount -ResourceGroupName $location -Name $storageAccountName).Id `
  -AzureFileShareName $azureFileShareName `
  -ServerLocalPath $serverEndpointPath
