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
    Set-DnsClient -InterfaceIndex $a.InterfaceIndex -RegisterThisConnectionsAddress $false
    Write-Host "[dc03_postboot] DNS on $($a.Name) -> 127.0.0.1,$dc01IP (no dyn reg)"
}
Clear-DnsClientCache

Write-Host "[dc03_postboot] Restarting NLA (network profile re-detection)..."
Restart-Service NlaSvc -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

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
    Set-DnsClient -InterfaceIndex $_.InterfaceIndex -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue
}
Set-DnsServerGlobalSetting -EnableIPv6 $false -ErrorAction SilentlyContinue

Write-Host "[dc03_postboot] Registering DNS records..."
ipconfig /registerdns 2>&1 | Out-Null
nltest /dsregdns 2>&1 | Out-Null

Write-Host "[dc03_postboot] Clearing Server Manager post-deployment flag..."
@("AD-Domain-Services") | ForEach-Object {
    $path = "HKLM:\SOFTWARE\Microsoft\ServerManager\ServicingStorage\ServerComponentCache\$_"
    if (Test-Path $path) {
        Set-ItemProperty -Path $path -Name "PostInstallComplete" -Value 1 -ErrorAction SilentlyContinue
    }
}

Write-Host "[dc03_postboot] Done"
