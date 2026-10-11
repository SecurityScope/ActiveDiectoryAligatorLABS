$ErrorActionPreference = "Continue"

Write-Host "[dc03_join] Starting subdomain promotion..."

$domain      = $env:DOMAIN
$childDomain = $env:CHILD_DOMAIN
$adminPass   = $env:ADMIN_PASS
$dc01IP      = $env:DC01_IP
$dcIP        = $env:DC_IP

# Re-assert the internal static IP before contacting DC01. After sysprep + the
# rename-commit reload the internal natnetwork adapter can revert to DHCP and
# fall back to APIPA 169.254.x (no DHCP on the LAN), so dc_base.ps1's static IP
# doesn't always survive. Identify the internal adapter as the Up one NOT on the
# 10.0.2.x NAT, re-enable it if sysprep left it errored, and pin $dcIP.
if ($dcIP) {
    Write-Host "[dc03_join] Ensuring internal static IP $dcIP..."
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
            Write-Host "[dc03_join] Internal adapter '$($intf.Name)' is '$curr'; setting static $dcIP"
            Get-NetIPAddress -InterfaceIndex $intf.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            netsh interface ip set address name="$($intf.Name)" static $dcIP 255.255.255.0 192.168.200.1 | Out-Null
            Set-NetIPInterface -InterfaceIndex $intf.InterfaceIndex -Dhcp Disabled -ErrorAction SilentlyContinue
            Set-DnsClientServerAddress -InterfaceIndex $intf.InterfaceIndex -ServerAddresses $dc01IP -ErrorAction SilentlyContinue
            Start-Sleep 3
        } else {
            Write-Host "[dc03_join] Internal adapter already on $dcIP"
        }
    } else {
        Write-Host "[dc03_join] WARNING: could not identify internal (non-NAT) adapter"
    }
}

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

Write-Host "[dc03_join] Setting DNS to DC01 ($dc01IP) on natnetwork adapters..."
$netAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
foreach ($adapter in $netAdapters) {
    $ips = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ips.IPAddress -like "192.168.*") {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $dc01IP
        Write-Host "[dc03_join] DNS set on adapter: $($adapter.Name) (192.168.x)"
    } else {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses "127.0.0.1" -ErrorAction SilentlyContinue
        Set-DnsClient -InterfaceIndex $adapter.InterfaceIndex -RegisterThisConnectionsAddress $false
        Write-Host "[dc03_join] DNS set to 127.0.0.1 on adapter: $($adapter.Name) (NAT, no dyn reg)"
    }
}
Clear-DnsClientCache
Write-Host "[dc03_join] DNS cache flushed"

Write-Host "[dc03_join] Pinning secscope.corp to DC01 IP in hosts file..."
if (-not (Select-String -Path "$env:windir\System32\drivers\etc\hosts" `
        -Pattern "secscope.corp" -SimpleMatch -Quiet)) {
    Add-Content -Path "$env:windir\System32\drivers\etc\hosts" `
        -Value "$dc01IP secscope.corp dc01.secscope.corp dc01" -Force
    Write-Host "[dc03_join] Hosts file entry added"
} else {
    Write-Host "[dc03_join] Hosts file entry already exists"
}

Write-Host "[dc03_join] Verifying DNS resolution of secscope.corp..."
$dnsOk = $false
for ($i = 1; $i -le 6; $i++) {
    $result = nslookup "secscope.corp" $dc01IP 2>&1
    if ($result -match "Address" -and $result -match $dc01IP) {
        Write-Host "[dc03_join] secscope.corp resolved via nslookup"
        $dnsOk = $true
        break
    }
    Write-Host "[dc03_join] DNS resolution attempt $i/6, waiting..."
    Start-Sleep 3
}
if (-not $dnsOk) {
    Write-Host "[dc03_join] ERROR: Cannot resolve secscope.corp via DNS after 18s."
    exit 1
}

Write-Host "[dc03_join] Checking if subdomain already exists..."
try {
    $dcRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
    if ($dcRole -ge 4) {
        Write-Host "[dc03_join] Already a domain controller (role $dcRole), skipping promotion"
        exit 0
    }
} catch {}
$secPass = ConvertTo-SecureString $adminPass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("Administrator@$domain", $secPass)
try {
    $null = Get-ADDomain -Identity $childDomain -Server $dc01IP -Credential $cred -ErrorAction Stop
    Write-Host "[dc03_join] Subdomain $childDomain already exists in forest, skipping promotion"
    exit 0
} catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    Write-Host "[dc03_join] Child domain does not exist yet, proceeding with promotion"
} catch {
    Write-Host "[dc03_join] Child-domain existence check inconclusive ($_), proceeding with promotion"
}

