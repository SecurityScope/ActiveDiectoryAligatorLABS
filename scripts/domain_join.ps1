$ErrorActionPreference = "Continue"

$domain     = $env:DOMAIN
$adminPass  = $env:ADMIN_PASS
$dc01IP     = $env:DC01_IP
$vmIP       = $env:VM_IP
$vmName     = $env:VM_NAME
$logPrefix  = $env:LOG_PREFIX

Write-Host "[$logPrefix] Starting $vmName join setup..."

Write-Host "[$logPrefix] Setting static IP $vmIP..."
# sysprep /generalize (used to give members a unique machine SID) leaves the
# second virtual NIC in a CM_PROB_DISABLED state. When that happens the internal
# natnetwork adapter shows as "Not Present"/disabled after reboot, so the static
# IP never applies and the domain is unreachable. Re-enable any disabled net
# device before we look for the internal adapter.
$disabledNet = Get-PnpDevice -Class Net -Status Error -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*Ethernet*" -or $_.FriendlyName -like "*Intel*" -or $_.FriendlyName -like "*PRO/1000*" }
foreach ($d in $disabledNet) {
    Write-Host "[$logPrefix] Re-enabling disabled network device: $($d.FriendlyName)"
    Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
}
if ($disabledNet) { Start-Sleep 8 }

$adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
$mgmtNic  = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1).InterfaceIndex
$nic2     = $adapters | Where-Object { $_.InterfaceIndex -ne $mgmtNic } | Select-Object -First 1

if ($nic2) {
    $ifIndex = $nic2.InterfaceIndex
    $nic2Name = $nic2.Name
    Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    netsh interface ip set address name="$nic2Name" static $vmIP 255.255.255.0 192.168.200.1
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dc01IP
    Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Disabled -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $ifIndex -InterfaceMetric 10 -ErrorAction SilentlyContinue
    # Keep the NAT (10.0.2.x) adapter from registering its address in AD DNS so
    # a member never publishes a stale "<host> -> 10.0.2.15" A record.
    $otherNics = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceIndex -ne $ifIndex }
    foreach ($o in $otherNics) {
        Set-NetIPInterface -InterfaceIndex $o.InterfaceIndex -InterfaceMetric 200 -ErrorAction SilentlyContinue
        Set-DnsClient -InterfaceIndex $o.InterfaceIndex -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue
        $guid = (Get-NetAdapter -InterfaceIndex $o.InterfaceIndex).InterfaceGuid
        $ifKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
        if (Test-Path $ifKey) {
            Set-ItemProperty -Path $ifKey -Name RegistrationEnabled -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $ifKey -Name DisableDynamicUpdate -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "[$logPrefix] Static IP set, DNS pointing to $dc01IP"
} else {
    Write-Host "[$logPrefix] WARNING: Could not find secondary adapter"
    $idx = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).InterfaceIndex
    $idxName = (Get-NetAdapter -InterfaceIndex $idx).Name
    netsh interface ip set address name="$idxName" static $vmIP 255.255.255.0 192.168.200.1
    Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dc01IP
    Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled -ErrorAction SilentlyContinue
    $ifIndex = $idx
}

Write-Host "[$logPrefix] Waiting for DC01 to be reachable..."
$reachable = $false
for ($i = 1; $i -le 10; $i++) {
    if (Test-Connection $dc01IP -Count 1 -Quiet) {
        $reachable = $true
        Write-Host "[$logPrefix] DC01 reachable"
        break
    }
    Write-Host "[$logPrefix] Attempt $i/10, waiting..."
    Start-Sleep 5
}
if (-not $reachable) {
    Write-Host "[$logPrefix] ERROR: DC01 not reachable after 50s"
    exit 1
}

Write-Host "[$logPrefix] Syncing clock with DC01 ($dc01IP)..."
try {
    net time \\$dc01IP /set /y 2>&1 | Out-Null
    $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$logPrefix] Clock synced. Current time: $currentTime"
} catch {
    Write-Host "[$logPrefix] WARNING: Time sync failed: $_"
    Write-Host "[$logPrefix] AD requires clocks within 5 minutes of each other."
}

Write-Host "[$logPrefix] Setting DNS to DC01 on internal adapter..."
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dc01IP
Clear-DnsClientCache

