# ═══════════════════════════════════════════════════════════════════════════
# Active Directory Alligator Labs - Unified Setup Orchestrator (Windows)
# ═══════════════════════════════════════════════════════════════════════════
# Run from the ActiveDirectoryAlligatorLABS directory:
#   powershell -ExecutionPolicy Bypass -File setup.ps1 [SUBCOMMAND] [OPTIONS]

param(
    [Parameter(Position=0)]
    [string]$Subcommand = "deploy",

    [switch]$Help,
    [switch]$Verbose,
    [switch]$Quiet,
    [switch]$Debug,
    [switch]$NoColor,

    [string]$VMs = "",
    [switch]$DC01Only,
    [switch]$SkipServices,
    [switch]$SkipMisconfig,
    [switch]$SkipHardening,
    [switch]$SkipLinux,
    [switch]$DisableAVUpdate,
    [switch]$SealNetwork,
    [switch]$NoSeal,

    [switch]$ServerOnly,
    [switch]$WorkstationOnly,
    [switch]$DebianOnly,
    [switch]$SkipDebian,
    [switch]$NoVagrantAdd,
    [string]$ServerISO = "",
    [string]$Win10ISO = "",
    [string]$DebianISO = ""
)

$ErrorActionPreference = "Continue"

# Network seal is ON by default for full builds (removes NAT nic1 so each VM is
# single-homed on 192.168.200.x, killing the NAT-leak class of bugs). -NoSeal
# disables it; -SealNetwork forces it even on a scoped run. Because sealing
# severs Vagrant/WinRM/RDP, an explicit request is tracked so scoped (--VMs)
# runs don't auto-seal and cut management mid-workflow.
$SealExplicit = $SealNetwork.IsPresent -or $NoSeal.IsPresent
$EffectiveSeal = if ($NoSeal) { $false } else { $true }

# ── Defaults ──────────────────────────────────────────────────────────────

$ScriptDir = $PSScriptRoot
$AdminPass = if ($env:ADMIN_PASS) { $env:ADMIN_PASS } else { "SecScope2024!" }
$Domain = "secscope.corp"
$env:DC_WINRM_PASSWORD = $AdminPass

$DefaultServerISO = Join-Path $ScriptDir "iso\SERVER_EVAL_x64FRE_en-us.iso"
$DefaultWin10ISO  = Join-Path $ScriptDir "iso\Win10_22H2_English_x64v1.iso"
$DefaultDebianISO = Join-Path $ScriptDir "iso\debian-12.15.0-amd64-netinst-preseed.iso"

$AllWindowsVMs = @("dc01","dc02","dc03","srv01","ws01","ws02")
$AllDCs = @("dc01","dc02","dc03")
$AllMembers = @("srv01","ws01","ws02","lin01")
$AllVMs = @("dc01","dc02","dc03","srv01","ws01","ws02","lin01")

$StartTime = Get-Date
$ExecutedSteps = @()
$SkippedSteps = @()

# ── Verbosity ─────────────────────────────────────────────────────────────

function Write-Log    { if (-not $Quiet) { Write-Host $args } }
function Write-OK     { Write-Host "    [OK] $args" -ForegroundColor Green }
function Write-Skip   { Write-Host "    [SKIP] $args" -ForegroundColor Yellow }
function Write-Warn   { Write-Host "    [WARN] $args" -ForegroundColor Yellow }
function Write-Err    { Write-Host "    [ERROR] $args" -ForegroundColor Red }
function Write-Step   { Write-Host "`n$args" -ForegroundColor Cyan }
function Write-Info   { Write-Host "    [*] $args" -ForegroundColor Cyan }

function Write-VerboseLog {
    param([string]$Message)
    if (-not $Quiet) { Write-Host $Message }
}

function Filter-WinRM {
    param([string[]]$Lines)
    if ($Debug -or $Verbose) { return $Lines }
    return $Lines | Where-Object {
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
}

function Invoke-Vagrant {
    param([string[]]$Arguments)
    $output = vagrant @Arguments 2>&1
    $filtered = Filter-WinRM -Lines $output
    if (-not $Quiet) {
        if ($filtered) { $filtered | Write-Host }
    }
    return $LASTEXITCODE
}

# ── VM selection ─────────────────────────────────────────────────────────

function Test-VMSelected {
    param([string]$VMName)
    if (-not $VMs) { return $true }
    $selected = $VMs -split ',' | ForEach-Object { $_.Trim().ToLower() }
    return $selected -contains $VMName.ToLower()
}

# True for Windows/Linux member VMs (not domain controllers).
function Test-Member {
    param([string]$VMName)
    return ($AllMembers -contains $VMName.ToLower())
}

# Strip stale NAT-range (10.0.2.*) A records and non-internal AAAA records from
# DC01's secscope.corp zone. 10.0.2.15 is every VM's own NAT IP, so a leaked
# "<dc> -> 10.0.2.15" record makes clients round-robin onto themselves and
# breaks Kerberos/replication/joins. Safe + idempotent: only removes NAT-range
# A / IPv6 records, never touches 192.168.200.x, machine accounts, or services.
function Clean-NatLeak {
    vagrant winrm dc01 -c @'
$zone = "secscope.corp"
Get-DnsServerResourceRecord -ZoneName $zone -RRType A -ErrorAction SilentlyContinue | ForEach-Object {
    $ip = $_.RecordData.IPv4Address.IPAddressToString
    if ($ip -like "10.0.2.*") {
        Write-Host "Removing: $($_.HostName) -> $ip"
        dnscmd localhost /RecordDelete $zone $($_.HostName) A $ip /f 2>&1 | Out-Null
    }
}
Get-DnsServerResourceRecord -ZoneName $zone -RRType AAAA -ErrorAction SilentlyContinue | ForEach-Object {
    dnscmd localhost /RecordDelete $zone $($_.HostName) AAAA $($_.RecordData.IPv6Address.IPAddressToString) /f 2>&1 | Out-Null
}
Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
'@ 2>&1 | Out-Null
}

# Remove stale child-domain (it.secscope.corp) metadata from the SURVIVING DC01
# before DC03 (re)joins. When only the DC03 VM is destroyed, the forest keeps the
# child-domain crossRef, the 'it' NS delegation and the it.secscope.corp
# forwarder zone, so Install-ADDSDomain aborts with "The specified domain already
# exists". Self-heals a DC03 rebuild against a running DC01/DC02. Idempotent:
# only acts when the DC03 computer object is absent (a real rebuild).
function Clean-StaleChildDomain {
    Write-Info "Cleaning stale child-domain metadata on DC01 (for DC03 rebuild)..."
    vagrant winrm dc01 -c @'
$childDN = "DC=it,DC=secscope,DC=corp"
$partitionsDN = "CN=Partitions,CN=Configuration,DC=secscope,DC=corp"
Import-Module ActiveDirectory -ErrorAction SilentlyContinue
$dc03Present = $false
try { if (Get-ADComputer -Identity "DC03" -ErrorAction Stop) { $dc03Present = $true } } catch {}
if ($dc03Present) {
    Write-Host "DC03 computer object present - leaving child domain intact"
} else {
    try {
        $crossRefs = Get-ADObject -SearchBase $partitionsDN -SearchScope OneLevel -LDAPFilter "(objectClass=crossRef)" -Properties nCName -ErrorAction Stop | Where-Object { $_.nCName -eq $childDN }
        foreach ($cr in $crossRefs) {
            Remove-ADObject -Identity $cr.DistinguishedName -Recursive -Confirm:$false -ErrorAction Stop
            Write-Host "Removed stale crossRef: $($cr.DistinguishedName)"
        }
        if (-not $crossRefs) { Write-Host "No stale crossRef" }
    } catch { Write-Host "crossRef cleanup skipped: $_" }
    Import-Module DnsServer -ErrorAction SilentlyContinue
    Get-DnsServerResourceRecord -ZoneName "secscope.corp" -Name "it" -RRType NS -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-DnsServerResourceRecord -ZoneName "secscope.corp" -InputObject $_ -Force -ErrorAction SilentlyContinue
        Write-Host "Removed stale it NS delegation"
    }
    $fwd = Get-DnsServerZone -Name "it.secscope.corp" -ErrorAction SilentlyContinue
    if ($fwd -and $fwd.ZoneType -eq "Forwarder") {
        Remove-DnsServerZone -Name "it.secscope.corp" -Force -ErrorAction SilentlyContinue
        Write-Host "Removed stale it.secscope.corp forwarder zone"
    }
    Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
}
'@ 2>&1 | Out-Null
}

