param(
    [string]$syncServiceName,
    [string]$storageAccountName,
    [string]$fileShareName,
    [string]$serverEndpointPath,
    [string]$location,
    [string]$syncGroupName
)

# Install required PowerShell modules
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Install-Module -Name Az.Accounts -Force
}
if (-not (Get-Module -ListAvailable -Name Az.StorageSync)) {
    Install-Module -Name Az.StorageSync -Force
}

Import-Module Az.Accounts
Import-Module Az.StorageSync

# Prepare the server (disable IE ESC if not Server Core)
$installType = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\").InstallationType
if ($installType -ne "Server Core") {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0 -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0 -Force
    Stop-Process -Name iexplore -ErrorAction SilentlyContinue
}

# Create the endpoint path if not exists
if (-not (Test-Path -Path $serverEndpointPath)) {
    New-Item -ItemType Directory -Path $serverEndpointPath -Force | Out-Null
}

# Determine OS version and download appropriate MSI
$osver = [System.Environment]::OSVersion.Version
if ($osver.Equals([System.Version]::new(10, 0, 20348, 0))) {
    $msiUrl = "https://aka.ms/afs/agent/Server2022"
} elseif ($osver.Equals([System.Version]::new(10, 0, 17763, 0))) {
    $msiUrl = "https://aka.ms/afs/agent/Server2019"
} elseif ($osver.Equals([System.Version]::new(10, 0, 14393, 0))) {
    $msiUrl = "https://aka.ms/afs/agent/Server2016"
} elseif ($osver.Equals([System.Version]::new(6, 3, 9600, 0))) {
    $msiUrl = "https://aka.ms/afs/agent/Server2012R2"
} else {
    throw "Unsupported OS version for Azure File Sync agent"
}

$msiPath = "$env:TEMP\StorageSyncAgent.msi"
Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath
Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait
Remove-Item -Path $msiPath -Force

# Login and register the server
Connect-AzAccount -Identity
Register-AzStorageSyncServer -ResourceGroupName $(Get-AzResourceGroup | Where-Object { $_.Location -eq $location } | Select-Object -First 1 -ExpandProperty ResourceGroupName) `
                             -StorageSyncServiceName $syncServiceName

# Create the server endpoint
New-AzStorageSyncServerEndpoint -ResourceGroupName $(Get-AzResourceGroup | Where-Object { $_.Location -eq $location } | Select-Object -First 1 -ExpandProperty ResourceGroupName) `
                                -StorageSyncServiceName $syncServiceName `
                                -SyncGroupName $syncGroupName `
                                -ServerEndpointName "serverEndpoint" `
                                -ServerLocalPath $serverEndpointPath
