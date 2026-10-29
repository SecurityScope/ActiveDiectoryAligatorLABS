$ErrorActionPreference = "Continue"

Write-Host "[dc02_join] Starting AD DS promotion..."

$domain    = $env:DOMAIN
$adminPass = $env:ADMIN_PASS
$dc01IP    = $env:DC01_IP
$dcIP      = $env:DC_IP

# Re-assert the internal static IP before anything else. After sysprep + the
# rename-commit reload, the internal natnetwork adapter can revert to DHCP and
# (no DHCP on the LAN) fall back to APIPA 169.254.x, so dc_base.ps1's static IP
# doesn't always survive - leaving DC01 unreachable at promotion time. Identify
# the internal adapter as the Up one NOT on the 10.0.2.x NAT, re-enable it if
# sysprep left it errored, and pin $dcIP.
if ($dcIP) {
    Write-Host "[dc02_join] Ensuring internal static IP $dcIP..."
    $errored = Get-PnpDevice -Class Net -Status Error -ErrorAction SilentlyContinue
    foreach ($d in $errored) { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
    if ($errored) { Start-Sleep 5 }
    $intf = $null
    foreach ($a in (Get-NetAdapter | Where-Object Status -eq 'Up')) {
        $aip = (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
        if ($aip -notlike '10.0.2.*') { $intf = $a; break }
    }
    if ($intf) {
        $curr = (Get-NetIPAddress -InterfaceIndex $intf.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
        if ($curr -ne $dcIP) {
            Write-Host "[dc02_join] Internal adapter '$($intf.Name)' is '$curr'; setting static $dcIP"
            Get-NetIPAddress -InterfaceIndex $intf.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            # No default gateway: the internal adapter must not outrank the NAT
            # adapter's default route (WinRM rides the NAT adapter).
            netsh interface ip set address name="$($intf.Name)" static $dcIP 255.255.255.0 | Out-Null
            Set-NetIPInterface -InterfaceIndex $intf.InterfaceIndex -Dhcp Disabled -ErrorAction SilentlyContinue
            Set-DnsClientServerAddress -InterfaceIndex $intf.InterfaceIndex -ServerAddresses $dc01IP -ErrorAction SilentlyContinue
            Start-Sleep 3
        } else {
            Write-Host "[dc02_join] Internal adapter already on $dcIP"
        }
    } else {
        Write-Host "[dc02_join] WARNING: could not identify internal (non-NAT) adapter"
    }
}

Write-Host "[dc02_join] Waiting for DC01 to be reachable..."
$reachable = $false
for ($i = 1; $i -le 10; $i++) {
    if (Test-Connection $dc01IP -Count 1 -Quiet) {
        $reachable = $true
        Write-Host "[dc02_join] DC01 reachable"
        break
    }
    Write-Host "[dc02_join] Attempt $i/10, waiting..."
    Start-Sleep 5
}
if (-not $reachable) {
    Write-Host "[dc02_join] ERROR: DC01 not reachable after 50s"
    exit 1
}

Write-Host "[dc02_join] Setting DNS to DC01 ($dc01IP) on natnetwork adapters..."
$netAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
foreach ($adapter in $netAdapters) {
    $ips = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ips.IPAddress -like "192.168.*") {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $dc01IP
        Write-Host "[dc02_join] DNS set on adapter: $($adapter.Name) (192.168.x)"
    } else {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses "127.0.0.1" -ErrorAction SilentlyContinue
        Set-DnsClient -InterfaceIndex $adapter.InterfaceIndex -RegisterThisConnectionsAddress $false
        Write-Host "[dc02_join] DNS set to 127.0.0.1 on adapter: $($adapter.Name) (NAT, no dyn reg)"
    }
}
Clear-DnsClientCache
Write-Host "[dc02_join] DNS cache flushed"

Write-Host "[dc02_join] Pinning secscope.corp to DC01 IP in hosts file..."
if (-not (Select-String -Path "$env:windir\System32\drivers\etc\hosts" `
        -Pattern "secscope.corp" -SimpleMatch -Quiet)) {
    Add-Content -Path "$env:windir\System32\drivers\etc\hosts" `
        -Value "$dc01IP secscope.corp dc01.secscope.corp dc01" -Force
    Write-Host "[dc02_join] Hosts file entry added"
} else {
    Write-Host "[dc02_join] Hosts file entry already exists"
}

Write-Host "[dc02_join] Syncing clock with DC01 ($dc01IP)..."
try {
    w32tm /resync 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        w32tm /config /syncfromflags:manual /manualpeerlist:$dc01IP 2>&1 | Out-Null
        w32tm /resync 2>&1 | Out-Null
    }
    $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[dc02_join] Clock synced. Current time: $currentTime"
} catch {
    Write-Host "[dc02_join] WARNING: Time sync failed: $_"
    Write-Host "[dc02_join] Current time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "[dc02_join] AD requires clocks within 5 minutes of each other."
}

Write-Host "[dc02_join] Verifying SRV records for $domain..."
$srvOk = $false
for ($i = 1; $i -le 6; $i++) {
    $result = nslookup -type=srv "_ldap._tcp.$domain" $dc01IP 2>&1
    if ($result -match "svr hostname") {
        Write-Host "[dc02_join] SRV record found via nslookup"
        $srvOk = $true
        break
    }
    Write-Host "[dc02_join] SRV lookup attempt $i/6, waiting..."
    Start-Sleep 5
}
if (-not $srvOk) {
    Write-Host "[dc02_join] ERROR: _ldap SRV records not found for $domain. DC01 DNS may not be ready."
    exit 1
}

Write-Host "[dc02_join] Installing AD-Domain-Services..."
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

Write-Host "[dc02_join] Joining as additional domain controller..."
try {
    $dcRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
    if ($dcRole -ge 4) {
        Write-Host "[dc02_join] Already a domain controller (role $dcRole), skipping promotion"
        exit 0
    }
} catch {}
$secPass = ConvertTo-SecureString $adminPass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("Administrator@$domain", $secPass)
Write-Host "[dc02_join] Cleaning up any stale DC02 AD objects..."
try {
    $staleComputer = Get-ADComputer -Identity "DC02" -Server $dc01IP -Credential $cred -ErrorAction Stop
    if ($staleComputer) {
        Remove-ADObject -Identity $staleComputer.ObjectGUID -Server $dc01IP -Credential $cred -Recursive -Confirm:$false -ErrorAction Stop
        Write-Host "[dc02_join] Removed stale DC02 AD object and children"
        Start-Sleep -Seconds 10
    }
} catch {
    Write-Host "[dc02_join] No stale DC02 to clean (this is fine on first run)"
}
Write-Host "[dc02_join] Promoting to additional DC (retry up to 5 times)..."
$dsrmSec = ConvertTo-SecureString $adminPass -AsPlainText -Force

$promoted = $false
$retryDelays = @(10, 20, 30, 40, 60)
for ($i = 1; $i -le 5; $i++) {
    Write-Host "[dc02_join] Attempt $i/5..."
    try {
        Install-ADDSDomainController -DomainName $domain -Credential $cred -SafeModeAdministratorPassword $dsrmSec -Force -NoRebootOnCompletion:$true -ErrorAction Stop
        $promoted = $true
        Write-Host "[dc02_join] Promotion succeeded"
        break
    } catch {
        Write-Host "[dc02_join] Attempt $i/5 failed: $_"
        if ($i -lt 5) { Start-Sleep -Seconds $retryDelays[$i-1] }
    }
}
if (-not $promoted) {
    Write-Host "[dc02_join] ERROR: Failed to promote after 5 attempts"
    exit 1
}

Write-Host "[dc02_join] Setting Administrator password..."
net user Administrator $adminPass 2>&1 | Out-Null
Write-Host "[dc02_join] Administrator password set"

Write-Host "[dc02_join] Enabling AD Web Services..."
Set-Service ADWS -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service ADWS -ErrorAction SilentlyContinue

Write-Host "[dc02_join] Disabling IPv6 DNS registration..."
# Registry method (next boot), not a live unbind: the latter resets TCP and can
# cut the connection the post-promotion DNS steps rely on.
$tcpip6 = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
if (-not (Test-Path $tcpip6)) { New-Item -Path $tcpip6 -Force | Out-Null }
Set-ItemProperty -Path $tcpip6 -Name 'DisabledComponents' -Value 0xFF -Type DWord -Force
Get-NetAdapter | ForEach-Object {
    # Keep IPv4 connection registration on the internal (192.168.x) adapter so
    # Netlogon can publish DC02's DC-locator SRV records; only disable it on
    # the NAT adapter to keep its WAN IP out of the AD DNS zones.
    $ip = (Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    if ($ip -notlike "192.168.*") {
        Set-DnsClient -InterfaceIndex $_.InterfaceIndex -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue
    } else {
        Set-DnsClient -InterfaceIndex $_.InterfaceIndex -RegisterThisConnectionsAddress $true -ErrorAction SilentlyContinue
    }
}
Set-DnsServerGlobalSetting -EnableIPv6 $false -ErrorAction SilentlyContinue

Write-Host "[dc02_join] Promotion completed. Reboot required (vagrant reload dc02)."
