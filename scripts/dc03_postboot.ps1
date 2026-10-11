$ErrorActionPreference = "Continue"

Write-Host "[dc03_postboot] Starting post-promotion configuration..."

$domain      = $env:DOMAIN
$childDomain = $env:CHILD_DOMAIN
$adminPass   = $env:ADMIN_PASS
$dc01IP      = $env:DC01_IP

Write-Host "[dc03_postboot] Waiting for AD services..."
$ready = $false
for ($i = 1; $i -le 24; $i++) {
    try {
        $null = Get-ADDomain -ErrorAction Stop
        $ready = $true
        Write-Host "[dc03_postboot] AD services ready (attempt $i)"
        break
    } catch {
        Write-Host "[dc03_postboot] Attempt $i/24, waiting..."
        Start-Sleep 5
    }
}
if (-not $ready) {
    Write-Host "[dc03_postboot] WARNING: AD services not ready after 120s. Continuing."
}

Write-Host "[dc03_postboot] Fixing DNS client on all adapters..."
$adapters = Get-NetAdapter | Where-Object Status -eq "Up"
foreach ($a in $adapters) {
    Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses "127.0.0.1",$dc01IP
    $ips = Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ips.IPAddress -like "192.168.*") {
        Set-DnsClient -InterfaceIndex $a.InterfaceIndex -RegisterThisConnectionsAddress $true
        Write-Host "[dc03_postboot] DNS on $($a.Name) -> 127.0.0.1,$dc01IP (registration ENABLED on internal $($ips.IPAddress))"
    } else {
        Set-DnsClient -InterfaceIndex $a.InterfaceIndex -RegisterThisConnectionsAddress $false
        Write-Host "[dc03_postboot] DNS on $($a.Name) -> 127.0.0.1,$dc01IP (no dyn reg)"
    }
}
Clear-DnsClientCache

