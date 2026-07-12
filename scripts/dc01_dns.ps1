$ErrorActionPreference = "Continue"

Write-Host "[dc01_dns] Starting DNS and services setup..."

function Wait-ServiceRunning {
    param([string]$Name, [int]$TimeoutSec = 30)
    for ($s = 0; $s -lt $TimeoutSec; $s += 2) {
        $svc = Get-Service $Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { return $true }
        Start-Sleep 2
    }
    return $false
}

$domain      = $env:DOMAIN
$childDomain = $env:CHILD_DOMAIN
$adminPass   = $env:ADMIN_PASS
$dc01IP      = $env:DC01_IP
$dc02IP      = $env:DC02_IP
$dc03IP      = $env:DC03_IP
$srv01IP     = $env:SRV01_IP
$ws01IP      = $env:WS01_IP
$ws02IP      = $env:WS02_IP
$lin01IP     = $env:LIN01_IP
$kaliIP      = $env:KALI_IP

Write-Host "[dc01_dns] Waiting for AD services..."
$ready = $false
for ($i = 1; $i -le 12; $i++) {
    try {
        $null = Get-ADDomain -ErrorAction Stop
        $ready = $true
        Write-Host "[dc01_dns] AD services ready (attempt $i)"
        break
    } catch {
        Write-Host "[dc01_dns] Attempt $i/12, waiting..."
        Start-Sleep 10
    }
}
if (-not $ready) {
    Write-Host "[dc01_dns] ERROR: AD Domain Services not found after 120s."
    exit 1
}

