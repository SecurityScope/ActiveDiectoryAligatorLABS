$ErrorActionPreference = "Continue"

Write-Host "[dc01_child_dns] Configuring parent-side DNS for child domain..."

$domain      = $env:DOMAIN
$childDomain = $env:CHILD_DOMAIN
$dc03IP      = $env:DC03_IP

# This runs on DC01 AFTER DC03 has promoted the child domain. It is the
# equivalent of GOAD's parent_child_dns role: the parent DC publishes a DNS
# delegation to the child zone plus a conditional forwarder to the child DC so
# name resolution flows both ways. Creating these BEFORE promotion is what makes
# Install-ADDSDomain abort with "The specified domain already exists", so it is
# deliberately deferred to this step.

Import-Module DnsServer -ErrorAction SilentlyContinue

$childLabel = $childDomain.Split('.')[0]
$childNameServer = "dc03.$childDomain"

Write-Host "[dc01_child_dns] Adding DNS delegation: $childLabel.$domain -> $childNameServer ($dc03IP)..."
$existingDelegation = $false
try {
    $del = Get-DnsServerZoneDelegation -Name $domain -ErrorAction SilentlyContinue | Where-Object { $_.ChildZoneName -eq $childLabel -or $_.ChildZoneName -eq "$childLabel.$domain." }
    if ($del) { $existingDelegation = $true }
} catch {}

if ($existingDelegation) {
    Write-Host "[dc01_child_dns] Delegation for $childLabel already present, skipping"
} else {
    for ($i = 1; $i -le 5; $i++) {
        try {
            Add-DnsServerZoneDelegation -Name $domain -ChildZoneName $childLabel -NameServer $childNameServer -IPAddress $dc03IP -ErrorAction Stop
            Write-Host "[dc01_child_dns] Delegation created"
            break
        } catch {
            Write-Host "[dc01_child_dns] Delegation attempt $i/5 failed: $_"
            Start-Sleep -Seconds 10
        }
    }
}

Write-Host "[dc01_child_dns] Adding conditional forwarder: $childDomain -> $dc03IP..."
$existingFwd = Get-DnsServerZone -Name $childDomain -ErrorAction SilentlyContinue
if ($existingFwd -and $existingFwd.ZoneType -eq "Forwarder") {
    Write-Host "[dc01_child_dns] Conditional forwarder already present, skipping"
} else {
    try {
        Add-DnsServerConditionalForwarderZone -Name $childDomain -MasterServers $dc03IP -ErrorAction Stop
        Write-Host "[dc01_child_dns] Conditional forwarder created"
    } catch {
        Write-Host "[dc01_child_dns] Conditional forwarder create skipped: $_"
    }
}

# The dc01_dns.ps1 inventory A record for dc03 lives in the parent zone. A
# rebuild's pre-promotion cleanup can remove it; re-add it so the lab inventory
# name dc03.secscope.corp resolves to the child DC (its own FQDN is
# dc03.it.secscope.corp and lives in the child zone).
Write-Host "[dc01_child_dns] Ensuring parent-zone dc03 A record..."
try {
    $existingA = Get-DnsServerResourceRecord -ZoneName $domain -Name "dc03" -RRType A -ErrorAction SilentlyContinue
    if (-not $existingA) {
        Add-DnsServerResourceRecordA -Name "dc03" -ZoneName $domain -IPv4Address $dc03IP -ErrorAction Stop
        Write-Host "[dc01_child_dns] Added dc03.$domain -> $dc03IP"
    } else {
        Write-Host "[dc01_child_dns] dc03.$domain A record already present"
    }
} catch {
    Write-Host "[dc01_child_dns] Could not add dc03 A record: $_"
}

Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
Write-Host "[dc01_child_dns] Parent-side child DNS configuration complete"