# ── Check functions ──────────────────────────────────────────────────────

function Test-Running {
    param([string]$VMName)
    $status = vagrant status $VMName 2>&1
    return ($status -match "running")
}

function Test-DC01Postboot {
    $result = vagrant winrm dc01 -c "Get-ADDomain" 2>&1
    return ($result -match "secscope")
}

function Test-DC01DNS {
    $result = vagrant winrm dc01 -c "Get-DnsServerZone secscope.corp" 2>&1
    return ($result -match "secscope")
}

function Test-DC01ObjectsBase {
    $result = vagrant winrm dc01 -c "Get-ADUser anakin" 2>&1
    return ($result -match "anakin")
}

function Test-DC01AVUpdateGPO {
    $result = vagrant winrm dc01 -c "Get-GPO -Name 'Disable AV and Windows Update'" 2>&1
    return ($result -match "Disable AV and Windows Update")
}

function Test-DC01Objects {
    # The final objects pass applies per-MEMBER ACLs (WS01 HelpDesk GenericWrite,
    # WS02 unconstrained delegation, SRV01 constrained delegation). The old check
    # merely matched the string "WS01" in Get-ADComputer output (always present,
    # even with zero ACLs applied), a false positive that made the final pass
    # self-skip and left delegation unset. Verify actual applied state, scoped to
    # the members selected for this run.
    $checkWs01  = Test-VMSelected ws01
    $checkWs02  = Test-VMSelected ws02
    $checkSrv01 = Test-VMSelected srv01
    if (-not ($checkWs01 -or $checkWs02 -or $checkSrv01)) { return $true }

    $ps = '$ok = $true; '
    if ($checkWs01)  { $ps += 'try { $dn=(Get-ADComputer WS01).DistinguishedName; $sid=(Get-ADGroup HelpDesk).SID; $ace=(Get-Acl "AD:\$dn").Access | Where-Object { $_.ActiveDirectoryRights -match "GenericWrite" -and $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $sid.Value }; if (-not $ace) { $ok=$false } } catch { $ok=$false }; ' }
    if ($checkWs02)  { $ps += 'try { if (-not (Get-ADComputer WS02 -Properties TrustedForDelegation).TrustedForDelegation) { $ok=$false } } catch { $ok=$false }; ' }
    if ($checkSrv01) { $ps += 'try { if (-not (Get-ADComputer SRV01 -Properties msDS-AllowedToDelegateTo)."msDS-AllowedToDelegateTo") { $ok=$false } } catch { $ok=$false }; ' }
    $ps += 'if ($ok) { "OBJECTS_DONE" }'

    $result = vagrant winrm dc01 -c $ps 2>&1
    return ($result -match "OBJECTS_DONE")
}

function Test-DC02Join {
    $result = vagrant winrm dc02 -c "Get-ADDomainController" 2>&1
    return ($result -match "DC02")
}

function Test-DC03Join {
    $result = vagrant winrm dc03 -c "Get-ADDomain" 2>&1
    return ($result -match "it")
}

function Test-DC02Postboot {
    # ADWS is already started during the JOIN step (dc02_join.ps1), so testing
    # ADWS=Running produced a FALSE POSITIVE that skipped postboot entirely -
    # leaving ConfigurationStatus=1 (the "Promote this server to a domain
    # controller" banner). Gate on postboot's real end-state: ConfigurationStatus=2.
    $result = vagrant winrm dc02 -c "(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\10' -Name ConfigurationStatus -ErrorAction SilentlyContinue).ConfigurationStatus" 2>&1
    return ($result -match "^\s*2\s*$")
}

function Test-DC03Postboot {
    # Same false-positive class as Test-DC02Postboot (ADWS started at join).
    $result = vagrant winrm dc03 -c "(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\10' -Name ConfigurationStatus -ErrorAction SilentlyContinue).ConfigurationStatus" 2>&1
    return ($result -match "^\s*2\s*$")
}

function Test-SRV01Services {
    $result = vagrant winrm srv01 -c "Get-WindowsFeature Web-Server" 2>&1
    return ($result -match "Installed")
}

function Test-WS01Misconfig {
    $result = vagrant winrm ws01 -c "Get-LocalUser localadmin" 2>&1
    return ($result -match "localadmin")
}

function Test-WS02Misconfig {
    # WS02 doesn't create a localadmin; verify a real WS02 artifact instead -
    # the AutoLogon-as-anakin registry value set by ws02_misconfig.ps1.
    $result = vagrant winrm ws02 -c "(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').DefaultUserName" 2>&1
    return ($result -match "anakin")
}