Write-Host "[dc03_join] Installing AD-Domain-Services and DNS..."
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

Import-Module ADDSDeployment -ErrorAction SilentlyContinue
Import-Module ActiveDirectory -ErrorAction SilentlyContinue

Write-Host "[dc03_join] Resolving OU name conflict for child domain..."
try {
    $conflictingOU = Get-ADOrganizationalUnit -Identity "OU=IT,DC=secscope,DC=corp" -Server $dc01IP -Credential $cred -ErrorAction Stop
    if ($conflictingOU) {
        Write-Host "[dc03_join] Temporarily renaming OU=IT to avoid conflict..."
        Rename-ADObject -Identity $conflictingOU.DistinguishedName -NewName "IT_TEMP" -Server $dc01IP -Credential $cred -ErrorAction Stop
        Write-Host "[dc03_join] OU renamed to IT_TEMP"
    }
} catch { Write-Host "[dc03_join] No OU conflict found: $_" }

Write-Host "[dc03_join] Syncing clock with DC01 ($dc01IP)..."
try {
    w32tm /resync 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        w32tm /config /syncfromflags:manual /manualpeerlist:$dc01IP 2>&1 | Out-Null
        w32tm /resync 2>&1 | Out-Null
    }
    Write-Host "[dc03_join] Clock synced. Current time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
} catch {
    Write-Host "[dc03_join] WARNING: Time sync failed: $_"
}

Write-Host "[dc03_join] Creating subdomain $childDomain under $domain..."
$secPass = ConvertTo-SecureString $adminPass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("Administrator@$domain", $secPass)

