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
    # No default gateway on the internal adapter: it must not outrank the NAT
    # adapter's default route, which carries WinRM during this provisioner.
    netsh interface ip set address name="$nic2Name" static $vmIP 255.255.255.0
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dc01IP
    Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Disabled -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $ifIndex -InterfaceMetric 10 -ErrorAction SilentlyContinue
    # Keep the NAT (10.0.2.x) adapter from registering its address in AD DNS so
    # a member never publishes a stale "<host> -> 10.0.2.15" A record.
    $otherNics = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceIndex -ne $ifIndex }
    foreach ($o in $otherNics) {
        Set-NetIPInterface -InterfaceIndex $o.InterfaceIndex -InterfaceMetric 200 -ErrorAction SilentlyContinue
        # Point the NAT adapter's DNS at DC01 too. Leaving it on the VirtualBox
        # host-resolver (--natdnshostresolver1 on) means the DC Locator
        # (DsGetDcName) round-robins onto it and gets NXDOMAIN for the _msdcs SRV
        # records, so the domain join fails "the specified domain could not be
        # contacted" even though nslookup to DC01 works. DC01 forwards to 8.8.8.8
        # so internet name resolution still works through it.
        Set-DnsClientServerAddress -InterfaceIndex $o.InterfaceIndex -ServerAddresses $dc01IP -ErrorAction SilentlyContinue
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
    netsh interface ip set address name="$idxName" static $vmIP 255.255.255.0
    Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dc01IP
    Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled -ErrorAction SilentlyContinue
    $ifIndex = $idx
}