Write-Host "[dc01_dns] Fixing DNS client before SRV registration..."
$adapters = Get-NetAdapter | Where-Object Status -eq "Up"
foreach ($a in $adapters) {
    Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses "127.0.0.1"
    # The internal (natnetwork, 192.168.x) adapter MUST have connection
    # registration enabled, otherwise Netlogon reports "No DNS servers
    # configured for local system" and silently fails to register the
    # DC-locator SRV records. Only disable registration on the NAT adapter
    # (10.0.2.x) so its WAN IP never pollutes the AD DNS zones.
    $ip = (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    if ($ip -like "192.168.*") {
        Set-DnsClient -InterfaceIndex $a.InterfaceIndex -RegisterThisConnectionsAddress $true
        Write-Host "[dc01_dns] Registration ENABLED on internal adapter ($ip)"
    } else {
        Set-DnsClient -InterfaceIndex $a.InterfaceIndex -RegisterThisConnectionsAddress $false
        Write-Host "[dc01_dns] Registration disabled on non-internal adapter ($ip)"
    }
}
Clear-DnsClientCache
Write-Host "[dc01_dns] DNS client -> 127.0.0.1 on all adapters (internal adapter registers)"

Write-Host "[dc01_dns] Waiting for AD to signal DNS sync completion..."
# On a forest-root DC with no replication partners the DsAvailable signal is
# often never raised (AD is already confirmed ready above), so cap this at a
# short poll then force-set rather than burning the old 240s every build.
$dsReady = $false
for ($i = 1; $i -le 6; $i++) {
    $dsAvail = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\DNS Server" -Name "DsAvailable" -ErrorAction SilentlyContinue).DsAvailable
    if ($dsAvail -eq 1) {
        Write-Host "[dc01_dns] AD signaled sync complete after $((i-1)*5)s"
        $dsReady = $true
        break
    }
    Write-Host "[dc01_dns] DsAvailable=$dsAvail, waiting (attempt $i/6)..."
    Start-Sleep 5
}
if (-not $dsReady) {
    Write-Host "[dc01_dns] DsAvailable not signaled after 30s, forcing (expected on forest root)..."
    Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\DNS Server" -Name "DsAvailable" -Value 1 -Type DWord -Force
}

Write-Host "[dc01_dns] Ensuring DNS server uses AD storage..."
dnscmd localhost /Config /DsAvailable 1 2>&1 | Out-Null
$zoneFile = "$env:SystemRoot\System32\DNS\$domain.dns"
$msdcsFile = "$env:SystemRoot\System32\DNS\_msdcs.$domain.dns"
Remove-Item $zoneFile -Force -ErrorAction SilentlyContinue
Remove-Item $msdcsFile -Force -ErrorAction SilentlyContinue
Write-Host "[dc01_dns] Deleted stale zone files"

Write-Host "[dc01_dns] Restarting DNS Server..."
Restart-Service DNS -Force -ErrorAction SilentlyContinue
if (Wait-ServiceRunning -Name DNS -TimeoutSec 30) { Write-Host "[dc01_dns] DNS Server running" }
else { Write-Host "[dc01_dns] WARNING: DNS Server not running after 30s" }

Write-Host "[dc01_dns] Ensuring zones are AD-integrated..."
$zone = Get-DnsServerZone -Name $domain -ErrorAction SilentlyContinue
if (-not ($zone -and $zone.IsDsIntegrated)) {
    ConvertTo-DnsServerPrimaryZone -Name $domain -ReplicationScope Domain -Force -ErrorAction SilentlyContinue
    Write-Host "[dc01_dns] $domain converted to AD-integrated"
}
$mszone = Get-DnsServerZone -Name "_msdcs.$domain" -ErrorAction SilentlyContinue
if (-not ($mszone -and $mszone.IsDsIntegrated)) {
    ConvertTo-DnsServerPrimaryZone -Name "_msdcs.$domain" -ReplicationScope Forest -Force -ErrorAction SilentlyContinue
    Write-Host "[dc01_dns] _msdcs.$domain converted to AD-integrated (Forest)"
}

Write-Host "[dc01_dns] Restarting Netlogon to register SRV records..."
Restart-Service Netlogon -Force -ErrorAction SilentlyContinue
Wait-ServiceRunning -Name Netlogon -TimeoutSec 30 | Out-Null
$nlStatus = (Get-Service Netlogon -ErrorAction SilentlyContinue).Status
Write-Host "[dc01_dns] Netlogon status: $nlStatus"

Write-Host "[dc01_dns] Verifying critical SRV records exist..."
$srvVerified = $false
for ($i = 1; $i -le 10; $i++) {
    $result = nslookup -type=srv _ldap._tcp.$domain 127.0.0.1 2>&1
    if ($result -match "svr hostname") {
        Write-Host "[dc01_dns] _ldap SRV record found via nslookup"
        $srvVerified = $true
        break
    }
    Write-Host "[dc01_dns] Waiting for SRV records (attempt $i/10)..."
    Start-Sleep 6
    if ($i -eq 2) {
        Write-Host "[dc01_dns] Forcing Netlogon DNS registration..."
        nltest /dsregdns 2>&1 | Out-Null
    }
}
if (-not $srvVerified) {
    Write-Host "[dc01_dns] ERROR: SRV records still missing after 60s!"
    Write-Host "[dc01_dns] Last attempt: restarting DNS + Netlogon one more time..."
    Restart-Service DNS -Force -ErrorAction SilentlyContinue
    Wait-ServiceRunning -Name DNS -TimeoutSec 20 | Out-Null
    Restart-Service Netlogon -Force -ErrorAction SilentlyContinue
    Wait-ServiceRunning -Name Netlogon -TimeoutSec 20 | Out-Null
    nltest /dsregdns 2>&1 | Out-Null
    Start-Sleep 10
    $result = nslookup -type=srv _ldap._tcp.$domain 127.0.0.1 2>&1
    if ($result -notmatch "svr hostname") {
        Write-Host "[dc01_dns] FATAL: SRV records could not be created. Aborting."
        exit 1
    }
    Write-Host "[dc01_dns] SRV records now present (verified by nslookup)"
}
Write-Host "[dc01_dns] SRV records verified successfully"

Write-Host "[dc01_dns] Forcing NLA re-detection (Private -> DomainAuthenticated)..."
# NLA classifies the network at boot before DNS/AD is reachable and caches
# "Private", never re-checking on its own. Set-NetConnectionProfile cannot set
# DomainAuthenticated (that category is auto-assigned by NLA only). Bouncing
# the internal adapter forces a fresh NLA discovery now that AD/DNS are up.
# WinRM runs over the NAT adapter, so this does not drop the session.
$internal = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Where-Object {
    (Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -like "192.168.*"
} | Select-Object -First 1
if ($internal) {
    Restart-NetAdapter -Name $internal.Name -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 8
    $cat = (Get-NetConnectionProfile -InterfaceAlias $internal.Name -ErrorAction SilentlyContinue).NetworkCategory
    Write-Host "[dc01_dns] Network category on $($internal.Name): $cat"
}

Write-Host "[dc01_dns] Setting Domain Administrator password..."
try {
    $adminSec = ConvertTo-SecureString $adminPass -AsPlainText -Force
    Set-ADAccountPassword -Identity Administrator -NewPassword $adminSec -Reset -ErrorAction Stop
    Write-Host "[dc01_dns] Administrator password set"
} catch {
    Write-Host "[dc01_dns] Administrator password may already be set: $_"
}

Write-Host "[dc01_dns] Verifying DC status..."
try {
    $dcName = (Get-ADDomainController -Discover -DomainName $domain -ErrorAction Stop).Name
    Write-Host "[dc01_dns] Domain controller verified: $dcName"
    Import-Module ADDSDeployment -ErrorAction SilentlyContinue
} catch {
    Write-Host "[dc01_dns] WARNING: DC verification failed: $_"
}

Write-Host "[dc01_dns] Setting DNS forwarder..."
try {
    Add-DnsServerForwarder -IPAddress "8.8.8.8" -ErrorAction SilentlyContinue
    Write-Host "[dc01_dns] DNS forwarder set to 8.8.8.8"
} catch {
    Write-Host "[dc01_dns] DNS forwarder already exists or failed: $_"
}

Write-Host "[dc01_dns] Creating reverse lookup zone..."
try {
    Add-DnsServerPrimaryZone -NetworkId "192.168.200.0/24" -ReplicationScope Domain -ErrorAction Stop
    Write-Host "[dc01_dns] Reverse zone created"
} catch {
    Write-Host "[dc01_dns] Reverse zone may already exist"
}

Write-Host "[dc01_dns] Adding DNS A records..."
$records = @{
    "dc01"  = $dc01IP; "dc02" = $dc02IP; "dc03" = $dc03IP
    "srv01" = $srv01IP; "ws01" = $ws01IP; "ws02" = $ws02IP
    "lin01" = $lin01IP; "wpad" = $kaliIP
}
foreach ($name in $records.Keys) {
    try {
        Add-DnsServerResourceRecordA -Name $name -ZoneName $domain -IPv4Address $records[$name] -ErrorAction Stop
        Write-Host "[dc01_dns] DNS record: $name.$domain -> $($records[$name])"
    } catch {
        Write-Host "[dc01_dns] DNS record $name may already exist"
    }
}

Write-Host "[dc01_dns] Creating DNS delegation for subdomain $childDomain..."
try {
    Add-DnsServerZoneDelegation -Name $domain -ChildZoneName "it" -NameServer "dc03.$domain" -IPAddress $dc03IP -ErrorAction SilentlyContinue
    Write-Host "[dc01_dns] DNS delegation: it.$domain -> dc03 ($dc03IP)"
} catch {
    Write-Host "[dc01_dns] DNS delegation may already exist: $_"
}

Write-Host "[dc01_dns] Adding conditional forwarder for child domain..."
try {
    Add-DnsServerConditionalForwarderZone -Name $childDomain -MasterServers $dc03IP -ErrorAction SilentlyContinue
    Write-Host "[dc01_dns] Conditional forwarder for $childDomain -> $dc03IP"
} catch {
    Write-Host "[dc01_dns] Conditional forwarder may already exist"
}

Write-Host "[dc01_dns] Setting domain functional level..."
try {
    $currentMode = (Get-ADDomain -Identity $domain).DomainMode
    if ($currentMode -eq 'Windows2016Domain') {
        Write-Host "[dc01_dns] Domain functional level already $currentMode, skipping"
    } else {
        Set-ADDomainMode -Identity $domain -DomainMode Windows2016Domain -ErrorAction Stop
        Write-Host "[dc01_dns] Domain functional level set to Windows2016Domain"
    }
} catch {
    Write-Host "[dc01_dns] Domain functional level check/set: $_"
}

Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\10" -Name "ConfigurationStatus" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue

Write-Host "[dc01_dns] Installing LAPS (offline-first fallback)..."
$lapsLocal = "C:\vagrant\LAPS.x64.msi"
$lapsTemp  = "C:\Windows\Temp\LAPS.x64.msi"
if (Test-Path $lapsLocal) {
    Start-Process msiexec.exe -ArgumentList "/i `"$lapsLocal`" /quiet /norestart" -Wait
    Write-Host "[dc01_dns] LAPS installed from local file"
} elseif (Test-Path $lapsTemp) {
    Start-Process msiexec.exe -ArgumentList "/i `"$lapsTemp`" /quiet /norestart" -Wait
    Write-Host "[dc01_dns] LAPS installed from cached file"
} else {
    try {
        $lapsUrl = "https://download.microsoft.com/download/C/7/A/C7AAD914-A8A6-4904-88A1-29E657445D03/LAPS.x64.msi"
        Invoke-WebRequest -Uri $lapsUrl -OutFile $lapsTemp -TimeoutSec 30 -ErrorAction Stop
        Start-Process msiexec.exe -ArgumentList "/i `"$lapsTemp`" /quiet /norestart" -Wait
        Write-Host "[dc01_dns] LAPS installed from internet"
    } catch {
        Write-Host "[dc01_dns] WARNING: LAPS unavailable"
    }
}

Write-Host "[dc01_dns] Cleaning stale NAT / IPv6 leaks from DNS zones..."
# Durable, idempotent NAT-leak cleanup. 10.0.2.15 is every VM's own NAT IP, so a
# leaked "<host> -> 10.0.2.x" A record (or a link-local/ULA AAAA record) makes
# clients round-robin onto themselves and breaks Kerberos/replication/joins.
# Runs on every DNS provision so the leak (which DCs can transiently re-register
# under DHCP timing) never survives into a member join. Only touches NAT-range A
# records and AAAA records in the forward zones — never 192.168.200.x records,
# machine accounts, or services.
$leakZones = Get-DnsServerZone | Where-Object { $_.ZoneType -eq "Primary" -and -not $_.IsReverseLookupZone -and $_.ZoneName -notlike "*arpa*" }
foreach ($z in $leakZones) {
    $zoneName = $z.ZoneName
    Get-DnsServerResourceRecord -ZoneName $zoneName -RRType A -ErrorAction SilentlyContinue | ForEach-Object {
        $ip = $_.RecordData.IPv4Address.IPAddressToString
        if ($ip -like "10.0.2.*") {
            Write-Host "[dc01_dns] Removing stale A: $($_.HostName) -> $ip from $zoneName"
            Remove-DnsServerResourceRecord -ZoneName $zoneName -RRType A -Name $_.HostName -RecordData $ip -Force -ErrorAction SilentlyContinue
        }
    }
    # AD DNS should be IPv4-only in this lab; any AAAA is a NAT/VirtualBox IPv6
    # leak (e.g. the dc02 AAAA seen in the DC03 session). Strip them all.
    Get-DnsServerResourceRecord -ZoneName $zoneName -RRType AAAA -ErrorAction SilentlyContinue | ForEach-Object {
        $ip6 = $_.RecordData.IPv6Address.IPAddressToString
        Write-Host "[dc01_dns] Removing AAAA leak: $($_.HostName) -> $ip6 from $zoneName"
        Remove-DnsServerResourceRecord -ZoneName $zoneName -RRType AAAA -Name $_.HostName -RecordData $ip6 -Force -ErrorAction SilentlyContinue
    }
}
Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
Clear-DnsClientCache -ErrorAction SilentlyContinue
Write-Host "[dc01_dns] Disabling IPv6 DNS server registration..."
Import-Module DnsServer -ErrorAction SilentlyContinue
if (Get-Command Set-DnsServerGlobalSetting -ErrorAction SilentlyContinue) {
    Set-DnsServerGlobalSetting -EnableIPv6 $false -ErrorAction SilentlyContinue
}

Write-Host "[dc01_dns] Done"
