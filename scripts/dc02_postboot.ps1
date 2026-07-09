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
    Set-DnsClient -InterfaceIndex $a.InterfaceIndex -RegisterThisConnectionsAddress $false
    Write-Host "[dc02_postboot] DNS on $($a.Name) -> 127.0.0.1,$dc01IP (no dyn reg)"
}
Clear-DnsClientCache

Write-Host "[dc02_postboot] Adding conditional forwarder for child domain..."
try {
    Add-DnsServerConditionalForwarderZone -Name "it.secscope.corp" -MasterServers $dc03IP -ErrorAction SilentlyContinue
    Write-Host "[dc02_postboot] Conditional forwarder for it.secscope.corp -> $dc03IP"
} catch {
    Write-Host "[dc02_postboot] Conditional forwarder may already exist: $_"
}

Write-Host "[dc02_postboot] Restarting NLA (network profile re-detection)..."
Restart-Service NlaSvc -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

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

Write-Host "[dc02_postboot] Clearing Server Manager post-deployment flag..."
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\10" -Name "ConfigurationStatus" -Value 0 -ErrorAction SilentlyContinue

Write-Host "[dc02_postboot] Done"
