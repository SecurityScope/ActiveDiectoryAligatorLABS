# Active Directory Alligator Labs — Windows Setup Script
# Run from the ActiveDirectoryAlligatorLABS directory:
# powershell -ExecutionPolicy Bypass -File setup.ps1

param(
    [switch]$Help,
    [switch]$Destroy,
    [switch]$Build,
    [switch]$DC01Only,
    [switch]$NoMisconfig,
    [switch]$Status
)

$ErrorActionPreference = "Continue"

# ── Start time and tracking arrays ─────────────────────

$StartTime = Get-Date
$ExecutedSteps = @()
$SkippedSteps = @()

# ── Check functions ────────────────────────────────────

function Check-DC01-Base {
    $status = vagrant status dc01 2>&1
    return ($status -match "running")
}

function Check-DC01-Postboot {
    $result = vagrant winrm dc01 -c "Get-ADDomain" 2>&1
    return ($result -match "secscope")
}

function Check-DC01-DNS {
    $result = vagrant winrm dc01 -c "Get-DnsServerZone secscope.corp" 2>&1
    return ($result -match "secscope")
}

function Check-DC01-ObjectsBase {
    $result = vagrant winrm dc01 -c "Get-ADUser anakin" 2>&1
    return ($result -match "anakin")
}

function Check-DC01-Objects {
    $result = vagrant winrm dc01 -c `
        "Get-ADComputer WS01 -Properties msDS-AllowedToActOnBehalfOfOtherIdentity" 2>&1
    return ($result -match "WS01")
}

function Check-DC02-Base {
    $status = vagrant status dc02 2>&1
    return ($status -match "running")
}

function Check-DC02-Join {
    $result = vagrant winrm dc02 -c "Get-ADDomainController" 2>&1
    return ($result -match "DC02")
}

function Check-DC03-Base {
    $status = vagrant status dc03 2>&1
    return ($status -match "running")
}

function Check-DC03-Join {
    $result = vagrant winrm dc03 -c "Get-ADDomain" 2>&1
    return ($result -match "it")
}

function Check-SRV01-Base {
    $status = vagrant status srv01 2>&1
    return ($status -match "running")
}

function Check-WS01-Base {
    $status = vagrant status ws01 2>&1
    return ($status -match "running")
}

function Check-WS02-Base {
    $status = vagrant status ws02 2>&1
    return ($status -match "running")
}

function Check-LIN01-Base {
    $status = vagrant status lin01 2>&1
    return ($status -match "running")
}

function Check-SRV01-Services {
    $result = vagrant winrm srv01 -c "Get-WindowsFeature Web-Server" 2>&1
    return ($result -match "Installed")
}

function Check-WS01-Misconfig {
    $result = vagrant winrm ws01 -c "Get-LocalUser localadmin" 2>&1
    return ($result -match "localadmin")
}

function Check-WS02-Misconfig {
    $result = vagrant winrm ws02 -c "Get-LocalUser localadmin" 2>&1
    return ($result -match "localadmin")
}

function Check-Hardened {
    $result = vagrant winrm dc01 -c "Get-LocalUser vagrant | Select-Object Enabled" 2>&1
    return ($result -match "False")
}

# ── Help / Status functions ────────────────────────────

function Show-Help {
    Write-Host "╔══════════════════════════════════════════╗"
    Write-Host "║  Active Directory Alligator Labs — Setup ║"
    Write-Host "╚══════════════════════════════════════════╝"
    Write-Host ""
    Write-Host "USAGE:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File setup.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "OPTIONS:"
    Write-Host "  -Help           Show this help message"
    Write-Host "  -Build          Run full lab build (resumes if interrupted)"
    Write-Host "  -Destroy        Destroy all VMs and exit (does NOT rebuild)"
    Write-Host "  -DC01Only       Build DC01 only"
    Write-Host "  -NoMisconfig    Skip misconfigurations step"
    Write-Host "  -Status         Show current state of all VMs"
    Write-Host ""
    Write-Host "EXAMPLES:"
    Write-Host "  .\setup.ps1                     Full build (resumes if interrupted)"
    Write-Host "  .\setup.ps1 -Build              Same as above"
    Write-Host "  .\setup.ps1 -Destroy            Destroy all VMs and exit"
    Write-Host "  .\setup.ps1 -Status             Check VM states"
    Write-Host "  .\setup.ps1 -DC01Only           Build DC01 only"
    Write-Host ""
    Write-Host "VM INVENTORY:"
    Write-Host "  DC01   192.168.200.10   Primary Domain Controller"
    Write-Host "  DC02   192.168.200.11   Secondary Domain Controller"
    Write-Host "  DC03   192.168.200.12   Subdomain Controller (it.secscope.corp)"
    Write-Host "  SRV01  192.168.200.20   MSSQL + IIS + ADCS"
    Write-Host "  WS01   192.168.200.30   Workstation 1"
    Write-Host "  WS02   192.168.200.31   Workstation 2"
    Write-Host "  LIN01  192.168.200.40   Linux Domain Member"
    Write-Host ""
    Write-Host "CREDENTIALS:"
    Write-Host "  Domain Admin:  SECSCOPE\Administrator / SecScope2024!"
    Write-Host "  Vagrant:       vagrant / vagrant (all VMs)"
    Write-Host ""
    Write-Host "TOTAL BUILD TIME: approximately 90-120 minutes"
}

function Show-Status {
    Write-Host "╔══════════════════════════════════════════╗"
    Write-Host "║       AD Alligator Labs VM Status        ║"
    Write-Host "╚══════════════════════════════════════════╝"
    foreach ($vm in @("dc01","dc02","dc03","srv01","ws01","ws02","lin01")) {
        $status = vagrant status $vm 2>&1 |
            Where-Object { $_ -match $vm } |
            ForEach-Object { ($_ -split "\s+")[1] }
        Write-Host ("  {0,-8} {1}" -f $vm, $status)
    }
}

# ── Early exits ────────────────────────────────────────

if ($Help) { Show-Help; exit 0 }
if ($Status) { Show-Status; exit 0 }

if ($Destroy) {
    Write-Host "[!] Destroying all VMs..."
    vagrant destroy -f
    Write-Host "[OK] All VMs destroyed."
    exit 0
}

# ── Banner ─────────────────────────────────────────────

Write-Host "╔══════════════════════════════════════════╗"
Write-Host "║  Active Directory Alligator Labs — Setup ║"
Write-Host "╚══════════════════════════════════════════╝"

# ── Pre-flight checks ─────────────────────────────────

Write-Host "`n[0] Checking requirements..."
if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: vagrant not found in PATH. Install Vagrant first."
    exit 1
}
if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) {
    $vboxPath = "C:\Program Files\Oracle\VirtualBox"
    if (Test-Path "$vboxPath\VBoxManage.exe") {
        $env:Path = "$vboxPath;$env:Path"
    } else {
        Write-Host "ERROR: VBoxManage not found in PATH. Install VirtualBox first."
        exit 1
    }
}
Write-Host "    vagrant and VBoxManage found"

