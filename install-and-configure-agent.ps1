param(
  [string] $rgName,
  [string] $syncServiceName,
  [string] $syncGroupName,
  [string] $storageAccountName,
  [string] $fileShareName
)

# 1. Prepare server
$installType = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").InstallationType
if ($installType -ne "Server Core") {
  Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0 -Force
  Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0 -Force
  Stop-Process -Name iexplore -ErrorAction SilentlyContinue
}

# 2. Download & install the agent
$agentUrl = "https://aka.ms/afs/agent/Server2019"
$msi = "$env:TEMP\StorageSyncAgent.msi"
Invoke-WebRequest -Uri $agentUrl -OutFile $msi
Start-Process msiexec.exe -ArgumentList '/i', $msi, '/quiet', '/norestart' -Wait

# 3. Import and login
Install-Module Az.Accounts -Force -Scope AllUsers
Install-Module Az.StorageSync -Force -Scope AllUsers
Import-Module Az.Accounts
Import-Module Az.StorageSync
Connect-AzAccount -Identity

# 4. Register this server
$server = Register-AzStorageSyncServer `
  -ResourceGroupName $rgName `
  -StorageSyncServiceName $syncServiceName `
  -Name $env:COMPUTERNAME -Force

# 5. Create local folder
$localPath = "C:\SyncFolder"
New-Item -ItemType Directory -Path $localPath -Force

# 6. Create the server endpoint
New-AzStorageSyncServerEndpoint `
  -ResourceGroupName $rgName `
  -StorageSyncServiceName $syncServiceName `
  -SyncGroupName $syncGroupName `
  -StorageSyncServerResourceId $server.Id `
  -Name "serverEndpoint" `
  -ServerLocalPath $localPath `
  -AzureFileShareName $fileShareName