# Build the child-domain DN from the parent DN so this stays correct if the
# domain name ever changes (e.g. DC=it,DC=secscope,DC=corp).
$parentDN = ($domain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
$childDN  = "DC=it,$parentDN"
$partitionsDN = "CN=Partitions,CN=Configuration,$parentDN"

function Remove-StaleChildDomain {
    param(
        [string]$ChildDN,
        [string]$PartitionsDN,
        [string]$ParentDomain,
        [string]$ChildDomain,
        [string]$Server,
        [pscredential]$Credential
    )

    # --- stale DC03 computer object in the parent domain ---
    try {
        $staleComputer = Get-ADComputer -Identity "DC03" -Server $Server -Credential $Credential -ErrorAction Stop
        if ($staleComputer) {
            Remove-ADObject -Identity $staleComputer.ObjectGUID -Server $Server -Credential $Credential -Recursive -Confirm:$false -ErrorAction Stop
            Write-Host "[dc03_join] Removed stale DC03 AD object and children"
            Start-Sleep -Seconds 5
        }
    } catch {
        Write-Host "[dc03_join] No stale DC03 computer object to clean"
    }

    # --- stale child-domain crossRef under CN=Partitions ---
    # nCName is a DN-syntax attribute; a string "-eq" filter does NOT reliably
    # match (it silently returns nothing), which is why earlier builds logged
    # "no stale crossRef" while the crossRef was actually present and blocked
    # promotion with "The specified domain already exists". Enumerate the
    # Partitions children and match nCName exactly instead.
    try {
        $crossRefs = Get-ADObject -SearchBase $PartitionsDN -SearchScope OneLevel `
            -LDAPFilter "(objectClass=crossRef)" -Properties nCName `
            -Server $Server -Credential $Credential -ErrorAction Stop |
            Where-Object { $_.nCName -eq $ChildDN }
        foreach ($cr in $crossRefs) {
            Remove-ADObject -Identity $cr.DistinguishedName -Server $Server -Credential $Credential -Recursive -Confirm:$false -ErrorAction Stop
            Write-Host "[dc03_join] Removed stale child-domain crossRef: $($cr.DistinguishedName)"
            Start-Sleep -Seconds 5
        }
        if (-not $crossRefs) { Write-Host "[dc03_join] No stale crossRef to clean" }
    } catch {
        Write-Host "[dc03_join] crossRef cleanup skipped: $_"
    }

    # --- stale DNS delegation (NS record) + conditional-forwarder zone on DC01 ---
    # A leftover 'it' NS delegation in the parent zone or an 'it.secscope.corp'
    # forwarder zone (created by dc01_dns/dc02_postboot) can also confuse the
    # uniqueness check. Clean them via a remote session to DC01.
    try {
        Invoke-Command -ComputerName $Server -Credential $Credential -ScriptBlock {
            param($Dom, $Child)
            Import-Module DnsServer -ErrorAction SilentlyContinue
            # Remove the child NS delegation from the parent zone.
            Get-DnsServerResourceRecord -ZoneName $Dom -Name "it" -RRType NS -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-DnsServerResourceRecord -ZoneName $Dom -InputObject $_ -Force -ErrorAction SilentlyContinue
            }
            # Remove a stale conditional-forwarder zone for the child domain.
            $fwd = Get-DnsServerZone -Name $Child -ErrorAction SilentlyContinue
            if ($fwd -and $fwd.ZoneType -eq "Forwarder") {
                Remove-DnsServerZone -Name $Child -Force -ErrorAction SilentlyContinue
            }
        } -ArgumentList $ParentDomain, $ChildDomain -ErrorAction Stop 2>&1 | Out-Null
    } catch {
        Write-Host "[dc03_join] Remote DNS delegation/forwarder cleanup skipped: $_"
    }
}

Write-Host "[dc03_join] Installing subdomain (retry up to 5 times)..."
$dsrmSec = ConvertTo-SecureString $adminPass -AsPlainText -Force
$promoted = $false
$retryDelays = @(10, 20, 30, 40, 60)
for ($i = 1; $i -le 5; $i++) {
    Write-Host "[dc03_join] Attempt $i/5..."
    # Clean any stale child-domain metadata BEFORE every attempt: a half-created
    # partition from a failed attempt (or a surviving DC01 from a destroyed DC03)
    # would otherwise wedge all subsequent attempts.
    Write-Host "[dc03_join] Pre-attempt cleanup of stale child-domain metadata..."
    Remove-StaleChildDomain -ChildDN $childDN -PartitionsDN $partitionsDN -ParentDomain $domain -ChildDomain $childDomain -Server $dc01IP -Credential $cred
    try {
        Install-ADDSDomain -NewDomainName "it" -ParentDomainName $domain -DomainType ChildDomain -NewDomainNetbiosName "ITSEC" -ReplicationSourceDC "dc01.$domain" -Credential $cred -SafeModeAdministratorPassword $dsrmSec -SkipPreChecks -Force -NoRebootOnCompletion:$true -ErrorAction Stop
        $promoted = $true
        Write-Host "[dc03_join] Subdomain install succeeded"
        Write-Host "[dc03_join] OU IT renamed to IT_TEMP for child domain compatibility."
        Write-Host "[dc03_join] Post-promotion steps (password, ADWS, DNS) will run via dc03_postboot.ps1."
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

Write-Host "[dc03_join] Subdomain install completed. Reboot required."
Write-Host "[dc03_join] Post-promotion steps (ADWS, DNS, password) will run via dc03_postboot.ps1."