Write-Host "[$logPrefix] Verifying DNS resolution of $domain..."
# Use nslookup against DC01 directly, NOT Resolve-DnsName: with the NAT adapter's
# --natdnshostresolver1 on, Resolve-DnsName round-robins and caches a false
# NXDOMAIN from the host resolver (ISSUE_REPORT Issue 1), which aborts the join
# even though the DC answers fine. nslookup queries the specified server only.
$dnsOk = $false
for ($i = 1; $i -le 6; $i++) {
    $srv = nslookup -type=SRV "_ldap._tcp.$domain" $dc01IP 2>&1
    if ($srv -match "$([regex]::Escape($domain))") {
        Write-Host "[$logPrefix] $domain SRV records resolved via nslookup"
        $dnsOk = $true
        break
    }
    Write-Host "[$logPrefix] DNS attempt $i/6..."
    Start-Sleep 3
}
if (-not $dnsOk) {
    Write-Host "[$logPrefix] ERROR: Cannot resolve $domain (SRV) via $dc01IP"
    exit 1
}

Write-Host "[$logPrefix] Joining domain $domain..."
$password = ConvertTo-SecureString $adminPass -AsPlainText -Force
$cred = New-Object PSCredential("Administrator@$domain", $password)

# Resolve a target OU so this machine lands where its GPOs/ACLs expect it
# (e.g. workstations in OU=Workstations,OU=IT so the LAPS GPO + read ACL apply).
# VM_OU is a relative path (e.g. "OU=Workstations,OU=IT"); append the domain DN.
# If the child-domain build left OU=IT temporarily renamed to IT_TEMP, fall back
# to that; if neither resolves, omit -OUPath (default CN=Computers container).
$ouPath = $null
if ($env:VM_OU) {
    $domainDN = ($domain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
    $candidates = @("$($env:VM_OU),$domainDN", "$($env:VM_OU -replace 'OU=IT','OU=IT_TEMP'),$domainDN")
    foreach ($cand in $candidates) {
        try {
            $null = Get-ADObject -Identity $cand -Server $dc01IP -Credential $cred -ErrorAction Stop
            $ouPath = $cand
            Write-Host "[$logPrefix] Target OU resolved: $ouPath"
            break
        } catch { }
    }
    if (-not $ouPath) {
        Write-Host "[$logPrefix] WARNING: VM_OU '$($env:VM_OU)' not found; joining into default Computers container"
    }
}

$joined = $false
for ($i = 1; $i -le 5; $i++) {
    Write-Host "[$logPrefix] Attempt $i/5..."
    try {
        $addParams = @{
            DomainName = $domain
            Credential = $cred
            Force      = $true
            ErrorAction = "Stop"
        }
        if ($ouPath) {
            $addParams["OUPath"] = $ouPath
        }
        if ($env:COMPUTERNAME -ne $vmName) {
            $addParams["NewName"] = $vmName
        }
        Add-Computer @addParams
        Write-Host "[$logPrefix] Joined domain"
        $joined = $true
        break
    } catch {
        if ($_.Exception.Message -match "already exists") {
            Remove-ADComputer -Identity $vmName -Credential $cred -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "[$logPrefix] Removed stale AD object, retrying..."
        }
        Write-Host "[$logPrefix] Attempt $i/5 failed: $_"
        Start-Sleep 5
    }
}

if (-not $joined) {
    Write-Host "[$logPrefix] ERROR: Domain join failed after 5 attempts"
    exit 1
}

# Add-Computer's -NewName has been observed to join the domain successfully
# while silently not staging the rename (no pending ComputerName in the
# registry, even though HasSucceeded would report true). Verify the rename
# actually staged and fall back to an explicit Rename-Computer if not -
# this is required, not optional, before the "join-reload" reboot.
$pendingName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue).ComputerName
if ($pendingName -ne $vmName) {
    Write-Host "[$logPrefix] Rename did not stage during join (pending name: $pendingName) - retrying via Rename-Computer..."
    try {
        Rename-Computer -NewName $vmName -DomainCredential $cred -Force -ErrorAction Stop
        Write-Host "[$logPrefix] Rename-Computer succeeded"
    } catch {
        Write-Host "[$logPrefix] ERROR: Rename-Computer failed: $_"
        exit 1
    }
} else {
    Write-Host "[$logPrefix] Rename to $vmName staged correctly"
}

Write-Host "[$logPrefix] Done. Vagrant reload provisioner will reboot to complete domain join."