function Test-Hardened {
    param([string]$VMName)
    # Hardened == vagrant account gone (deleted) OR present-but-disabled.
    # After harden_windows.ps1 deletes the user, Get-LocalUser errors and prints
    # nothing, so treat "not found" (Absent) as hardened too.
    $result = vagrant winrm $VMName -c "if (Get-LocalUser vagrant -ErrorAction SilentlyContinue) { (Get-LocalUser vagrant).Enabled } else { 'Absent' }" 2>&1
    return ($result -match "False" -or $result -match "Absent")
}

function Ensure-ADWS {
    param([string]$VMName)
    for ($i = 1; $i -le 6; $i++) {
        Start-Sleep -Seconds 3
        $status = vagrant winrm $VMName -c "Get-Service ADWS | Select -ExpandProperty Status" 2>&1 | ForEach-Object { $_.Trim() }
        if ($status -eq "Running") {
            Write-OK "ADWS running on $VMName"
            return
        }
        if ($status -eq "Stopped") {
            Write-Info "Enabling ADWS on $VMName..."
            vagrant winrm $VMName -c "Set-Service ADWS -StartupType Automatic; Start-Service ADWS" 2>&1 | Out-Null
            Start-Sleep -Seconds 3
        }
        Write-VerboseLog "    ADWS on $VMName : attempt $i/6 ($status)"
    }
    Write-Warn "ADWS not running on $VMName after 18s"
}

# ── Pre-flight ───────────────────────────────────────────────────────────

function Invoke-Preflight {
    Write-Step "[0] Checking requirements..."
    if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: vagrant not found in PATH"
        exit 1
    }
    if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) {
        $vboxPath = "C:\Program Files\Oracle\VirtualBox"
        if (Test-Path "$vboxPath\VBoxManage.exe") {
            $env:Path = "$vboxPath;$env:Path"
        } else {
            Write-Host "ERROR: VBoxManage not found. Install VirtualBox first."
            exit 1
        }
    }
    Write-OK "vagrant and VBoxManage found"
}

# ── Subcommand: build-boxes ──────────────────────────────────────────────

function Invoke-BuildBoxes {
    Write-Host "╔══════════════════════════════════════════╗"
    Write-Host "║  AD Alligator Labs - Build Packer Boxes  ║"
    Write-Host "╚══════════════════════════════════════════╝"

    $BuildServer = -not $WorkstationOnly
    $BuildWin10  = -not $ServerOnly
    $BuildDebian = -not ($ServerOnly -or $WorkstationOnly)
    if ($DebianOnly) { $BuildServer = $false; $BuildWin10 = $false; $BuildDebian = $true }
    if ($SkipDebian) { $BuildDebian = $false }
    $SkipVagrant = $NoVagrantAdd

    $ServerISOPath = if ($ServerISO) { $ServerISO } else { $DefaultServerISO }
    $Win10ISOPath  = if ($Win10ISO)  { $Win10ISO }  else { $DefaultWin10ISO }
    $DebianISOPath = if ($DebianISO) { $DebianISO } else { $DefaultDebianISO }

    # Pre-flight
    $BundledPacker = Join-Path $ScriptDir "bin\packer.exe"
    if (-not (Get-Command packer -ErrorAction SilentlyContinue) -and (Test-Path $BundledPacker)) {
        $env:Path = "$(Join-Path $ScriptDir bin);$env:Path"
        Write-Info "Using bundled packer: $BundledPacker"
    }
    foreach ($tool in @("packer","vagrant","VBoxManage")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Write-Host "ERROR: $tool not found in PATH"
            exit 1
        }
        Write-OK "$tool found"
    }

    Write-Info "Cleaning previous build artifacts..."
    VBoxManage unregistervm packer-windows-server-2022 --delete 2>$null
    VBoxManage unregistervm packer-windows-10 --delete 2>$null
    VBoxManage unregistervm packer-debian-bookworm --delete 2>$null
    Remove-Item -Recurse -Force "$env:USERPROFILE\VirtualBox VMs\packer-windows-server-2022" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "$env:USERPROFILE\VirtualBox VMs\packer-windows-10" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "$env:USERPROFILE\VirtualBox VMs\packer-debian-bookworm" -ErrorAction SilentlyContinue
    Write-OK "Cleanup done"

    $buildStart = Get-Date

    if ($BuildServer) {
        Write-Host "`n[1] Building Windows Server 2022 box..."
        if (-not (Test-Path $ServerISOPath)) {
            Write-Host "ERROR: ISO not found at: $ServerISOPath"
            exit 1
        }
        Write-Info "ISO: $ServerISOPath"
        Write-Info "Calculating checksum..."
        $srvChecksum = (Get-FileHash -Algorithm SHA256 $ServerISOPath).Hash.ToLower()
        Write-Info "SHA256: $srvChecksum"
        Write-Host "    Starting Packer build (45-90 minutes)..."

        packer init (Join-Path $ScriptDir "packer\windows-server-2022\") 2>$null
        $packerArgs = @(
            "build",
            "-var", "iso_path=$ServerISOPath",
            "-var", "iso_checksum=$srvChecksum",
            "$ScriptDir\packer\windows-server-2022\windows-server-2022.pkr.hcl"
        )
        & packer @packerArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Packer build failed for Windows Server 2022"
            exit 1
        }

        if (-not $SkipVagrant) {
            Write-Info "Adding to Vagrant..."
            vagrant box remove secscope/windows-server-2022 --force 2>$null
            vagrant box add --name secscope/windows-server-2022 "$ScriptDir\packer\boxes\windows-server-2022.box"
            Write-OK "Windows Server 2022 box added"
        }
    }

    if ($BuildWin10) {
        Write-Host "`n[2] Building Windows 10 box..."
        if (-not (Test-Path $Win10ISOPath)) {
            Write-Host "ERROR: ISO not found at: $Win10ISOPath"
            exit 1
        }
        Write-Info "ISO: $Win10ISOPath"
        Write-Info "Calculating checksum..."
        $win10Checksum = (Get-FileHash -Algorithm SHA256 $Win10ISOPath).Hash.ToLower()
        Write-Info "SHA256: $win10Checksum"
        Write-Host "    Starting Packer build (45-90 minutes)..."

        packer init (Join-Path $ScriptDir "packer\windows-10\") 2>$null
        $packerArgs = @(
            "build",
            "-var", "iso_path=$Win10ISOPath",
            "-var", "iso_checksum=$win10Checksum",
            "$ScriptDir\packer\windows-10\windows-10.pkr.hcl"
        )
        & packer @packerArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Packer build failed for Windows 10"
            exit 1
        }

        if (-not $SkipVagrant) {
            Write-Info "Adding to Vagrant..."
            vagrant box remove secscope/windows-10 --force 2>$null
            vagrant box add --name secscope/windows-10 "$ScriptDir\packer\boxes\windows-10.box"
            Write-OK "Windows 10 box added"
        }
    }

    if ($BuildDebian) {
        Write-Host "`n[3] Building Debian Bookworm box..."
        if (-not (Test-Path $DebianISOPath)) {
            Write-Host "ERROR: ISO not found at: $DebianISOPath"
            exit 1
        }
        Write-Info "ISO: $DebianISOPath"
        Write-Info "Calculating checksum..."
        $debianChecksum = (Get-FileHash -Algorithm SHA256 $DebianISOPath).Hash.ToLower()
        Write-Info "SHA256: $debianChecksum"
        Write-Host "    Starting Packer build (10-20 minutes)..."

        packer init (Join-Path $ScriptDir "packer\debian-bookworm\") 2>$null
        $packerArgs = @(
            "build",
            "-var", "iso_path=$DebianISOPath",
            "-var", "iso_checksum=$debianChecksum",
            "$ScriptDir\packer\debian-bookworm\debian-bookworm.pkr.hcl"
        )
        & packer @packerArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Packer build failed for Debian Bookworm"
            exit 1
        }

        if (-not $SkipVagrant) {
            Write-Info "Adding to Vagrant..."
            vagrant box remove secscope/debian-bookworm --force 2>$null
            vagrant box add --name secscope/debian-bookworm "$ScriptDir\packer\boxes\debian-bookworm.box"
            Write-OK "Debian Bookworm box added"
        }
    }

    $buildElapsed = [int]((Get-Date) - $buildStart).TotalMinutes
    Write-Host "`nAll boxes built in $buildElapsed minutes."
}

