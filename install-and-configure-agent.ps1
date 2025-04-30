param(
  [string] $storageSyncSvc,
  [string] $storageAccountName,
  [string] $azureFileShareName,
  [string] $serverLocalPath,
  [string] $location,
  [string] $syncGroupName
)

# 1) Prepare Windows Server for Azure File Sync
$installType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\' -Name 'InstallationType').InstallationType
if ($installType -ne 'Server Core') {
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' -Name 'IsInstalled' -Value 0 -Force
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}' -Name 'IsInstalled' -Value 0 -Force
  Stop-Process -Name iexplore -ErrorAction SilentlyContinue
}

# 2) Create the folder to sync
if (-Not (Test-Path -Path $serverLocalPath)) {
  New-Item -ItemType Directory -Force -Path $serverLocalPath
}

# 3) Download & silently install Azure File Sync Agent for Server 2019
Invoke-WebRequest -Uri https://aka.ms/afs/agent/Server2019 -OutFile 'StorageSyncAgent.msi'
Start-Process -FilePath 'msiexec.exe' -ArgumentList '/i StorageSyncAgent.msi','/quiet' -Wait

# 4) Register this machine as a Server Endpoint
$rgName = $env:RESOURCE_GROUP
Connect-AzAccount -Identity
$storageAccountResourceId = (Get-AzStorageAccount -ResourceGroupName $rgName -Name $storageAccountName).Id
New-AzStorageSyncServerEndpoint `
  -ResourceGroupName $rgName `
  -StorageSyncServiceName $storageSyncSvc `
  -SyncGroupName $syncGroupName `
  -Name 'serverEndpoint' `
  -StorageAccountResourceId $storageAccountResourceId `
  -AzureFileShareName $azureFileShareName `
  -ServerLocalPath $serverLocalPath

Write-Host 'Server Endpoint registered.'
