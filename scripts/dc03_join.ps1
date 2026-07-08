$ErrorActionPreference = "Continue"

Write-Host "[dc03_join] Starting subdomain promotion..."

$domain      = $env:DOMAIN
$childDomain = $env:CHILD_DOMAIN
$adminPass   = $env:ADMIN_PASS
$dc01IP      = $env:DC01_IP

Write-Host "[dc03_join] Waiting for DC01 to be reachable..."
$reachable = $false
for ($i = 1; $i -le 10; $i++) {
    if (Test-Connection $dc01IP -Count 1 -Quiet) {
        $reachable = $true
        Write-Host "[dc03_join] DC01 reachable"
        break
    }
    Write-Host "[dc03_join] Attempt $i/10, waiting..."
    Start-Sleep 5
}
if (-not $reachable) {
    Write-Host "[dc03_join] ERROR: DC01 not reachable after 50s"
    exit 1
}

Write-Host "[dc03_join] Setting DNS to DC01 ($dc01IP) on internal adapter..."
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
$mgmtNic = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1).InterfaceIndex
$intNic  = $adapters | Where-Object { $_.InterfaceIndex -ne $mgmtNic } | Select-Object -First 1
if ($intNic) {
    Set-DnsClientServerAddress -InterfaceIndex $intNic.InterfaceIndex -ServerAddresses $dc01IP
    Write-Host "[dc03_join] DNS set on internal adapter: $($intNic.Name)"
} else {
    Write-Host "[dc03_join] WARNING: Could not find internal adapter, setting DNS on all adapters..."
    foreach ($adapter in $adapters) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $dc01IP
        Write-Host "[dc03_join] DNS set on adapter: $($adapter.Name)"
    }
}
Clear-DnsClientCache
Write-Host "[dc03_join] DNS cache flushed"

Write-Host "[dc03_join] Verifying DNS resolution of secscope.corp..."
$dnsOk = $false
for ($i = 1; $i -le 6; $i++) {
    try {
        $resolved = Resolve-DnsName "secscope.corp" -ErrorAction Stop
        Write-Host "[dc03_join] secscope.corp resolved to: $($resolved.IPAddress)"
        $dnsOk = $true
        break
    } catch {
        Write-Host "[dc03_join] DNS resolution attempt $i/6, waiting..."
        Start-Sleep 3
    }
}
if (-not $dnsOk) {
    Write-Host "[dc03_join] ERROR: Cannot resolve secscope.corp after 18s. Check DC01 is running and reachable."
    exit 1
}

Write-Host "[dc03_join] Pinning secscope.corp to DC01 IP in hosts file..."
if (-not (Select-String -Path "$env:windir\System32\drivers\etc\hosts" `
        -Pattern "secscope.corp" -SimpleMatch -Quiet)) {
    Add-Content -Path "$env:windir\System32\drivers\etc\hosts" `
        -Value "$dc01IP secscope.corp dc01.secscope.corp dc01" -Force
    Write-Host "[dc03_join] Hosts file entry added"
} else {
    Write-Host "[dc03_join] Hosts file entry already exists"
}

Write-Host "[dc03_join] Syncing clock with DC01 ($dc01IP)..."
try {
    w32tm /resync 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        w32tm /config /syncfromflags:manual /manualpeerlist:$dc01IP 2>&1 | Out-Null
        w32tm /resync 2>&1 | Out-Null
    }
    $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[dc03_join] Clock synced. Current time: $currentTime"
} catch {
    Write-Host "[dc03_join] WARNING: Time sync failed: $_"
    Write-Host "[dc03_join] Current time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "[dc03_join] AD requires clocks within 5 minutes of each other."
}

Write-Host "[dc03_join] Installing AD-Domain-Services and DNS..."
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