# ── Subcommand: status ───────────────────────────────────────────────────

function Invoke-Status {
    Write-Host "╔══════════════════════════════════════════╗"
    Write-Host "║       AD Alligator Labs VM Status        ║"
    Write-Host "╚══════════════════════════════════════════╝"
    foreach ($vm in $AllVMs) {
        $status = vagrant status $vm 2>&1 |
            Where-Object { $_ -match $vm } |
            ForEach-Object { ($_ -split "\s+")[1] }
        Write-Host ("  {0,-8} {1}" -f $vm, $status)
    }
}

# ── Subcommand: destroy ──────────────────────────────────────────────────

function Invoke-Destroy {
    Write-Host "[!] Destroying all VMs..."
    vagrant destroy -f
    Write-Host "[OK] All VMs destroyed."
}

# ── Deploy steps ─────────────────────────────────────────────────────────

function Step-DC01Base {
    Write-Step "[1/14] DC01 base setup..."
    if (Test-Running dc01) {
        Write-Skip "DC01 already running"
        $Script:SkippedSteps += "DC01 base"
        return
    }
    $exitCode = Invoke-Vagrant -Arguments @("up","dc01")
    if ($exitCode -ne 0) { Write-Err "vagrant up dc01 failed"; exit 1 }
    $Script:ExecutedSteps += "DC01 base"
}

function Step-DC01Postboot {
    Write-Step "[2/14] DC01 AD promotion..."
    if (Test-DC01Postboot) {
        Write-Skip "DC01 already a DC"
        $Script:SkippedSteps += "DC01 postboot"
        return
    }
    Write-VerboseLog "    (WinRM errors during AD DS promotion are expected)"
    Invoke-Vagrant -Arguments @("provision","dc01","--provision-with","postboot")

    Write-Info "Polling for AD to initialize..."
    $ready = $false
    for ($i = 1; $i -le 12; $i++) {
        Start-Sleep -Seconds 5
        if (Test-DC01Postboot) {
            Write-OK "AD ready after $($i*5)s"
            $ready = $true
            break
        }
        Write-VerboseLog "    ... attempt $i/12"
    }
    if (-not $ready) {
        Write-Err "AD did not initialize within 60s"
        exit 1
    }
    vagrant reload dc01 --force
    Ensure-ADWS dc01
    $Script:ExecutedSteps += "DC01 postboot"
}

function Step-DC01DNS {
    Write-Step "[3/14] DC01 DNS configuration..."
    if (Test-DC01DNS) {
        Write-Skip "DNS already configured"
        $Script:SkippedSteps += "DC01 DNS"
        return
    }
    $exitCode = Invoke-Vagrant -Arguments @("provision","dc01","--provision-with","dns")
    if ($exitCode -ne 0) { Write-Err "dns provision failed"; exit 1 }
    $Script:ExecutedSteps += "DC01 DNS"

    Write-Info "Cleaning stale NAT DNS records..."
    Clean-NatLeak
    Write-OK "NAT DNS cleanup done"
}

function Step-DC01ObjectsBase {
    Write-Step "[4/14] DC01 AD objects - base (users, groups, OUs)..."
    if (Test-DC01ObjectsBase) {
        Write-Skip "Base objects already exist"
        $Script:SkippedSteps += "DC01 objects (base)"
        return
    }
    $exitCode = Invoke-Vagrant -Arguments @("provision","dc01","--provision-with","objects-base")
    if ($exitCode -ne 0) { Write-Err "objects-base failed"; exit 1 }
    $Script:ExecutedSteps += "DC01 objects (base)"
}

function Step-DC01AVUpdateGPO {
    if (-not $DisableAVUpdate) {
        $Script:SkippedSteps += "AV/Update GPO"
        return
    }
    Write-Step "[+] DC01 GPO - disable Defender AV and Windows Update (all machines)..."
    if (Test-DC01AVUpdateGPO) {
        Write-Skip "AV/Update GPO already present"
        $Script:SkippedSteps += "AV/Update GPO"
        return
    }
    $exitCode = Invoke-Vagrant -Arguments @("provision","dc01","--provision-with","avupdate-gpo")
    if ($exitCode -ne 0) { Write-Err "AV/Update GPO failed"; exit 1 }
    $Script:ExecutedSteps += "AV/Update GPO"
}

