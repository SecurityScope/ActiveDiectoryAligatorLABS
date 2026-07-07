$ErrorActionPreference = "Continue"

$domain     = $env:DOMAIN
$adminPass  = $env:ADMIN_PASS
$dc01IP     = $env:DC01_IP
$vmIP       = $env:VM_IP
$vmName     = $env:VM_NAME
$logPrefix  = $env:LOG_PREFIX

Write-Host "[$logPrefix] Starting $vmName join setup..."

Write-Host "[$logPrefix] Setting static IP $vmIP..."
$adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
$mgmtNic  = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1).InterfaceIndex
$nic2     = $adapters | Where-Object { $_.InterfaceIndex -ne $mgmtNic } | Select-Object -First 1

if ($nic2) {
    $ifIndex = $nic2.InterfaceIndex
    Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $vmIP -PrefixLength 24 -DefaultGateway 192.168.200.1 -AddressFamily IPv4 -PolicyStore PersistentStore
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dc01IP
    Write-Host "[$logPrefix] Static IP set, DNS pointing to $dc01IP"
} else {
    Write-Host "[$logPrefix] WARNING: Could not find secondary adapter"
    $idx = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).InterfaceIndex
    New-NetIPAddress -InterfaceIndex $idx -IPAddress $vmIP -PrefixLength 24 -DefaultGateway 192.168.200.1 -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dc01IP
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
$dnsOk = $false
for ($i = 1; $i -le 6; $i++) {
    try {
        $resolved = Resolve-DnsName $domain -ErrorAction Stop
        Write-Host "[$logPrefix] $domain resolved OK"
        $dnsOk = $true
        break
    } catch {
        Write-Host "[$logPrefix] DNS attempt $i/6..."
        Start-Sleep 3
    }
}
if (-not $dnsOk) {
    Write-Host "[$logPrefix] ERROR: Cannot resolve $domain"
    exit 1
}

Write-Host "[$logPrefix] Joining domain $domain..."
$password = ConvertTo-SecureString $adminPass -AsPlainText -Force
$cred = New-Object PSCredential("Administrator@$domain", $password)

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
