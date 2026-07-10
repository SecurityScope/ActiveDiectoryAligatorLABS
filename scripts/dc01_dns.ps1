$ErrorActionPreference = "Continue"

Write-Host "[dc01_dns] Starting DNS and services setup..."

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
    Set-DnsClient -InterfaceIndex $a.InterfaceIndex -RegisterThisConnectionsAddress $false
}
Clear-DnsClientCache
Write-Host "[dc01_dns] DNS client -> 127.0.0.1 on all adapters"

Write-Host "[dc01_dns] Ensuring DNS server uses AD storage..."
dnscmd localhost /Config /DsAvailable 1 2>&1 | Out-Null
$zoneFile = "$env:SystemRoot\System32\DNS\$domain.dns"
$msdcsFile = "$env:SystemRoot\System32\DNS\_msdcs.$domain.dns"
Remove-Item $zoneFile -Force -ErrorAction SilentlyContinue
Remove-Item $msdcsFile -Force -ErrorAction SilentlyContinue
Write-Host "[dc01_dns] Deleted stale zone files"

Write-Host "[dc01_dns] Restarting DNS Server..."
Restart-Service DNS -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 15
Write-Host "[dc01_dns] DNS Server restarted"

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
Start-Sleep -Seconds 20
$nlStatus = (Get-Service Netlogon -ErrorAction SilentlyContinue).Status
Write-Host "[dc01_dns] Netlogon status: $nlStatus"

Write-Host "[dc01_dns] Verifying critical SRV records exist..."
$criticalSRV = @(
    "_ldap._tcp.$domain",
    "_kerberos._tcp.$domain",
    "_gc._tcp.$domain",
    "_ldap._tcp.Default-First-Site-Name._sites.$domain",
    "_ldap._tcp.dc._msdcs.$domain"
)

$srvVerified = $false
for ($i = 1; $i -le 8; $i++) {
    try {
        $found = $false
        foreach ($name in $criticalSRV) {
            $srv = Resolve-DnsName $name -Type SRV -Server 127.0.0.1 -ErrorAction Stop
            if ($srv) {
                Write-Host "[dc01_dns] SRV OK: $name -> $($srv.NameTarget)"
                $found = $true
                break
            }
        }
        if ($found) {
            $srvVerified = $true
            break
        }
    } catch { }
    Write-Host "[dc01_dns] Waiting for SRV records (attempt $i/8)..."
    Start-Sleep 15
    if ($i -eq 4) {
        Write-Host "[dc01_dns] Forcing Netlogon DNS registration..."
        nltest /dsregdns 2>&1 | Out-Null
        Start-Sleep 10
    }
}
if (-not $srvVerified) {
    Write-Host "[dc01_dns] ERROR: SRV records still missing after 120s!"
    Write-Host "[dc01_dns] Last attempt: restarting DNS + Netlogon one more time..."
    Restart-Service DNS -Force -ErrorAction SilentlyContinue
    Start-Sleep 10
    Restart-Service Netlogon -Force -ErrorAction SilentlyContinue
    Start-Sleep 30
    try {
        $srv = Resolve-DnsName "_ldap._tcp.$domain" -Type SRV -Server 127.0.0.1 -ErrorAction Stop
        if (-not $srv) { Write-Host "[dc01_dns] FATAL: Unable to create SRV records. Aborting."; exit 1 }
        Write-Host "[dc01_dns] SRV records now present: $($srv.NameTarget)"
    } catch { Write-Host "[dc01_dns] FATAL: DNS resolution still fails. Aborting."; exit 1 }
}
Write-Host "[dc01_dns] SRV records verified successfully"

Write-Host "[dc01_dns] Restarting NLA (network profile re-detection)..."
Restart-Service NlaSvc -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

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

Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\10" -Name "ConfigurationStatus" -Value 0 -ErrorAction SilentlyContinue

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
        Invoke-WebRequest -Uri $lapsUrl -OutFile $lapsTemp -TimeoutSec 120 -ErrorAction Stop
        Start-Process msiexec.exe -ArgumentList "/i `"$lapsTemp`" /quiet /norestart" -Wait
        Write-Host "[dc01_dns] LAPS installed from internet"
    } catch {
        Write-Host "[dc01_dns] WARNING: LAPS unavailable"
    }
}

Write-Host "[dc01_dns] Cleaning stale NAT IPs from DNS zones..."
Get-DnsServerZone | Where-Object ZoneType -eq "Primary" | ForEach-Object {
    $zoneName = $_.ZoneName
    Get-DnsServerResourceRecord -ZoneName $zoneName -RRType A -ErrorAction SilentlyContinue | ForEach-Object {
        $ip = $_.RecordData.IPv4Address.IPAddressToString
        if ($ip -like "10.0.2.*") {
            Write-Host "[dc01_dns] Removing stale A: $($_.HostName) -> $ip from $zoneName"
            Remove-DnsServerResourceRecord -ZoneName $zoneName -RRType A -Name $_.HostName -RecordData $ip -Force -ErrorAction SilentlyContinue
        }
    }
}
Write-Host "[dc01_dns] Disabling IPv6 DNS server registration..."
Set-DnsServerGlobalSetting -EnableIPv6 $false -ErrorAction SilentlyContinue

Write-Host "[dc01_dns] Done"