function Step-BootRemaining {
    Write-Step "[5/14] Booting remaining VMs in parallel..."
    $toBoot = @()
    foreach ($vm in ($AllMembers + $AllDCs)) {
        if ($vm -eq "dc01") { continue }
        if (-not (Test-VMSelected $vm)) { continue }
        if ($vm -eq "lin01" -and $SkipLinux) { continue }
        if (-not (Test-Running $vm)) {
            $toBoot += $vm
        } else {
            Write-Skip "$vm already running"
        }
    }

    if ($toBoot.Count -eq 0) {
        Write-Skip "All VMs already running"
        $Script:SkippedSteps += "Boot remaining VMs"
        return
    }

    $jobs = @()
    foreach ($vm in $toBoot) {
        Write-Info "Booting $vm..."
        $jobs += Start-Job -Name "boot-$vm" -ScriptBlock {
            param($vmName)
            vagrant up $vmName 2>&1 | Out-Null
        } -ArgumentList $vm
    }

    $failures = 0
    foreach ($job in $jobs) {
        Wait-Job $job | Out-Null
        $result = Receive-Job $job
        if ($result -match "error" -or $LASTEXITCODE -ne 0) { $failures++ }
        Remove-Job $job
    }
    if ($failures -gt 0) {
        Write-Err "$failures VM(s) failed to boot"
        exit 1
    }
    Write-OK "All VMs booted"
    $Script:ExecutedSteps += "Boot remaining VMs"
}

# ── Step: sysprep (generate unique SIDs) ──
# The Packer base box ships with a machine SID identical to the domain's, so
# EVERY VM built from it (DCs and members alike) must sysprep /generalize before
# it can join/promote, or Add-Computer/Install-ADDS* fails with "SID identical".
function Step-Sysprep {
    $sysprepVMs = @()
    foreach ($vm in @("dc02","dc03","srv01","ws01","ws02")) {
        if (-not (Test-VMSelected $vm)) { continue }
        $sysprepVMs += $vm
    }
    if ($sysprepVMs.Count -eq 0) {
        Write-Skip "Sysprep: no VMs selected"
        $Script:SkippedSteps += "Sysprep"
        return
    }

    foreach ($vm in $sysprepVMs) {
        Write-Step "[sysprep] Checking $vm..."
        $role = (vagrant winrm $vm -c "(Get-CimInstance Win32_ComputerSystem).DomainRole" 2>&1 | Out-String).Trim()
        $roleNum = 0; [int]::TryParse($role, [ref]$roleNum) | Out-Null
        if ($roleNum -ge 4) {
            Write-Skip "$vm already a DC (role $role), skipping sysprep"
            $Script:SkippedSteps += "Sysprep $vm"
            continue
        }
        # Members: if already domain-joined (role 1=member workstation, 3=member
        # server), the SID work is done - don't re-sysprep.
        if ((Test-Member $vm) -and $roleNum -ge 1 -and $roleNum -ne 2) {
            Write-Skip "$vm already domain-joined (role $role), skipping sysprep"
            $Script:SkippedSteps += "Sysprep $vm"
            continue
        }
        Write-Step "[sysprep] Generating new SID on $vm..."
        Invoke-Vagrant -Arguments @("provision",$vm,"--provision-with","sysprep") | Out-Null
        Write-Info "Sysprep launched on $vm, machine will reboot. Waiting for OOBE..."
        # /generalize reboots into OOBE and drops WinRM. sysprep_sid.ps1 preserves
        # the computer name from COMPUTERNAME at sysprep time (the base-box name
        # for a member, e.g. VAGRANT-BUILD); a member is not renamed to "$vm"
        # until the join step. So we must NOT gate readiness on the hostname
        # matching "$vm". Instead wait for WinRM to go DOWN (reboot started), then
        # wait for it to come back up.
        for ($i = 1; $i -le 18; $i++) {
            vagrant winrm $vm -c "exit 0" 2>$null
            if (-not $?) { break }
            Start-Sleep -Seconds 5
        }
        $online = $false
        for ($i = 1; $i -le 30; $i++) {
            Start-Sleep -Seconds 10
            vagrant winrm $vm -c "exit 0" 2>$null
            if ($?) {
                Write-OK "$vm back online after sysprep ($($i*10)s)"
                $online = $true
                break
            }
            Write-VerboseLog "    $vm sysprep wait $i/30..."
        }
        if (-not $online) {
            Write-Err "$vm did not come back after sysprep"
            exit 1
        }
        Write-Info "Running vagrant reload on $vm to stabilize..."
        vagrant reload $vm --force
        # DCs get their static IP re-applied by the dedicated 'base' provisioner
        # after sysprep. Members have no 'base' provisioner - domain_join.ps1
        # (run later in Step-MemberJoin) sets the static IP and re-enables the
        # sysprep-disabled internal NIC.
        if (-not (Test-Member $vm)) {
            Write-Info "Re-applying base config (IP) on $vm..."
            Invoke-Vagrant -Arguments @("provision",$vm,"--provision-with","base") | Out-Null
        }
        $Script:ExecutedSteps += "Sysprep $vm"
    }
}

# ── Step 7.5: Windows member domain joins (srv01, ws01, ws02) ──
# Members must be sysprepped (Step-Sysprep) BEFORE this so their machine SID is
# unique. domain_join.ps1 sets the static IP, re-enables the sysprep-disabled
# internal NIC, and joins; the reload finalizes the join + computer rename.
# Runs after the DCs are up so DNS/Kerberos resolve, and BEFORE
# Step-DC01ObjectsFinal (which needs the joined computer objects to set the
# RBCD / delegation ACLs).
function Step-MemberJoin {
    $winMembers = @("srv01","ws01","ws02")
    $any = $false
    foreach ($vm in $winMembers) {
        if (Test-VMSelected $vm) { $any = $true; break }
    }
    if (-not $any) {
        $Script:SkippedSteps += "Member joins"
        return
    }

    # Clear any recurring NAT leak on DC01 first so members don't resolve a DC
    # to 10.0.2.15 during the join.
    Write-Info "Pre-join NAT DNS cleanup on DC01..."
    Clean-NatLeak

    $joinFailures = 0
    foreach ($vm in $winMembers) {
        if (-not (Test-VMSelected $vm)) { continue }
        Write-Step "[7.5] $vm domain join..."
        $role = (vagrant winrm $vm -c "(Get-CimInstance Win32_ComputerSystem).DomainRole" 2>&1 | Out-String).Trim()
        if ($role -eq "1" -or $role -eq "3") {
            Write-Skip "$vm already domain-joined (role $role)"
            $Script:SkippedSteps += "$vm join"
            continue
        }
        $exitCode = Invoke-Vagrant -Arguments @("provision",$vm,"--provision-with","join")
        if ($exitCode -ne 0) { Write-Err "$vm join failed"; $joinFailures++; continue }
        Write-Info "Rebooting $vm to finalize domain join..."
        # The post-join reload occasionally trips Vagrant's boot_timeout when
        # WinRM is slow to return after the domain-join reboot. That is a
        # transient race, not a real failure, so retry the reload a few times
        # (re-confirming the joined role each time) before giving up.
        $reloadOk = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            vagrant reload $vm --force 2>&1 | Out-Null
            $role = (vagrant winrm $vm -c "(Get-CimInstance Win32_ComputerSystem).DomainRole" 2>&1 | Out-String).Trim()
            if ($role -eq "1" -or $role -eq "3") { $reloadOk = $true; break }
            Write-Warn "$vm not domain-joined after reload attempt $attempt/3 (role=$role); retrying..."
            Start-Sleep -Seconds 10
        }
        if ($reloadOk) {
            Write-OK "$vm joined secscope.corp (role $role)"
            $Script:ExecutedSteps += "$vm join"
        } else {
            Write-Err "$vm did not reach a domain-joined role (role=$role)"
            $joinFailures++
        }
    }
    if ($joinFailures -gt 0) {
        Write-Err "$joinFailures member join(s) failed"
        exit 1
    }
}

