$ErrorActionPreference = "Continue"

Write-Host "[dc02_postboot] Starting post-promotion configuration..."

$domain    = $env:DOMAIN
$adminPass = $env:ADMIN_PASS
$dc01IP    = $env:DC01_IP
$dc03IP    = $env:DC03_IP

Write-Host "[dc02_postboot] Fixing DNS client on all adapters..."
$adapters = Get-NetAdapter | Where-Object Status -eq "Up"
foreach ($a in $adapters) {
    Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses "127.0.0.1",$dc01IP
    # The internal (natnetwork, 192.168.x) adapter MUST keep connection
    # registration enabled, otherwise Netlogon reports "No DNS servers
    # configured for local system" and silently fails to register DC02's own
    # DC-locator SRV records. Only disable registration on the NAT adapter
    # (10.0.2.x) so its WAN IP never pollutes the AD DNS zones.
    $ip = (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    if ($ip -like "192.168.*") {
        Set-DnsClient -InterfaceIndex $a.InterfaceIndex -RegisterThisConnectionsAddress $true
        Write-Host "[dc02_postboot] DNS on $($a.Name) -> 127.0.0.1,$dc01IP (registration ENABLED, internal $ip)"
    } else {
        Set-DnsClient -InterfaceIndex $a.InterfaceIndex -RegisterThisConnectionsAddress $false
        Write-Host "[dc02_postboot] DNS on $($a.Name) -> 127.0.0.1,$dc01IP (no dyn reg, $ip)"
    }
}
Clear-DnsClientCache

Write-Host "[dc02_postboot] Adding conditional forwarder for child domain..."
try {
    Add-DnsServerConditionalForwarderZone -Name "it.secscope.corp" -MasterServers $dc03IP -ErrorAction SilentlyContinue
    Write-Host "[dc02_postboot] Conditional forwarder for it.secscope.corp -> $dc03IP"
} catch {
    Write-Host "[dc02_postboot] Conditional forwarder may already exist: $_"
}

Write-Host "[dc02_postboot] Forcing NLA re-detection (Private -> DomainAuthenticated)..."
$internal = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Where-Object {
    (Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -like "192.168.*"
} | Select-Object -First 1
if ($internal) {
    Restart-NetAdapter -Name $internal.Name -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 8
    $cat = (Get-NetConnectionProfile -InterfaceAlias $internal.Name -ErrorAction SilentlyContinue).NetworkCategory
    Write-Host "[dc02_postboot] Network category on $($internal.Name): $cat"
}

Write-Host "[dc02_postboot] Enabling AD Web Services..."
Set-Service ADWS -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service ADWS -ErrorAction SilentlyContinue
Start-Sleep 3
$adwsStatus = (Get-Service ADWS -ErrorAction SilentlyContinue).Status
Write-Host "[dc02_postboot] ADWS status: $adwsStatus"

Write-Host "[dc02_postboot] Verifying DC status..."
try {
    $dc = Get-ADDomainController -Discover -ErrorAction Stop
    Write-Host "[dc02_postboot] Domain controller verified: $($dc.Name)"
    Write-Host "[dc02_postboot] Domain: $($dc.Domain)"
} catch {
    Write-Host "[dc02_postboot] WARNING: DC verification failed: $_"
}

Write-Host "[dc02_postboot] Cleaning stale NAT IPs from all DNS zones..."
Get-DnsServerZone | Where-Object ZoneType -eq "Primary" | ForEach-Object {
    $zoneName = $_.ZoneName
    Get-DnsServerResourceRecord -ZoneName $zoneName -RRType A -ErrorAction SilentlyContinue | ForEach-Object {
        $ip = $_.RecordData.IPv4Address.IPAddressToString
        if ($ip -like "10.0.2.*") {
            Write-Host "[dc02_postboot] Removing stale A: $($_.HostName) -> $ip from $zoneName"
            Remove-DnsServerResourceRecord -ZoneName $zoneName -RRType A -Name $_.HostName -RecordData $ip -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "[dc02_postboot] Registering DNS records..."
ipconfig /registerdns 2>&1 | Out-Null
nltest /dsregdns 2>&1 | Out-Null

Write-Host "[dc02_postboot] Verifying DC02 registered its own SRV records..."
# nltest /dsregdns can report success even when registration was silently
# rejected, so assert the DC02-specific SRV set exists in DNS directly.
$srvOk = $false
for ($i = 1; $i -le 10; $i++) {
    $result = nslookup -type=srv "_ldap._tcp.$domain" 127.0.0.1 2>&1
    if ($result -match "dc02\.$([regex]::Escape($domain))") {
        Write-Host "[dc02_postboot] DC02 SRV record present in $domain"
        $srvOk = $true
        break
    }
    Write-Host "[dc02_postboot] Waiting for DC02 SRV registration (attempt $i/10)..."
    Start-Sleep 6
    if ($i -eq 2) {
        Write-Host "[dc02_postboot] Forcing Netlogon DNS registration..."
        Restart-Service Netlogon -Force -ErrorAction SilentlyContinue
        Start-Sleep 4
        nltest /dsregdns 2>&1 | Out-Null
    }
}
if (-not $srvOk) {
    Write-Host "[dc02_postboot] WARNING: DC02 SRV records not yet visible (may lag behind replication)."
}

Write-Host "[dc02_postboot] Cleaning stale Recycle Bin SID folders..."
# sysprep /generalize and DC promotion both change this machine's identity, so
# the pre-change local Administrator's C:\$Recycle.Bin\<old-SID> folder is left
# owner-less. Windows then reports "The Recycle Bin on C:\ is corrupted" and
# prompts to empty it. Remove only folders whose SID no longer resolves.
Get-ChildItem -Path "C:\`$Recycle.Bin" -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "S-1-5-21-*" } | ForEach-Object {
    $sid = $_.Name
    $resolvable = $true
    try {
        $null = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount])
    } catch {
        $resolvable = $false
    }
    if (-not $resolvable) {
        Write-Host "[dc02_postboot] Removing stale Recycle Bin for dangling SID $sid"
        Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[dc02_postboot] Clearing Server Manager post-deployment flag..."
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\10" -Name "ConfigurationStatus" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue

Write-Host "[dc02_postboot] Done"