Write-Host "[dc03_join] Resolving OU name conflict for child domain..."
try {
    $conflictingOU = Get-ADOrganizationalUnit -Identity "OU=IT,DC=secscope,DC=corp" -ErrorAction SilentlyContinue
    if ($conflictingOU) {
        Write-Host "[dc03_join] Temporarily renaming OU=IT to avoid conflict..."
        Rename-ADObject -Identity $conflictingOU.DistinguishedName -NewName "IT_TEMP" -ErrorAction Stop
        Write-Host "[dc03_join] OU renamed to IT_TEMP"
    }
} catch { Write-Host "[dc03_join] No OU conflict found" }

Write-Host "[dc03_join] Importing ADDSDeployment module..."
Import-Module ADDSDeployment -ErrorAction SilentlyContinue
Import-Module ActiveDirectory -ErrorAction SilentlyContinue

Write-Host "[dc03_join] Creating subdomain $childDomain under $domain..."
try {
    $dcRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
    if ($dcRole -ge 4) {
        Write-Host "[dc03_join] Already a domain controller (role $dcRole), skipping promotion"
        exit 0
    }
} catch {}
try {
    $null = Get-ADDomain -Identity $childDomain -ErrorAction Stop
    Write-Host "[dc03_join] Subdomain $childDomain already exists, skipping promotion"
    exit 0
} catch {}
$secPass = ConvertTo-SecureString $adminPass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("Administrator@$domain", $secPass)
Write-Host "[dc03_join] Cleaning up any stale DC03 AD objects..."
try {
    $staleComputer = Get-ADComputer -Identity "DC03" -Server $dc01IP -Credential $cred -ErrorAction Stop
    if ($staleComputer) {
        Remove-ADObject -Identity $staleComputer.ObjectGUID -Server $dc01IP -Credential $cred -Recursive -Confirm:$false -ErrorAction Stop
        Write-Host "[dc03_join] Removed stale DC03 AD object and children"
        Start-Sleep -Seconds 10
    }
} catch {
    Write-Host "[dc03_join] No stale DC03 to clean (this is fine on first run)"
}
Write-Host "[dc03_join] Installing subdomain (retry up to 5 times)..."
$dsrmSec = ConvertTo-SecureString $adminPass -AsPlainText -Force
$promoted = $false
$retryDelays = @(10, 20, 30, 40, 60)
for ($i = 1; $i -le 5; $i++) {
    Write-Host "[dc03_join] Attempt $i/5..."
    try {
        Install-ADDSDomain -NewDomainName "it" -ParentDomainName $domain -DomainType ChildDomain -NewDomainNetbiosName "ITSEC" -Credential $cred -SafeModeAdministratorPassword $dsrmSec -Force -NoRebootOnCompletion:$true -ErrorAction Stop
        $promoted = $true
        Write-Host "[dc03_join] Subdomain install succeeded"
        Write-Host "[dc03_join] Setting Administrator password..."
        net user Administrator $adminPass 2>&1 | Out-Null
        Write-Host "[dc03_join] Administrator password set"
        Write-Host "[dc03_join] OU IT renamed to IT_TEMP for child domain compatibility."
        break
    } catch {
        Write-Host "[dc03_join] Attempt $i/5 failed: $_"
        if ($i -lt 5) { Start-Sleep -Seconds $retryDelays[$i-1] }
    }
}
if (-not $promoted) {
    Write-Host "[dc03_join] ERROR: Failed to install subdomain after 5 attempts"
    exit 1
}

Write-Host "[dc03_join] Enabling AD Web Services..."
Set-Service ADWS -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service ADWS -ErrorAction SilentlyContinue

Write-Host "[dc03_join] Disabling IPv6 DNS registration..."
Get-NetAdapter | ForEach-Object {
    Disable-NetAdapterBinding -InterfaceAlias $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    Set-DnsClient -InterfaceIndex $_.InterfaceIndex -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue
}
Set-DnsServerGlobalSetting -EnableIPv6 $false -ErrorAction SilentlyContinue

Write-Host "[dc03_join] Subdomain install completed successfully. Reboot required (vagrant reload dc03)."