Write-Host "[$logPrefix] Waiting for DC01 to be reachable..."
# Test an actual TCP port (SMB/445), NOT ICMP: VirtualBox NAT networks don't
# reliably pass ping, so Test-Connection throws 'Generic failure' even when the
# DC is fully reachable over TCP. 445 is what the join needs anyway.
$reachable = $false
for ($i = 1; $i -le 12; $i++) {
    try {
        $t = New-Object System.Net.Sockets.TcpClient
        $iar = $t.BeginConnect($dc01IP, 445, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(3000) -and $t.Connected) {
            $reachable = $true; $t.Close()
            Write-Host "[$logPrefix] DC01 reachable (TCP 445)"
            break
        }
        $t.Close()
    } catch { }
    Write-Host "[$logPrefix] Attempt $i/12, waiting..."
    Start-Sleep 5
}
if (-not $reachable) {
    Write-Host "[$logPrefix] ERROR: DC01 not reachable on TCP 445 after 60s"
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

# nslookup proves DNS resolves, but Add-Computer uses the DC LOCATOR
# (DsGetDcName), which queries the DNS client across all adapters. Confirm the
# locator itself can find a DC (and warm its cache) before joining - this is
# what actually fails with "the specified domain could not be contacted".
Write-Host "[$logPrefix] Verifying DC Locator can find a DC for $domain..."
$dcOk = $false
for ($i = 1; $i -le 10; $i++) {
    Clear-DnsClientCache
    $dc = nltest "/dsgetdc:$domain" 2>&1
    if ($dc -match "DC:\s*\\\\" -and $dc -notmatch "ERROR") {
        Write-Host "[$logPrefix] DC Locator OK: $(( $dc | Select-String 'DC:' | Select-Object -First 1).ToString().Trim())"
        $dcOk = $true
        break
    }
    Write-Host "[$logPrefix] DC Locator attempt $i/10 (not found yet)..."
    Start-Sleep 5
}
if (-not $dcOk) {
    Write-Host "[$logPrefix] WARNING: DC Locator could not confirm a DC; attempting join anyway"
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
    # Candidates: the literal VM_OU, and (for IT) the IT_TEMP variant the child
    # domain forces. Verify via ADSI/DirectoryEntry, NOT Get-ADObject - members
    # don't have the ActiveDirectory module at join time (RSAT installs later),
    # so a Get-ADObject check always threw and we fell back to CN=Computers,
    # breaking OU placement (and with it the LAPS GPO/ACL on the Workstations OU).
    $candidates = @("$($env:VM_OU),$domainDN", "$($env:VM_OU -replace 'OU=IT','OU=IT_TEMP'),$domainDN")
    foreach ($cand in $candidates) {
        try {
            $de = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$dc01IP/$cand", "Administrator@$domain", $adminPass)
            # RefreshCache() forces a real server bind and THROWS if the OU does
            # not exist. (.Guid does NOT reliably validate - it can return a GUID
            # from the ADsPath without contacting the server, so it false-matched
            # a non-existent OU=IT and Add-Computer -OUPath then failed "the system
            # cannot find the file specified".)
            $de.RefreshCache()
            if ($de.Properties["distinguishedName"].Value) {
                $ouPath = $cand
                Write-Host "[$logPrefix] Target OU resolved: $ouPath"
                break
            }
        } catch { }
    }
    if (-not $ouPath) {
        Write-Host "[$logPrefix] WARNING: VM_OU '$($env:VM_OU)' not found; joining into default Computers container"
    }
}

# Is the machine already in the target domain? A previous attempt may have joined
# it (as VAGRANT-BUILD) but failed the rename, leaving it joined-but-misnamed - or
# this is an idempotent re-run. In that case DON'T call Add-Computer again (it
# fails "already in that domain"); go straight to the rename step.
$cs = Get-CimInstance Win32_ComputerSystem
$alreadyJoined = $cs.PartOfDomain -and ($cs.Domain -eq $domain)

if ($alreadyJoined) {
    Write-Host "[$logPrefix] Already joined to $domain (computer name '$($env:COMPUTERNAME)'); ensuring rename only"
} else {
    # Join WITHOUT -NewName. Combining join + rename in one Add-Computer call is
    # what hit 'The directory service is busy' DURING the rename and left the box
    # joined as VAGRANT-BUILD with no $vmName computer object. Join first; rename
    # as a separate, retryable step below.
    $joined = $false
    for ($i = 1; $i -le 5; $i++) {
        Write-Host "[$logPrefix] Join attempt $i/5..."
        try {
            $addParams = @{
                DomainName  = $domain
                Credential  = $cred
                Force       = $true
                ErrorAction = "Stop"
            }
            if ($ouPath) { $addParams["OUPath"] = $ouPath }
            Add-Computer @addParams
            Write-Host "[$logPrefix] Joined domain"
            $joined = $true
            break
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match "already in that domain|already a member of") {
                Write-Host "[$logPrefix] Already a member (joined on a prior attempt); proceeding to rename"
                $joined = $true
                break
            }
            if ($msg -match "already exists") {
                Remove-ADComputer -Identity $vmName -Credential $cred -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "[$logPrefix] Removed stale AD object, retrying..."
            }
            # "The system cannot find the file specified" here almost always means
            # the -OUPath OU doesn't exist. Drop OUPath and fall back to the default
            # Computers container rather than failing the whole build.
            if ($ouPath -and $msg -match "cannot find the file specified") {
                Write-Host "[$logPrefix] OUPath '$ouPath' rejected; falling back to default container"
                $ouPath = $null
            }
            Write-Host "[$logPrefix] Join attempt $i/5 failed: $msg"
            Start-Sleep 5
        }
    }
    if (-not $joined) {
        Write-Host "[$logPrefix] ERROR: Domain join failed after 5 attempts"
        exit 1
    }
}

# Ensure the computer is named $vmName. SEPARATE, RETRYABLE step: the rename
# contacts AD and can transiently fail with 'The directory service is busy' -
# which is exactly what left the earlier build joined as VAGRANT-BUILD. Skip if
# the name is already correct or a rename is already staged (pending reboot).
$pendingName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue).ComputerName
if ($env:COMPUTERNAME -eq $vmName -or $pendingName -eq $vmName) {
    Write-Host "[$logPrefix] Computer name already '$vmName' (or rename staged)"
} else {
    $renamed = $false
    for ($r = 1; $r -le 6; $r++) {
        try {
            Rename-Computer -NewName $vmName -DomainCredential $cred -Force -ErrorAction Stop
            Write-Host "[$logPrefix] Rename to '$vmName' succeeded (attempt $r)"
            $renamed = $true
            break
        } catch {
            if ($_.Exception.Message -match "already exists") {
                Remove-ADComputer -Identity $vmName -Credential $cred -Confirm:$false -ErrorAction SilentlyContinue
            }
            Write-Host "[$logPrefix] Rename attempt $r/6 failed (e.g. 'directory service is busy'): $_"
            Start-Sleep 10
        }
    }
    if (-not $renamed) {
        Write-Host "[$logPrefix] ERROR: could not rename computer to '$vmName' after 6 attempts"
        exit 1
    }
}

Write-Host "[$logPrefix] Done. Vagrant reload provisioner will reboot to complete domain join."
