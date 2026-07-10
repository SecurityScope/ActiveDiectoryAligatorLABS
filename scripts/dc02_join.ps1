$ErrorActionPreference = "Continue"

Write-Host "[dc02_join] Starting AD DS promotion..."

$domain    = $env:DOMAIN
$adminPass = $env:ADMIN_PASS
$dc01IP    = $env:DC01_IP

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
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses -ErrorAction SilentlyContinue
        Set-DnsClient -InterfaceIndex $adapter.InterfaceIndex -RegisterThisConnectionsAddress $false
        Write-Host "[dc02_join] Reset DNS on adapter: $($adapter.Name) (use DHCP, no dyn reg)"
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
Get-NetAdapter | ForEach-Object {
    Disable-NetAdapterBinding -InterfaceAlias $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    Set-DnsClient -InterfaceIndex $_.InterfaceIndex -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue
}
Set-DnsServerGlobalSetting -EnableIPv6 $false -ErrorAction SilentlyContinue

Write-Host "[dc02_join] Promotion completed. Reboot required (vagrant reload dc02)."