# ── Step 1 — DC01 base ─────────────────────────────────

Write-Host "`n[1/16] DC01 base setup..."
if (Check-DC01-Base) {
    Write-Host "    [OK] DC01 already running - skipping"
    $SkippedSteps += "DC01 base"
} else {
    vagrant up dc01
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: vagrant up dc01 failed"; exit 1 }
    $ExecutedSteps += "DC01 base"
}

# ── Step 2 — DC01 postboot ─────────────────────────────

Write-Host "`n[2/16] DC01 AD promotion..."
Write-Host "    (WinRM error at end is NORMAL - ignore it)"
if (Check-DC01-Postboot) {
    Write-Host "    [OK] DC01 already a DC - skipping postboot"
    $SkippedSteps += "DC01 postboot"
} else {
    $output = vagrant provision dc01 --provision-with postboot 2>&1
    $filtered = $output | Where-Object {
        $_ -notmatch "WinRMAuthorizationError" -and
        $_ -notmatch "WinRMHTTPTransportError" -and
        $_ -notmatch "raise_if_auth_error" -and
        $_ -notmatch "response_handler.rb" -and
        $_ -notmatch "transport.rb" -and
        $_ -notmatch "power_shell.rb" -and
        $_ -notmatch "elevated.rb" -and
        $_ -notmatch "communicator.rb" -and
        $_ -notmatch "provisioner.rb" -and
        $_ -notmatch "from /home" -and
        $_ -notmatch "AuthenticationFailed" -and
        $_ -notmatch "wsman"
    }
    $filtered | Write-Host
    Write-Host "    Waiting 120s for AD to initialize..."
    Start-Sleep -Seconds 120
    vagrant reload dc01 --force
    $ExecutedSteps += "DC01 postboot"
}

# ── Step 3 — DC01 DNS ──────────────────────────────────

Write-Host "`n[3/16] DC01 DNS configuration..."
if (Check-DC01-DNS) {
    Write-Host "    [OK] DNS already configured - skipping"
    $SkippedSteps += "DC01 DNS"
} else {
    vagrant provision dc01 --provision-with dns
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: dns provision failed"; exit 1 }
    $ExecutedSteps += "DC01 DNS"
}

# ── Step 4 — DC01 objects (base - users, groups, OUs) ──

