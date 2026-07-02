$ErrorActionPreference = "Continue"

Write-Host "[dc03_join] Starting subdomain promotion..."

$domain      = $env:DOMAIN
$childDomain = $env:CHILD_DOMAIN
$adminPass   = $env:ADMIN_PASS
$dc01IP      = $env:DC01_IP

Write-Host "[dc03_join] Waiting for DC01 to be reachable..."
$reachable = $false
for ($i = 1; $i -le 20; $i++) {
    if (Test-Connection $dc01IP -Count 1 -Quiet) {
        $reachable = $true
        Write-Host "[dc03_join] DC01 reachable"
        break
    }
    Write-Host "[dc03_join] Attempt $i/20, waiting..."
    Start-Sleep 15
}
if (-not $reachable) {
    Write-Host "[dc03_join] ERROR: DC01 not reachable after 20 attempts"
    exit 1
}

Write-Host "[dc03_join] Setting DNS to DC01 ($dc01IP) on all adapters..."
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
foreach ($adapter in $adapters) {
    Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex `
        -ServerAddresses $dc01IP
    Write-Host "[dc03_join] DNS set on adapter: $($adapter.Name)"
}
Clear-DnsClientCache
Write-Host "[dc03_join] DNS cache flushed"

Write-Host "[dc03_join] Verifying DNS resolution of secscope.corp..."
$dnsOk = $false
for ($i = 1; $i -le 12; $i++) {
    try {
        $resolved = Resolve-DnsName "secscope.corp" -ErrorAction Stop
        Write-Host "[dc03_join] secscope.corp resolved to: $($resolved.IPAddress)"
        $dnsOk = $true
        break
    } catch {
        Write-Host "[dc03_join] DNS resolution attempt $i/12, waiting..."
        Start-Sleep 10
    }
}
if (-not $dnsOk) {
    Write-Host "[dc03_join] ERROR: Cannot resolve secscope.corp. Check DC01 is running and reachable."
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
    net time \\$dc01IP /set /y 2>&1 | Out-Null
    $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[dc03_join] Clock synced. Current time: $currentTime"
} catch {
    Write-Host "[dc03_join] WARNING: Time sync failed: $_"
    Write-Host "[dc03_join] Current time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "[dc03_join] AD requires clocks within 5 minutes of each other."
}

Write-Host "[dc03_join] Installing AD-Domain-Services and DNS..."
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

Write-Host "[dc03_join] Creating subdomain $childDomain under $domain..."
try {
    $dcRole = (Get-WmiObject Win32_ComputerSystem).DomainRole
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
$dsrmSec = ConvertTo-SecureString $adminPass -AsPlainText -Force

$credFormats = @(
    "Administrator@$domain",
    "$env:DOMAIN_UPPER\Administrator",
    "Administrator"
)

Write-Host "[dc03_join] Current system time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "[dc03_join] Installing subdomain (retry up to 20 times)..."
$promoted = $false
for ($i = 1; $i -le 20; $i++) {
    foreach ($credFormat in $credFormats) {
        Write-Host "[dc03_join] Attempt $i/20 -- credential: $credFormat"
        $cred = New-Object System.Management.Automation.PSCredential($credFormat, $secPass)
        try {
            Install-ADDSDomain `
                -NewDomainName "it" `
                -ParentDomainName $domain `
                -DomainType ChildDomain `
                -Credential $cred `
                -SafeModeAdministratorPassword $dsrmSec `
                -SkipPreChecks:$true `
                -Force `
                -NoRebootOnCompletion:$true `
                -ErrorAction Stop
            $promoted = $true
            Write-Host "[dc03_join] Subdomain install succeeded with credential: $credFormat"
            Write-Host "[dc03_join] Setting Administrator password..."
            net user Administrator $adminPass 2>&1 | Out-Null
            Write-Host "[dc03_join] Administrator password set"
            break
        } catch {
            Write-Host "[dc03_join] Failed with $credFormat`: $_"
            Start-Sleep -Seconds 15
        }
    }
    if ($promoted) { break }
    Write-Host "[dc03_join] All credential formats failed on attempt $i/20, waiting..."
    Start-Sleep -Seconds 30
}
if (-not $promoted) {
    Write-Host "[dc03_join] ERROR: Failed to install subdomain after 20 attempts"
    exit 1
}

Write-Host "[dc03_join] Subdomain install completed successfully. Reboot required (vagrant reload dc03)."
