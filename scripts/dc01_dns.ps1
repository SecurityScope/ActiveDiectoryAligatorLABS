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
        $null = Get-ADDomainController -Discover -ErrorAction Stop
        $ready = $true
        Write-Host "[dc01_dns] AD services ready (attempt $i)"
        break
    } catch {
        Write-Host "[dc01_dns] Attempt $i/12, waiting..."
        Start-Sleep 5
    }
}
if (-not $ready) {
    Write-Host "[dc01_dns] ERROR: AD Domain Services not found after 60s."
    Write-Host "[dc01_dns] Did you run 'vagrant reload dc01' after the postboot provisioner?"
    exit 1
}

Write-Host "[dc01_dns] Triggering network profile re-detection (NLA)..."
Restart-Service NlaSvc -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
Write-Host "[dc01_dns] Network profiles re-evaluated"

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
    Write-Host "[dc01_dns] DC promotion confirmed"
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
    "dc01"  = $dc01IP
    "dc02"  = $dc02IP
    "dc03"  = $dc03IP
    "srv01" = $srv01IP
    "ws01"  = $ws01IP
    "ws02"  = $ws02IP
    "lin01" = $lin01IP
    "wpad"  = $kaliIP
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
    Write-Host "[dc01_dns] DNS delegation for subdomain may already exist: $_"
}

Write-Host "[dc01_dns] Adding conditional forwarder for child domain..."
try {
    Add-DnsServerConditionalForwarderZone -Name $childDomain -MasterServers $dc03IP -ErrorAction SilentlyContinue
    Write-Host "[dc01_dns] Conditional forwarder for $childDomain -> $dc03IP"
} catch {
    Write-Host "[dc01_dns] Conditional forwarder for child domain may already exist"
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
    Write-Host "[dc01_dns] Found local LAPS MSI, installing..."
    Start-Process msiexec.exe -ArgumentList "/i `"$lapsLocal`" /quiet /norestart" -Wait
    Write-Host "[dc01_dns] LAPS installed from local file"
} elseif (Test-Path $lapsTemp) {
    Write-Host "[dc01_dns] Found cached LAPS MSI, installing..."
    Start-Process msiexec.exe -ArgumentList "/i `"$lapsTemp`" /quiet /norestart" -Wait
    Write-Host "[dc01_dns] LAPS installed from cached file"
} else {
    try {
        $lapsUrl = "https://download.microsoft.com/download/C/7/A/C7AAD914-A8A6-4904-88A1-29E657445D03/LAPS.x64.msi"
        Invoke-WebRequest -Uri $lapsUrl -OutFile $lapsTemp -TimeoutSec 120 -ErrorAction Stop
        Write-Host "[dc01_dns] LAPS downloaded, installing..."
        Start-Process msiexec.exe -ArgumentList "/i `"$lapsTemp`" /quiet /norestart" -Wait
        Write-Host "[dc01_dns] LAPS installed from internet"
    } catch {
        Write-Host "[dc01_dns] WARNING: LAPS unavailable. Place LAPS.x64.msi in ActiveDirectoryAlligatorLABS/ folder or download from https://www.microsoft.com/en-us/download/details.aspx?id=46899"
    }
}

Write-Host "[dc01_dns] Cleaning up stale NAT IPs from DNS zone..."
$zone = $domain
Get-DnsServerResourceRecord -ZoneName $zone -RRType A -ErrorAction SilentlyContinue | ForEach-Object {
    $ip = $_.RecordData.IPv4Address.IPAddressToString
    if ($ip -like "10.0.2.*") {
        Write-Host "[dc01_dns] Removing stale A record: $($_.HostName) -> $ip"
        Remove-DnsServerResourceRecord -ZoneName $zone -RRType A -Name $_.HostName -RecordData $ip -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "[dc01_dns] Disabling IPv6 DNS server registration..."
Set-DnsServerGlobalSetting -EnableIPv6 $false -ErrorAction SilentlyContinue
Get-DnsServerResourceRecord -ZoneName $zone -RRType AAAA -ErrorAction SilentlyContinue | ForEach-Object {
    $ip = $_.RecordData.IPv6Address.IPAddressToString
    if ($ip -like "fd17*") {
        Write-Host "[dc01_dns] Removing stale AAAA record: $($_.HostName) -> $ip"
        Remove-DnsServerResourceRecord -ZoneName $zone -RRType AAAA -Name $_.HostName -RecordData $ip -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[dc01_dns] Done"
