# nla_recheck.ps1
# Boot-time NLA/DNS repair for the lab's internal 192.168.200.0/24 adapter.
# Registered as the NLA-Recheck scheduled task (SYSTEM, at startup, 30s delay)
# by common_windows.ps1 (which copies this file to the guest), and runnable
# manually (e.g. over Guest Additions) after sealing.
$ErrorActionPreference = "Continue"

$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$domain = $null
if ($cs -and $cs.PartOfDomain -and $cs.Domain -like "*.*") { $domain = $cs.Domain }

$internal = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" } | Where-Object {
    (Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -like "192.168.200.*"
} | Select-Object -First 1

if (-not $internal) {
    Write-Output "[nla] no internal 192.168.200.x adapter found"
    exit 0
}

$idx = $internal.InterfaceIndex
$ip = (Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress

# The default gateway is added ONLY when this is the sole lab adapter (sealed).
# While the NAT nic1 exists, an internal default route would outrank the NAT
# route and cut the WinRM session mid-provision.
$nat = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -like "10.0.2.*" }
if (-not $nat -and $ip) {
    $gw = "192.168.200.1"
    $route = Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
    if (-not $route -or $route.NextHop -ne $gw) {
        $route | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        New-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -NextHop $gw -RouteMetric 50 -ErrorAction SilentlyContinue | Out-Null
        if (-not (Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue)) {
            netsh interface ip set address name="$($internal.Name)" static $ip 255.255.255.0 $gw | Out-Null
        }
    }
    Write-Output "[nla] default gateway $gw on $($internal.Name)"
}

if ($domain) {
    # An empty ConnectionSpecificSuffix leaves the adapter "Unidentified";
    # NLA needs the suffix to associate the network with the AD domain.
    Set-DnsClient -InterfaceIndex $idx -ConnectionSpecificSuffix $domain -RegisterThisConnectionsAddress $true -ErrorAction SilentlyContinue
    $suffixes = @($domain)
    if ($domain -ne "secscope.corp") { $suffixes += "secscope.corp" }
    Set-DnsClientGlobalSetting -SuffixSearchList $suffixes -ErrorAction SilentlyContinue
    $isDnsServer = [bool](Get-Service DNS -ErrorAction SilentlyContinue)
    if ($isDnsServer) {
        Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @("127.0.0.1", "192.168.200.10") -ErrorAction SilentlyContinue
    } else {
        Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @("192.168.200.10") -ErrorAction SilentlyContinue
    }
    nltest /dsgetdc:$domain 2>&1 | Out-Null
    $dnsAddrs = (Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses -join ","
    Write-Output "[nla] DNS suffix=$domain, servers=$dnsAddrs"
}

# Give NLA a few seconds to notice the new suffix/default-route before forcing a
# link reset. Do NOT Restart-Service NlaSvc here: it can block for minutes on the
# netprofm dependency (observed as a stuck NLA-Recheck boot task).
$cat = (Get-NetConnectionProfile -InterfaceAlias $internal.Name -ErrorAction SilentlyContinue).NetworkCategory
for ($i = 1; $i -le 6 -and $cat -ne "DomainAuthenticated"; $i++) {
    Start-Sleep 5
    $cat = (Get-NetConnectionProfile -InterfaceAlias $internal.Name -ErrorAction SilentlyContinue).NetworkCategory
}
Write-Output "[nla] initial profile: $cat"

# NLA re-classifies most reliably after one link down/up. Do it at most once,
# and only when the suffix/gateway fix alone did not produce a domain profile.
if ($domain -and $cat -ne "DomainAuthenticated") {
    try {
        Disable-NetAdapter -Name $internal.Name -Confirm:$false -ErrorAction Stop
        Start-Sleep 4
        Enable-NetAdapter -Name $internal.Name -Confirm:$false -ErrorAction Stop
        Write-Output "[nla] adapter $($internal.Name) re-detected"
    } catch {
        Write-Output "[nla] adapter bounce skipped: $_"
    }
    for ($i = 1; $i -le 8; $i++) {
        Start-Sleep 5
        $cat = (Get-NetConnectionProfile -InterfaceAlias $internal.Name -ErrorAction SilentlyContinue).NetworkCategory
        Write-Output "[nla] attempt $i : $cat"
        if ($cat -eq "DomainAuthenticated") { break }
    }
}

# Never downgrade DomainAuthenticated. A Public profile breaks discovery and
# blocks inbound WinRM, so lower it to Private as a last resort.
$prof = Get-NetConnectionProfile -InterfaceAlias $internal.Name -ErrorAction SilentlyContinue
if ($prof -and $prof.NetworkCategory -eq "Public") {
    Set-NetConnectionProfile -InterfaceAlias $internal.Name -NetworkCategory Private -ErrorAction SilentlyContinue
    $prof = Get-NetConnectionProfile -InterfaceAlias $internal.Name -ErrorAction SilentlyContinue
}
if ($prof) { Write-Output "[nla] final: $($prof.NetworkCategory) / $($prof.IPv4Connectivity)" }
