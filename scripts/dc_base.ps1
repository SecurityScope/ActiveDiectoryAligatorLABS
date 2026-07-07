$ErrorActionPreference = "Continue"

$dcIP      = $env:DC_IP
$dc01IP    = $env:DC01_IP
$dcName    = $env:DC_NAME
$logPrefix = if ($env:LOG_PREFIX) { $env:LOG_PREFIX } else { $dcName.ToLower() + "_base" }
$dnsServer = if ($env:DNS_SERVER) { $env:DNS_SERVER } else { $dc01IP }
$dnsSuffix = if ($env:DNSSUFFIX) { $env:DNSSUFFIX } else { "secscope.corp" }

Write-Host "[$logPrefix] Starting $dcName base setup..."

Write-Host "[$logPrefix] Renaming computer to $dcName..."
Rename-Computer -NewName $dcName -Force

Write-Host "[$logPrefix] Setting static IP $dcIP on secondary adapter..."
$adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
$mgmtNic  = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1).InterfaceIndex
$nic2     = $adapters | Where-Object { $_.InterfaceIndex -ne $mgmtNic } | Select-Object -First 1

if ($nic2) {
    $ifIndex = $nic2.InterfaceIndex
    $nic2Name = $nic2.Name
    Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $dcIP -PrefixLength 24 -DefaultGateway 192.168.200.1 -AddressFamily IPv4 -PolicyStore PersistentStore
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dnsServer
    Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Disabled
    Set-DnsClient -InterfaceIndex $ifIndex -ConnectionSpecificSuffix $dnsSuffix -RegisterThisConnectionsAddress $false
    Write-Host "[$logPrefix] Static IP set, DNS pointing to $dnsServer"
    Write-Host "[$logPrefix] Waiting for network profile..."
    for ($j = 1; $j -le 8; $j++) {
        try {
            Set-NetConnectionProfile -InterfaceAlias $nic2Name -NetworkCategory Private -ErrorAction Stop
            Write-Host "[$logPrefix] Network profile set to Private"
            break
        } catch {
            Write-Host "[$logPrefix] Profile not ready, retrying ($j/8)..."
            Start-Sleep 3
        }
    }
} else {
    Write-Host "[$logPrefix] WARNING: Could not find secondary adapter"
    $idx = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).InterfaceIndex
    New-NetIPAddress -InterfaceIndex $idx -IPAddress $dcIP -PrefixLength 24 -DefaultGateway 192.168.200.1 -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dnsServer
    Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled
    Set-DnsClient -InterfaceIndex $idx -ConnectionSpecificSuffix $dnsSuffix -RegisterThisConnectionsAddress $false
}

Write-Host "[$logPrefix] Done. Vagrant reload provisioner will reboot to apply changes."