Write-Host "`n[4/16] DC01 AD objects — base (users, groups, OUs)..."
if (Check-DC01-ObjectsBase) {
    Write-Host "    [OK] Base objects already exist - skipping"
    $SkippedSteps += "DC01 objects (base)"
} else {
    vagrant provision dc01 --provision-with objects-base
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: objects-base provision failed"; exit 1 }
    $ExecutedSteps += "DC01 objects (base)"
}

if ($DC01Only) {
    Write-Host ""
    Write-Host "[!] -DC01Only flag set - stopping after DC01 build"
    $SkippedSteps += @("DC02 base","DC02 join","DC03 base","DC03 join","SRV01 base","WS01 base","WS02 base","LIN01 base","SRV01 services","WS01 misconfig","WS02 misconfig","DC01 objects (final)","Harden")
    $Elapsed = (Get-Date) - $StartTime
    $Minutes = [math]::Floor($Elapsed.TotalMinutes)
    $Seconds = $Elapsed.Seconds
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════╗"
    Write-Host "║          DC01 Build Complete             ║"
    Write-Host "╚══════════════════════════════════════════╝"
    Write-Host ""
    Write-Host "  Total time: ${Minutes}m ${Seconds}s"
    exit 0
}

# ── Step 5 — DC02 base ─────────────────────────────────

Write-Host "`n[5/16] DC02 base setup..."
if (Check-DC02-Base) {
    Write-Host "    [OK] DC02 already running - skipping"
    $SkippedSteps += "DC02 base"
} else {
    vagrant up dc02
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: vagrant up dc02 failed"; exit 1 }
    $ExecutedSteps += "DC02 base"
}

# ── Step 6 — DC02 join ─────────────────────────────────

Write-Host "`n[6/16] DC02 domain join..."
if (Check-DC02-Join) {
    Write-Host "    [OK] DC02 already a DC - skipping join"
    $SkippedSteps += "DC02 join"
} else {
    vagrant provision dc02 --provision-with join
    Write-Host "    Waiting 90s for DC02 to initialize..."
    Start-Sleep -Seconds 90
    $ExecutedSteps += "DC02 join"
}

# ── Step 7 — DC03 base ─────────────────────────────────

Write-Host "`n[7/16] DC03 base setup..."
if (Check-DC03-Base) {
    Write-Host "    [OK] DC03 already running - skipping"
    $SkippedSteps += "DC03 base"
} else {
    vagrant up dc03
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: vagrant up dc03 failed"; exit 1 }
    $ExecutedSteps += "DC03 base"
}

# ── Step 8 — DC03 join ─────────────────────────────────

Write-Host "`n[8/16] DC03 domain join..."
if (Check-DC03-Join) {
    Write-Host "    [OK] DC03 already a DC - skipping join"
    $SkippedSteps += "DC03 join"
} else {
    vagrant provision dc03 --provision-with join
    Write-Host "    Waiting 90s for DC03 to initialize..."
    Start-Sleep -Seconds 90
    $ExecutedSteps += "DC03 join"
}

# ── Step 9 — SRV01 base ────────────────────────────────

Write-Host "`n[9/16] SRV01 base setup..."
if (Check-SRV01-Base) {
    Write-Host "    [OK] SRV01 already running - skipping"
    $SkippedSteps += "SRV01 base"
} else {
    vagrant up srv01
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: vagrant up srv01 failed"; exit 1 }
    $ExecutedSteps += "SRV01 base"
}

# ── Step 10 — WS01 base ────────────────────────────────

Write-Host "`n[10/16] WS01 base setup..."
if (Check-WS01-Base) {
    Write-Host "    [OK] WS01 already running - skipping"
    $SkippedSteps += "WS01 base"
} else {
    vagrant up ws01
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: vagrant up ws01 failed"; exit 1 }
    $ExecutedSteps += "WS01 base"
}

# ── Step 11 — WS02 base ────────────────────────────────

Write-Host "`n[11/16] WS02 base setup..."
if (Check-WS02-Base) {
    Write-Host "    [OK] WS02 already running - skipping"
    $SkippedSteps += "WS02 base"
} else {
    vagrant up ws02
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: vagrant up ws02 failed"; exit 1 }
    $ExecutedSteps += "WS02 base"
}

# ── Step 12 — LIN01 base ───────────────────────────────

Write-Host "`n[12/16] LIN01 base setup..."
if (Check-LIN01-Base) {
    Write-Host "    [OK] LIN01 already running - skipping"
    $SkippedSteps += "LIN01 base"
} else {
    vagrant up lin01
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: vagrant up lin01 failed"; exit 1 }
    $ExecutedSteps += "LIN01 base"
}

# ── Step 13 — SRV01 services ───────────────────────────

