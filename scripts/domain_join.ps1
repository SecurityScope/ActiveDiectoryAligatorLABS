$ErrorActionPreference = "Continue"

$domain     = $env:DOMAIN
$adminPass  = $env:ADMIN_PASS
$dc01IP     = $env:DC01_IP
$vmIP       = $env:VM_IP
$vmName     = $env:VM_NAME
$logPrefix  = $env:LOG_PREFIX

Write-Host "[$logPrefix] Starting $vmName join setup..."

Write-Host "[$logPrefix] Setting static IP $vmIP..."
$adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
$mgmtNic  = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1).InterfaceIndex
$nic2     = $adapters | Where-Object { $_.InterfaceIndex -ne $mgmtNic } | Select-Object -First 1

if ($nic2) {
    $ifIndex = $nic2.InterfaceIndex
    Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $vmIP -PrefixLength 24 -AddressFamily IPv4
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dc01IP
    Write-Host "[$logPrefix] Static IP set, DNS pointing to $dc01IP"
} else {
    Write-Host "[$logPrefix] WARNING: Could not find secondary adapter"
    $idx = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).InterfaceIndex
    New-NetIPAddress -InterfaceIndex $idx -IPAddress $vmIP -PrefixLength 24 -AddressFamily IPv4 -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dc01IP
}

Write-Host "[$logPrefix] Waiting for DC01 to be reachable..."
$reachable = $false
for ($i = 1; $i -le 20; $i++) {
    if (Test-Connection $dc01IP -Count 1 -Quiet) {
        $reachable = $true
        Write-Host "[$logPrefix] DC01 reachable"
        break
    }
    Write-Host "[$logPrefix] Attempt $i/20, waiting..."
    Start-Sleep 15
}
if (-not $reachable) {
    Write-Host "[$logPrefix] ERROR: DC01 not reachable after 20 attempts"
    exit 1
}

Write-Host "[$logPrefix] Syncing clock with DC01 ($dc01IP)..."
try {
    net time \\$dc01IP /set /y 2>&1 | Out-Null
    $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$logPrefix] Clock synced. Current time: $currentTime"
} catch {
    Write-Host "[$logPrefix] WARNING: Time sync failed: $_"
    Write-Host "[$logPrefix] AD requires clocks within 5 minutes of each other."
}

Write-Host "[$logPrefix] Setting DNS to DC01 on all adapters..."
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
foreach ($adapter in $adapters) {
    Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex `
        -ServerAddresses $dc01IP
}
Clear-DnsClientCache

Write-Host "[$logPrefix] Verifying DNS resolution of $domain..."
$dnsOk = $false
for ($i = 1; $i -le 12; $i++) {
    try {
        $resolved = Resolve-DnsName $domain -ErrorAction Stop
        Write-Host "[$logPrefix] $domain resolved OK"
        $dnsOk = $true
        break
    } catch {
        Write-Host "[$logPrefix] DNS attempt $i/12..."
        Start-Sleep 10
    }
}
if (-not $dnsOk) {
    Write-Host "[$logPrefix] ERROR: Cannot resolve $domain"
    exit 1
}

Write-Host "[$logPrefix] Joining domain $domain..."
$password = ConvertTo-SecureString $adminPass -AsPlainText -Force

$credFormats = @(
    "Administrator@$domain",
    "$env:DOMAIN_UPPER\Administrator",
    "Administrator"
)

$joined = $false
foreach ($credFormat in $credFormats) {
    Write-Host "[$logPrefix] Trying credential format: $credFormat"
    $cred = New-Object PSCredential($credFormat, $password)
    try {
        Add-Computer -DomainName $domain -Credential $cred -NewName $vmName -Force -ErrorAction Stop
        Write-Host "[$logPrefix] Joined domain with credential: $credFormat"
        $joined = $true
        break
    } catch {
        Write-Host "[$logPrefix] Failed with $credFormat`: $_"
    }
}

if (-not $joined) {
    Write-Host "[$logPrefix] ERROR: All credential formats failed"
    exit 1
}
Write-Host "[$logPrefix] Done. Vagrant reload provisioner will reboot to complete domain join."
