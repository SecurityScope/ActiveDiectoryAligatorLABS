$ErrorActionPreference = "Continue"

$dcIP      = $env:DC_IP
$dc01IP    = $env:DC01_IP
$dcName    = $env:DC_NAME
$logPrefix = if ($env:LOG_PREFIX) { $env:LOG_PREFIX } else { $dcName.ToLower() + "_base" }
$dnsServer = if ($env:DNS_SERVER) { $env:DNS_SERVER } else { $dc01IP }

Write-Host "[$logPrefix] Starting $dcName base setup..."

Write-Host "[$logPrefix] Renaming computer to $dcName..."
Rename-Computer -NewName $dcName -Force

Write-Host "[$logPrefix] Setting static IP $dcIP on secondary adapter..."
$adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
$mgmtNic  = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1).InterfaceIndex
$nic2     = $adapters | Where-Object { $_.InterfaceIndex -ne $mgmtNic } | Select-Object -First 1

if ($nic2) {
    $ifIndex = $nic2.InterfaceIndex
    Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $dcIP -PrefixLength 24 -AddressFamily IPv4
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dnsServer
    Write-Host "[$logPrefix] Static IP set, DNS pointing to $dnsServer"
} else {
    Write-Host "[$logPrefix] WARNING: Could not find secondary adapter"
    $idx = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).InterfaceIndex
    New-NetIPAddress -InterfaceIndex $idx -IPAddress $dcIP -PrefixLength 24 -AddressFamily IPv4 -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dnsServer
}

Write-Host "[$logPrefix] Done. Vagrant reload provisioner will reboot to apply changes."