if ($NoMisconfig) {
    Write-Host "`n[13/16] SRV01 services..."
    Write-Host "    [OK] -NoMisconfig set - skipping"
    $SkippedSteps += "SRV01 services"
} else {
    Write-Host "`n[13/16] SRV01 services..."
    if (Check-SRV01-Services) {
        Write-Host "    [OK] SRV01 services already configured - skipping"
        $SkippedSteps += "SRV01 services"
    } else {
        vagrant provision srv01 --provision-with services
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: srv01 services failed"; exit 1 }
        $ExecutedSteps += "SRV01 services"
    }
}

# ── Step 14 — WS01 misconfig ───────────────────────────

if ($NoMisconfig) {
    Write-Host "`n[14/16] WS01 misconfigurations..."
    Write-Host "    [OK] -NoMisconfig set - skipping"
    $SkippedSteps += "WS01 misconfig"
} else {
    Write-Host "`n[14/16] WS01 misconfigurations..."
    if (Check-WS01-Misconfig) {
        Write-Host "    [OK] WS01 already misconfigured - skipping"
        $SkippedSteps += "WS01 misconfig"
    } else {
        vagrant provision ws01 --provision-with misconfig
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: ws01 misconfig failed"; exit 1 }
        $ExecutedSteps += "WS01 misconfig"
    }
}

# ── Step 15 — WS02 misconfig ───────────────────────────

if ($NoMisconfig) {
    Write-Host "`n[15/16] WS02 misconfigurations..."
    Write-Host "    [OK] -NoMisconfig set - skipping"
    $SkippedSteps += "WS02 misconfig"
} else {
    Write-Host "`n[15/16] WS02 misconfigurations..."
    if (Check-WS02-Misconfig) {
        Write-Host "    [OK] WS02 already misconfigured - skipping"
        $SkippedSteps += "WS02 misconfig"
    } else {
        vagrant provision ws02 --provision-with misconfig
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: ws02 misconfig failed"; exit 1 }
        $ExecutedSteps += "WS02 misconfig"
    }
}

# ── Step 16 — DC01 objects (final pass) ────────────────

Write-Host "`n[16/16] DC01 AD objects (final pass)..."
if (Check-DC01-Objects) {
    Write-Host "    [OK] AD objects final pass already done - skipping"
    $SkippedSteps += "DC01 objects (final)"
} else {
    vagrant provision dc01 --provision-with objects
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: final objects provision failed"; exit 1 }
    $ExecutedSteps += "DC01 objects (final)"
}

# ── Step 17 — Hardening ────────────────────────────────

Write-Host "`n[17/17] Hardening — removing default vagrant credentials..."
if (Check-Hardened) {
    Write-Host "    [OK] Already hardened - skipping"
    $SkippedSteps += "Harden"
} else {
    foreach ($vm in @("dc01","dc02","dc03","srv01","ws01","ws02")) {
        Write-Host "    Hardening $vm..."
        vagrant provision $vm --provision-with harden
    }
    Write-Host "    [OK] Hardening complete"
    $ExecutedSteps += "Harden"
}

# ── Summary ────────────────────────────────────────────

$EndTime = Get-Date
$Elapsed = $EndTime - $StartTime
$Minutes = [math]::Floor($Elapsed.TotalMinutes)
$Seconds = $Elapsed.Seconds

Write-Host ""
Write-Host "╔══════════════════════════════════════════╗"
Write-Host "║              Setup Summary               ║"
Write-Host "╚══════════════════════════════════════════╝"
Write-Host ""
Write-Host "  Total time: ${Minutes}m ${Seconds}s"
Write-Host ""
Write-Host "  Steps executed:"
if ($ExecutedSteps.Count -eq 0) {
    Write-Host "    (none)"
} else {
    foreach ($step in $ExecutedSteps) {
        Write-Host "    • $step"
    }
}
Write-Host ""
Write-Host "  Steps skipped (already done):"
if ($SkippedSteps.Count -eq 0) {
    Write-Host "    (none)"
} else {
    foreach ($step in $SkippedSteps) {
        Write-Host "    • $step"
    }
}
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗"
Write-Host "║        Lab fully built and ready!        ║"
Write-Host "╚══════════════════════════════════════════╝"
Write-Host ""
Write-Host "DC01  192.168.200.10  Primary Domain Controller"
Write-Host "DC02  192.168.200.11  Secondary Domain Controller"
Write-Host "DC03  192.168.200.12  Subdomain Controller (it.secscope.corp)"
Write-Host "SRV01 192.168.200.20  MSSQL + IIS + ADCS"
Write-Host "WS01  192.168.200.30  Workstation 1"
Write-Host "WS02  192.168.200.31  Workstation 2"
Write-Host "LIN01 192.168.200.40  Linux Domain Member"
