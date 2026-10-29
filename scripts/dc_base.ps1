$ErrorActionPreference = "Continue"

$dcIP      = $env:DC_IP
$dc01IP    = $env:DC01_IP
$dcName    = $env:DC_NAME
$logPrefix = if ($env:LOG_PREFIX) { $env:LOG_PREFIX } else { $dcName.ToLower() + "_base" }
$dnsServer = if ($env:DNS_SERVER) { $env:DNS_SERVER } else { $dc01IP }
$dnsSuffix = if ($env:DNSSUFFIX) { $env:DNSSUFFIX } else { "secscope.corp" }

Write-Host "[$logPrefix] Starting $dcName base setup..."

if ($env:COMPUTERNAME -eq $dcName) {
    Write-Host "[$logPrefix] Computer already named $dcName (no rename needed)"
} else {
    Write-Host "[$logPrefix] Renaming computer to $dcName..."
    Rename-Computer -NewName $dcName -Force
}

Write-Host "[$logPrefix] Setting static IP $dcIP on secondary adapter..."
$adapters = Get-NetAdapter | Where-Object Status -eq 'Up'

# Identify the NAT/management adapter by its VirtualBox NAT address (10.0.2.x),
# NOT by "whichever default route is first". After an earlier run the internal
# adapter can own a default route (192.168.200.1), which made the old logic pick
# the NAT adapter as "secondary" and reconfigure it - instantly cutting WinRM.
$mgmtNic = $null
foreach ($a in $adapters) {
    $aip = (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    if ($aip -like '10.0.2.*') { $mgmtNic = $a.InterfaceIndex; break }
}
if (-not $mgmtNic) {
    # Fallback for a NAT adapter that is still DHCP/APIPA at this point.
    $mgmtNic = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1).InterfaceIndex
}
$nic2 = $adapters | Where-Object { $_.InterfaceIndex -ne $mgmtNic } | Select-Object -First 1

if ($nic2) {
    $ifIndex = $nic2.InterfaceIndex
    $nic2Name = $nic2.Name
    Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    # NO default gateway on the internal (natnetwork) adapter. Giving it one -
    # combined with the lower interface metric below - installs a default route
    # that outranks the NAT adapter's route. That hijacks the return path of the
    # WinRM session (which rides nic1/NAT) and disconnects Vagrant mid-provision.
    # All lab traffic is on 192.168.200.0/24, so the internal adapter needs only
    # its on-link /24 route.
    netsh interface ip set address name="$nic2Name" static $dcIP 255.255.255.0
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dnsServer
    Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Disabled
    # Internal (natnetwork) adapter must register its connection address so
    # Netlogon can publish DC-locator SRV records after promotion. Disabling
    # this causes "No DNS servers configured for local system" and SRV
    # registration silently fails.
    Set-DnsClient -InterfaceIndex $ifIndex -ConnectionSpecificSuffix $dnsSuffix -RegisterThisConnectionsAddress $true
    # Prefer natnetwork adapter for DNS (lower metric = higher priority)
    Set-NetIPInterface -InterfaceIndex $ifIndex -InterfaceMetric 10
    $otherNics = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceIndex -ne $ifIndex }
    foreach ($o in $otherNics) {
        Set-NetIPInterface -InterfaceIndex $o.InterfaceIndex -InterfaceMetric 200
        Set-DnsClient -InterfaceIndex $o.InterfaceIndex -RegisterThisConnectionsAddress $false
        # The NAT adapter is DHCP-enabled; a DHCP renewal during the promotion
        # window (Install-ADDSForest, before dc01_dns.ps1 runs) can transiently
        # re-assert DNS registration via DHCP option 81 and let Netlogon publish
        # a stale "<dc> -> 10.0.2.x" A record into the fresh zone. Pin the
        # per-interface registry flag so registration stays off across DHCP
        # renewals, not just at the DNS-client layer.
        $guid = (Get-NetAdapter -InterfaceIndex $o.InterfaceIndex).InterfaceGuid
        $ifKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
        if (Test-Path $ifKey) {
            Set-ItemProperty -Path $ifKey -Name RegistrationEnabled -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $ifKey -Name DisableDynamicUpdate -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "[$logPrefix] Static IP set, DNS pointing to $dnsServer"
    # Best-effort, single attempt - and never on a NoTraffic profile. The static
    # IP was just applied but NLA may not have observed traffic yet; calling
    # Set-NetConnectionProfile on a NoTraffic profile can block inside NLA/WMI.
    # The NLA-Recheck startup task reclassifies the adapter after base-reload.
    try {
        $prof = Get-NetConnectionProfile -InterfaceAlias $nic2Name -ErrorAction Stop
        if ($prof.IPv4Connectivity -ne 'NoTraffic') {
            Set-NetConnectionProfile -InterfaceAlias $nic2Name -NetworkCategory Private -ErrorAction Stop
            Write-Host "[$logPrefix] Network profile set to Private"
        } else {
            Write-Host "[$logPrefix] Network profile deferred (NoTraffic) to NLA-Recheck"
        }
    } catch {
        Write-Host "[$logPrefix] Network profile deferred to NLA-Recheck startup task: $_"
    }
} else {
    Write-Host "[$logPrefix] WARNING: Could not find secondary adapter"
    $idx = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).InterfaceIndex
    $nicName = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).Name
    netsh interface ip set address name="$nicName" static $dcIP 255.255.255.0
    Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dnsServer
    Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled
    Set-DnsClient -InterfaceIndex $idx -ConnectionSpecificSuffix $dnsSuffix -RegisterThisConnectionsAddress $false
}

# Ensure the Print Spooler is running + Automatic so the DC can be coerced over
# MS-RPRN (PrinterBug). This is the trigger for the unconstrained-delegation
# capture (coerce DC01 -> WS02's unconstrained host -> capture the DC01$ TGT ->
# DCSync) and for ADCS ESC8 relay. Server has it on by default; set it explicitly
# so the exercise never depends on that default.
Write-Host "[$logPrefix] Ensuring Print Spooler is enabled (PrinterBug coercion target)..."
try {
    Set-Service -Name Spooler -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name Spooler -ErrorAction SilentlyContinue
    Write-Host "[$logPrefix] Print Spooler running + Automatic"
} catch {
    Write-Host "[$logPrefix] Could not ensure Spooler: $_"
}

Write-Host "[$logPrefix] Done. Vagrant reload provisioner will reboot to apply changes."