function Step-DCJoins {
    $jobs = @()

    if (Test-VMSelected dc02) {
        if (Test-DC02Join) {
            Write-Skip "DC02 already a DC"
            $Script:SkippedSteps += "DC02 join"
        } else {
            Write-Info "Starting DC02 join (parallel with DC03)..."
            $jobs += Start-Job -Name "join-dc02" -ScriptBlock {
                vagrant provision dc02 --provision-with join 2>&1 | Out-Null
                for ($i = 1; $i -le 12; $i++) {
                    Start-Sleep -Seconds 3
                    $result = vagrant winrm dc02 -c "Get-ADDomainController" 2>&1
                    if ($result -match "DC02") { break }
                }
                vagrant winrm dc02 -c "Set-Service ADWS -StartupType Automatic; Start-Service ADWS" 2>&1 | Out-Null
            }
        }
    }

    if (Test-VMSelected dc03) {
        if (Test-DC03Join) {
            Write-Skip "DC03 already a DC"
            $Script:SkippedSteps += "DC03 join"
        } else {
            Clean-StaleChildDomain
            Write-Info "Starting DC03 join (parallel with DC02)..."
            $jobs += Start-Job -Name "join-dc03" -ScriptBlock {
                vagrant provision dc03 --provision-with join 2>&1 | Out-Null
                for ($i = 1; $i -le 12; $i++) {
                    Start-Sleep -Seconds 3
                    $result = vagrant winrm dc03 -c "Get-ADDomain" 2>&1
                    if ($result -match "it") { break }
                }
                vagrant winrm dc03 -c "Set-Service ADWS -StartupType Automatic; Start-Service ADWS" 2>&1 | Out-Null
            }
        }
    }

    foreach ($job in $jobs) {
        Wait-Job $job | Out-Null
        Receive-Job $job | Out-Null
        Remove-Job $job
    }
    if ("DC02 join" -notin $SkippedSteps) { $Script:ExecutedSteps += "DC02 join" }
    if ("DC03 join" -notin $SkippedSteps) { $Script:ExecutedSteps += "DC03 join" }
}

function Step-DC02Postboot {
    if (-not (Test-VMSelected dc02)) { $Script:SkippedSteps += "DC02 postboot"; return }
    Write-Step "[6b/14] DC02 post-promotion config..."
    if (Test-DC02Postboot) {
        Write-Skip "DC02 already post-configured"
        $Script:SkippedSteps += "DC02 postboot"
        return
    }
    $env:DC_WINRM_PASSWORD = $AdminPass
    vagrant provision dc02 --provision-with postboot 2>&1 | Out-Null
    $Script:ExecutedSteps += "DC02 postboot"
}

function Step-DC03Postboot {
    if (-not (Test-VMSelected dc03)) { $Script:SkippedSteps += "DC03 postboot"; return }
    Write-Step "[7b/14] DC03 post-promotion config..."
    if (Test-DC03Postboot) {
        Write-Skip "DC03 already post-configured"
        $Script:SkippedSteps += "DC03 postboot"
        return
    }
    # Child DC keeps the local Administrator password 'vagrant' through promotion
    # until dc03_postboot.ps1 resets it; try vagrant first, then the admin pass.
    $env:DC_WINRM_PASSWORD = "vagrant"
    vagrant provision dc03 --provision-with postboot 2>&1 | Out-Null
    if (-not (Test-DC03Postboot)) {
        Write-Info "Trying postboot with Admin password..."
        $env:DC_WINRM_PASSWORD = $AdminPass
        vagrant provision dc03 --provision-with postboot 2>&1 | Out-Null
    }
    $Script:ExecutedSteps += "DC03 postboot"
}

function Step-MemberProvisioning {
    Write-Step "[8/14] Member provisioning (SRV01 services, WS01/WS02 misconfig - parallel)..."
    $jobs = @()

    if (Test-VMSelected srv01 -and -not $SkipServices) {
        if (Test-SRV01Services) {
            Write-Skip "SRV01 services already configured"
            $Script:SkippedSteps += "SRV01 services"
        } else {
            Write-Info "Starting SRV01 services..."
            $jobs += Start-Job -Name "srv01-svc" -ScriptBlock {
                vagrant provision srv01 --provision-with services 2>&1 | Out-Null
            }
        }
    } else {
        Write-Skip "SRV01 services"
        $Script:SkippedSteps += "SRV01 services"
    }

    if (Test-VMSelected ws01 -and -not $SkipMisconfig) {
        if (Test-WS01Misconfig) {
            Write-Skip "WS01 already misconfigured"
            $Script:SkippedSteps += "WS01 misconfig"
        } else {
            Write-Info "Starting WS01 misconfig..."
            $jobs += Start-Job -Name "ws01-mis" -ScriptBlock {
                vagrant provision ws01 --provision-with misconfig 2>&1 | Out-Null
            }
        }
    } else {
        Write-Skip "WS01 misconfig"
        $Script:SkippedSteps += "WS01 misconfig"
    }

    if (Test-VMSelected ws02 -and -not $SkipMisconfig) {
        if (Test-WS02Misconfig) {
            Write-Skip "WS02 already misconfigured"
            $Script:SkippedSteps += "WS02 misconfig"
        } else {
            Write-Info "Starting WS02 misconfig..."
            $jobs += Start-Job -Name "ws02-mis" -ScriptBlock {
                vagrant provision ws02 --provision-with misconfig 2>&1 | Out-Null
            }
        }
    } else {
        Write-Skip "WS02 misconfig"
        $Script:SkippedSteps += "WS02 misconfig"
    }

    foreach ($job in $jobs) {
        Wait-Job $job | Out-Null
        Receive-Job $job | Out-Null
        Remove-Job $job
    }
    if ("SRV01 services" -notin $SkippedSteps) { $Script:ExecutedSteps += "SRV01 services" }
    if ("WS01 misconfig" -notin $SkippedSteps) { $Script:ExecutedSteps += "WS01 misconfig" }
    if ("WS02 misconfig" -notin $SkippedSteps) { $Script:ExecutedSteps += "WS02 misconfig" }
}

