param(
    [Parameter(Mandatory=$true)][string] $ResourceGroupName,
    [Parameter(Mandatory=$true)][string] $StorageSyncServiceName,
    [Parameter(Mandatory=$true)][string] $SyncGroupName,
    [Parameter(Mandatory=$true)][string] $ServerEndpointLocalPath,
    [Parameter(Mandatory=$true)][string] $ServerResourceId,
    [Parameter(Mandatory=$true)][string] $StorageAccountName,
    [Parameter(Mandatory=$true)][string] $FileShareName,
    [Parameter(Mandatory=$true)][string] $SubscriptionId,
    [Parameter(Mandatory=$true)][string] $TenantId
)

# 1) Install / Import Az.Accounts and Az.StorageSync modules if missing
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Install-Module -Name Az.Accounts -Force -Scope AllUsers
}
Import-Module Az.Accounts

if (-not (Get-Module -ListAvailable -Name Az.StorageSync)) {
    Install-Module -Name Az.StorageSync -Force -Scope AllUsers
}
Import-Module Az.StorageSync

# 2) Connect via the VM's managed identity
Connect-AzAccount -Identity `
                 -Subscription $SubscriptionId `
                 -Tenant $TenantId

# 3) (Optional / Redundant) Disable IE ESC if running Desktop Experience
$installType = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").InstallationType
if ($installType -ne "Server Core") {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0 -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0 -Force
    Stop-Process -Name iexplore -ErrorAction SilentlyContinue
}

# 4) Ensure the local path exists
if (-not (Test-Path -Path $ServerEndpointLocalPath)) {
    New-Item -ItemType Directory -Force -Path $ServerEndpointLocalPath
}

# 5) Download & install the Azure File Sync agent MSI for Windows Server 2019
$osver = [System.Environment]::OSVersion.Version
if ($osver.Equals([Version] "10.0.17763.0")) {
    $agentUri = "https://aka.ms/afs/agent/Server2019"
} elseif ($osver.Equals([Version] "10.0.20348.0")) {
    $agentUri = "https://aka.ms/afs/agent/Server2022"
} elseif ($osver.Equals([Version] "10.0.14393.0")) {
    $agentUri = "https://aka.ms/afs/agent/Server2016"
} elseif ($osver.Equals([Version] "6.3.9600.0")) {
    $agentUri = "https://aka.ms/afs/agent/Server2012R2"
} else {
    throw [System.PlatformNotSupportedException]::new("Azure File Sync agent is only supported on Windows Server 2012 R2, 2016, 2019, 2022.")
}

$msiTemp = Join-Path $env:TEMP "StorageSyncAgent.msi"
Invoke-WebRequest -Uri $agentUri -OutFile $msiTemp
Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", $msiTemp, "/quiet", "/norestart" -Wait
Remove-Item -Path $msiTemp -Force

# 6) Register this server in the Storage Sync Service
Write-Output "Registering the server in Storage Sync Service..."
$rgName = $ResourceGroupName
$synSvcName = $StorageSyncServiceName

# Use the VM's managed identity (already connected), so no explicit credential needed
Register-AzStorageSyncServer `
    -ResourceGroupName $rgName `
    -StorageSyncServiceName $synSvcName

# 7) Create the server endpoint under that Sync Service / Sync Group
Write-Output "Creating the server endpoint under sync group '$SyncGroupName'..."
New-AzStorageSyncServerEndpoint `
    -ResourceGroupName $rgName `
    -StorageSyncServiceName $synSvcName `
    -SyncGroupName $SyncGroupName `
    -Name "serverEndpoint" `
    -ServerResourceId $ServerResourceId `
    -AzureFileShareName $FileShareName `
    -StorageAccountResourceId (Get-AzStorageAccount -ResourceGroupName $rgName -Name $StorageAccountName).Id `
    -ServerLocalPath $ServerEndpointLocalPath

Write-Output "Server endpoint created and healthy."