Write-Host "[dc03_postboot] Forcing NLA re-detection (Private -> DomainAuthenticated)..."
$internal = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Where-Object {
    (Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -like "192.168.*"
} | Select-Object -First 1
if ($internal) {
    Restart-NetAdapter -Name $internal.Name -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 8
    $cat = (Get-NetConnectionProfile -InterfaceAlias $internal.Name -ErrorAction SilentlyContinue).NetworkCategory
    Write-Host "[dc03_postboot] Network category on $($internal.Name): $cat"
}

Write-Host "[dc03_postboot] Setting Administrator password..."
try {
    net user Administrator $adminPass 2>&1 | Out-Null
    Write-Host "[dc03_postboot] Administrator password set"
} catch {
    Write-Host "[dc03_postboot] Administrator password may already be set"
}

Write-Host "[dc03_postboot] Enabling AD Web Services..."
Set-Service ADWS -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service ADWS -ErrorAction SilentlyContinue
Start-Sleep 3
$adwsStatus = (Get-Service ADWS -ErrorAction SilentlyContinue).Status
Write-Host "[dc03_postboot] ADWS status: $adwsStatus"

Write-Host "[dc03_postboot] Verifying DC status..."
try {
    $dcName = (Get-ADDomainController -Discover -ErrorAction Stop).Name
    Write-Host "[dc03_postboot] Domain controller verified: $dcName"
    $domainInfo = Get-ADDomain -ErrorAction Stop
    Write-Host "[dc03_postboot] Domain: $($domainInfo.DNSRoot), Forest: $($domainInfo.Forest)"
} catch {
    Write-Host "[dc03_postboot] WARNING: DC verification failed: $_"
}

Write-Host "[dc03_postboot] Restoring parent OU name (IT_TEMP -> IT) on DC01..."
# dc03_join.ps1 temporarily renamed OU=IT to IT_TEMP on DC01 before creating the
# child domain. Rename it back now so dc01_objects.ps1 (and the IT/Workstations
# OU references it depends on) are consistent again. If the parent OU and the
# child domain label genuinely collide, this rename fails harmlessly and
# dc01_objects.ps1 self-heals by using whichever name exists.
try {
    $ppass = ConvertTo-SecureString $adminPass -AsPlainText -Force
    $pcred = New-Object System.Management.Automation.PSCredential("Administrator@$domain", $ppass)
    $parentDN = ($domain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
    $tempOU = Get-ADOrganizationalUnit -Identity "OU=IT_TEMP,$parentDN" -Server $dc01IP -Credential $pcred -ErrorAction SilentlyContinue
    $realOU = Get-ADOrganizationalUnit -Identity "OU=IT,$parentDN" -Server $dc01IP -Credential $pcred -ErrorAction SilentlyContinue
    if ($tempOU -and -not $realOU) {
        Rename-ADObject -Identity $tempOU.DistinguishedName -NewName "IT" -Server $dc01IP -Credential $pcred -ErrorAction Stop
        Write-Host "[dc03_postboot] OU IT_TEMP renamed back to IT"
    } elseif ($realOU) {
        Write-Host "[dc03_postboot] OU=IT already present; nothing to restore"
    } else {
        Write-Host "[dc03_postboot] No IT_TEMP OU found to restore"
    }
} catch {
    Write-Host "[dc03_postboot] OU rename-back skipped (left as IT_TEMP; dc01_objects self-heals): $_"
}

Write-Host "[dc03_postboot] Setting DNS forwarder..."
try {
    Add-DnsServerForwarder -IPAddress "8.8.8.8" -ErrorAction SilentlyContinue
    Write-Host "[dc03_postboot] DNS forwarder set to 8.8.8.8"
} catch {
    Set-DnsServerForwarder -IPAddress "8.8.8.8" -ErrorAction SilentlyContinue
}

Write-Host "[dc03_postboot] Adding conditional forwarder for parent domain..."
try {
    Add-DnsServerConditionalForwarderZone -Name $domain -MasterServers $dc01IP -ErrorAction SilentlyContinue
    Write-Host "[dc03_postboot] Conditional forwarder for $domain -> $dc01IP"
} catch {
    Write-Host "[dc03_postboot] Conditional forwarder may already exist: $_"
}

Write-Host "[dc03_postboot] Cleaning stale NAT IPs from all DNS zones..."
Get-DnsServerZone | Where-Object ZoneType -eq "Primary" | ForEach-Object {
    $zoneName = $_.ZoneName
    Get-DnsServerResourceRecord -ZoneName $zoneName -RRType A -ErrorAction SilentlyContinue | ForEach-Object {
        $ip = $_.RecordData.IPv4Address.IPAddressToString
        if ($ip -like "10.0.2.*") {
            Write-Host "[dc03_postboot] Removing stale A: $($_.HostName) -> $ip from $zoneName"
            Remove-DnsServerResourceRecord -ZoneName $zoneName -RRType A -Name $_.HostName -RecordData $ip -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "[dc03_postboot] Disabling IPv6 DNS registration..."
Get-NetAdapter | ForEach-Object {
    Disable-NetAdapterBinding -InterfaceAlias $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    $ips = Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ips.IPAddress -like "192.168.*") {
        Set-DnsClient -InterfaceIndex $_.InterfaceIndex -RegisterThisConnectionsAddress $true -ErrorAction SilentlyContinue
    } else {
        Set-DnsClient -InterfaceIndex $_.InterfaceIndex -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue
    }
}
Set-DnsServerGlobalSetting -EnableIPv6 $false -ErrorAction SilentlyContinue

Write-Host "[dc03_postboot] Registering DNS records..."
ipconfig /registerdns 2>&1 | Out-Null
nltest /dsregdns 2>&1 | Out-Null

Write-Host "[dc03_postboot] Verifying DC03 SRV self-registration (nltest reports success even on failure)..."
$srvOk = $false
for ($i = 1; $i -le 10; $i++) {
    $srv = nslookup -type=SRV "_ldap._tcp.$childDomain" 127.0.0.1 2>&1
    if ($srv -match "dc03") {
        Write-Host "[dc03_postboot] DC03 SRV registered: _ldap._tcp.$childDomain -> dc03"
        $srvOk = $true
        break
    }
    Write-Host "[dc03_postboot] SRV self-check attempt $i/10, re-registering and waiting..."
    if ($i -eq 2) {
        Restart-Service Netlogon -Force -ErrorAction SilentlyContinue
        Start-Sleep 3
        nltest /dsregdns 2>&1 | Out-Null
    }
    Start-Sleep 6
}
if (-not $srvOk) {
    Write-Host "[dc03_postboot] WARNING: DC03 _ldap SRV for $childDomain not found in local zone after retries."
}

Write-Host "[dc03_postboot] Cleaning stale Recycle Bin SID folders..."
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
        Write-Host "[dc03_postboot] Removing stale Recycle Bin for dangling SID $sid"
        Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[dc03_postboot] Clearing Server Manager post-deployment flag..."
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\10" -Name "ConfigurationStatus" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue

Write-Host "[dc03_postboot] Done"