function Step-DC01ObjectsFinal {
    Write-Step "[11/14] DC01 AD objects (final pass)..."
    if (Test-DC01Objects) {
        Write-Skip "AD objects final pass already done"
        $Script:SkippedSteps += "DC01 objects (final)"
        return
    }
    $exitCode = Invoke-Vagrant -Arguments @("provision","dc01","--provision-with","objects")
    if ($exitCode -ne 0) { Write-Err "final objects failed"; exit 1 }
    $Script:ExecutedSteps += "DC01 objects (final)"
}

function Step-Hardening {
    if ($SkipHardening) {
        Write-Skip "Hardening"
        $Script:SkippedSteps += "Harden"
        return
    }
    Write-Step "[12/14] Hardening - removing default vagrant credentials..."

    $allHardened = $true
    foreach ($vm in $AllWindowsVMs) {
        if (-not (Test-VMSelected $vm)) { continue }
        if (-not (Test-Hardened $vm)) {
            $allHardened = $false
            break
        }
    }
    if ($allHardened) {
        Write-Skip "Already hardened"
        $Script:SkippedSteps += "Harden"
        return
    }

    $jobs = @()
    foreach ($vm in $AllWindowsVMs) {
        if (-not (Test-VMSelected $vm)) { continue }
        Write-Info "Hardening $vm..."
        $jobs += Start-Job -Name "harden-$vm" -ScriptBlock {
            param($vmName)
            vagrant provision $vmName --provision-with harden 2>&1 | Out-Null
        } -ArgumentList $vm
    }

    $failures = 0
    foreach ($job in $jobs) {
        Wait-Job $job | Out-Null
        $result = Receive-Job $job
        if ($LASTEXITCODE -ne 0) { $failures++ }
        Remove-Job $job
    }
    if ($failures -gt 0) {
        Write-Warn "Hardening failed on $failures VM(s)"
    } else {
        Write-OK "Hardening complete"
    }
    $Script:ExecutedSteps += "Harden"
}

# ── Step 13: Seal network (opt-in) ──
# Removes nic1 (VirtualBox NAT, 10.0.2.x) from each selected VM so every machine
# is left with a single internal IP on the SECSCOPE.CORP NAT network
# (192.168.200.x). This permanently eliminates the NAT-leak class of DNS bugs.
#
# WARNING: this severs ALL Vagrant management (WinRM/SSH) and RDP port-forwards,
# which ride nic1. It is therefore the LAST step, after hardening (the final
# comms operation). Internet still works via the NAT Network on nic2. Access
# afterwards is via the VirtualBox console or an in-network host (e.g. Kali .99).
# Reversible only by re-adding nic1: VBoxManage modifyvm <name> --nic1 nat.
function Step-SealNetwork {
    if (-not $EffectiveSeal) {
        $Script:SkippedSteps += "Seal network"
        return
    }
    # Sealing severs all Vagrant/WinRM/RDP management. On a scoped run (a partial
    # -VMs subset) that would cut management mid-workflow, so auto-seal is limited
    # to FULL builds. A partial run only seals when -SealNetwork was passed.
    if ($VMs -and -not $SealExplicit) {
        Write-Skip "Seal network (scoped run; pass -SealNetwork to force, -NoSeal to silence)"
        $Script:SkippedSteps += "Seal network"
        return
    }
    Write-Step "[13/14] Sealing network - removing NAT adapter (single IP per VM)..."
    Write-Warn "This removes Vagrant/RDP access. Machines will be reachable only via the"
    Write-Warn "VirtualBox console or an in-network host (Kali .99) after this step."

    $sealed = 0
    $sealFailures = 0
    foreach ($vm in $AllVMs) {
        if (-not (Test-VMSelected $vm)) { continue }
        if ($vm -eq "lin01" -and $SkipLinux) { continue }

        $vboxName = "$($vm.ToUpper()).SECSCOPE.CORP"

        # Last-chance verification: confirm the internal 192.168.200.x IP is present
        # before we cut management off. Best-effort (comms are about to die anyway).
        if ($vm -ne "lin01") {
            $ipcheck = vagrant winrm $vm -c "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { `$_.IPAddress -like '192.168.200.*' }).IPAddress" 2>&1
            if ($ipcheck -match "192\.168\.200\.") {
                Write-OK "$vm internal IP present"
            } else {
                Write-Warn "$vm internal 192.168.200.x IP not confirmed - sealing anyway"
            }
        }

        Write-Info "Halting $vm..."
        vagrant halt $vm 2>&1 | Out-Null

        Write-Info "Removing nic1 (NAT) from $vboxName..."
        VBoxManage modifyvm $vboxName --nic1 none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-OK "$vm nic1 removed - now single-homed on SECSCOPE.CORP"
        } else {
            Write-Warn "Could not modify $vboxName (name mismatch or VM missing)"
            $sealFailures++
            continue
        }

        Write-Info "Booting $vm headless..."
        VBoxManage startvm $vboxName --type headless 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not start $vboxName - start it manually from VirtualBox"
        }
        $sealed++
    }

    if ($sealFailures -gt 0) {
        Write-Warn "Network seal completed with $sealFailures issue(s); $sealed VM(s) sealed"
    } else {
        Write-OK "Network seal complete - $sealed VM(s) single-homed on SECSCOPE.CORP"
    }
    $Script:ExecutedSteps += "Seal network"
}

# ── Deploy orchestrator ──────────────────────────────────────────────────

function Invoke-Deploy {
    Write-Host "╔══════════════════════════════════════════╗"
    Write-Host "║  Active Directory Alligator Labs - Setup ║"
    Write-Host "╚══════════════════════════════════════════╝"

    Invoke-Preflight

    Step-DC01Base
    Step-DC01Postboot
    Step-DC01DNS
    Step-DC01ObjectsBase

    Step-DC01AVUpdateGPO

    if ($DC01Only) {
        Write-Host ""
        Write-Info "--dc01-only set - stopping after DC01 build"
        $Script:SkippedSteps += @("Sysprep","DC02 join","DC03 join","DC02 postboot","DC03 postboot","Member joins","SRV01 services","WS01 misconfig","WS02 misconfig","DC01 objects (final)","Harden","Seal network")
        $elapsed = (Get-Date) - $StartTime
        Write-Host "`nDC01 Build Complete in $([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
        exit 0
    }

    Step-BootRemaining
    Step-Sysprep
    Step-DCJoins
    $env:DC_WINRM_PASSWORD = $AdminPass
    Step-DC02Postboot
    Step-DC03Postboot
    Step-MemberJoin
    Step-MemberProvisioning
    Step-DC01ObjectsFinal
    Step-Hardening
    Step-SealNetwork

    # ── Summary ──
    $elapsed = (Get-Date) - $StartTime
    Write-Host "`n╔══════════════════════════════════════════╗"
    Write-Host "║              Setup Summary               ║"
    Write-Host "╚══════════════════════════════════════════╝"
    Write-Host ""
    Write-Host "  Total time: $([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
    Write-Host ""
    Write-Host "  Steps executed:"
    if ($ExecutedSteps.Count -eq 0) {
        Write-Host "    (none)"
    } else {
        foreach ($step in $ExecutedSteps) { Write-Host "    - $step" }
    }
    Write-Host ""
    Write-Host "  Steps skipped:"
    if ($SkippedSteps.Count -eq 0) {
        Write-Host "    (none)"
    } else {
        foreach ($step in $SkippedSteps) { Write-Host "    - $step" }
    }
    Write-Host ""
    Write-Host "Lab fully built and ready."
}

# ── Help ─────────────────────────────────────────────────────────────────

function Show-Help {
    Write-Host "╔══════════════════════════════════════════╗"
    Write-Host "║  Active Directory Alligator Labs - Setup ║"
    Write-Host "╚══════════════════════════════════════════╝"
    Write-Host ""
    Write-Host "USAGE:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File setup.ps1 [SUBCOMMAND] [OPTIONS]"
    Write-Host ""
    Write-Host "SUBCOMMANDS:"
    Write-Host "  deploy          Deploy lab from VMs (default)"
    Write-Host "  build-boxes     Build Packer boxes sequentially"
    Write-Host "  destroy         Destroy all VMs"
    Write-Host "  status          Show VM states"
    Write-Host "  help            Show this help"
    Write-Host ""
    Write-Host "DEPLOY OPTIONS:"
    Write-Host "  -VMs <list>          Comma-separated VM list (default: all)"
    Write-Host "  -DC01Only            Build DC01 only, then stop"
    Write-Host "  -SkipServices        Skip SRV01 services (IIS, SQL, ADCS)"
    Write-Host "  -SkipMisconfig       Skip WS01/WS02 misconfigurations"
    Write-Host "  -SkipHardening       Skip vagrant account hardening"
    Write-Host "  -SkipLinux           Skip LIN01"
    Write-Host "  -DisableAVUpdate     Create a domain GPO (linked at the root) that"
    Write-Host "                       disables Windows Defender AV and Windows Update"
    Write-Host "                       on all domain-joined machines. Default OFF."
    Write-Host "  -SealNetwork         Force network seal (default ON for full builds):"
    Write-Host "                       remove NAT nic1 so each VM has a single"
    Write-Host "                       192.168.200.x IP. Cuts Vagrant/RDP access - use"
    Write-Host "                       the VirtualBox console or Kali (.99) afterwards."
    Write-Host "                       Auto-skipped on scoped (-VMs) runs unless forced."
    Write-Host "  -NoSeal              Disable the network seal (keep NAT nic1 for"
    Write-Host "                       continued Vagrant/RDP management)."
    Write-Host ""
    Write-Host "BUILD-BOXES OPTIONS:"
    Write-Host "  -ServerOnly          Build only Windows Server 2022 box"
    Write-Host "  -WorkstationOnly     Build only Windows 10 box"
    Write-Host "  -DebianOnly          Build only Debian Bookworm box"
    Write-Host "  -SkipDebian          Skip Debian (build Windows boxes only)"
    Write-Host "  -NoVagrantAdd        Build boxes but don't add to Vagrant"
    Write-Host "  -ServerISO <path>    Custom Server 2022 ISO path"
    Write-Host "  -Win10ISO <path>     Custom Windows 10 ISO path"
    Write-Host "  -DebianISO <path>    Custom Debian ISO path"
    Write-Host ""
    Write-Host "OUTPUT OPTIONS:"
    Write-Host "  -Verbose             Show all provisioning output"
    Write-Host "  -Quiet               Minimal output"
    Write-Host "  -Debug               Show suppressed WinRM errors too"
    Write-Host "  -NoColor             Disable colored output (not applicable in PS)"
    Write-Host ""
    Write-Host "EXAMPLES:"
    Write-Host "  .\setup.ps1                            Full deploy"
    Write-Host "  .\setup.ps1 -NoSeal                    Full deploy, keep NAT nic1 (manageable)"
    Write-Host "  .\setup.ps1 deploy -VMs dc01,ws01      Deploy only DC01 and WS01"
    Write-Host "  .\setup.ps1 deploy -DC01Only           Deploy DC01 only"
    Write-Host "  .\setup.ps1 deploy -SkipMisconfig      Deploy without WS vulns"
    Write-Host "  .\setup.ps1 deploy -DisableAVUpdate    Deploy + GPO disabling AV/Updates"
    Write-Host "  .\setup.ps1 deploy -Verbose            Full output"
    Write-Host "  .\setup.ps1 build-boxes -ServerOnly    Build Server 2022 box only"
    Write-Host "  .\setup.ps1 build-boxes -DebianOnly    Build Debian box only"
    Write-Host "  .\setup.ps1 destroy                    Destroy everything"
    Write-Host "  .\setup.ps1 status                     Show VM states"
    Write-Host ""
    Write-Host "VM INVENTORY:"
    Write-Host "  DC01   192.168.200.10   Primary Domain Controller"
    Write-Host "  DC02   192.168.200.11   Secondary Domain Controller"
    Write-Host "  DC03   192.168.200.12   Subdomain Controller (it.secscope.corp)"
    Write-Host "  SRV01  192.168.200.20   MSSQL + IIS + ADCS"
    Write-Host "  WS01   192.168.200.30   Workstation 1"
    Write-Host "  WS02   192.168.200.31   Workstation 2"
    Write-Host "  LIN01  192.168.200.40   Linux Domain Member"
}

# ═══════════════════════════════════════════════════════════════════════════
# Entry point - dispatch
# ═══════════════════════════════════════════════════════════════════════════

if ($Help) { Show-Help; exit 0 }

switch ($Subcommand.ToLower()) {
    "deploy"      { Invoke-Deploy }
    "build-boxes" { Invoke-BuildBoxes }
    "destroy"     { Invoke-Destroy }
    "status"      { Invoke-Status }
    "help"        { Show-Help }
    default {
        Write-Host "Unknown subcommand: $Subcommand"
        Write-Host "Run '.\setup.ps1 help' for usage"
        exit 1
    }
}
