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

    [switch]$ServerOnly,
    [switch]$WorkstationOnly,
    [switch]$NoVagrantAdd,
    [string]$ServerISO = "",
    [string]$Win10ISO = ""
)

$ErrorActionPreference = "Continue"

# ── Defaults ──────────────────────────────────────────────────────────────

$ScriptDir = $PSScriptRoot
$AdminPass = if ($env:ADMIN_PASS) { $env:ADMIN_PASS } else { "SecScope2024!" }
$Domain = "secscope.corp"
$env:DC_WINRM_PASSWORD = $AdminPass

$DefaultServerISO = Join-Path $ScriptDir "iso\SERVER_EVAL_x64FRE_en-us.iso"
$DefaultWin10ISO  = Join-Path $ScriptDir "iso\Win10_22H2_English_x64v1.iso"

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

function Test-DC01Objects {
    $result = vagrant winrm dc01 -c "Get-ADComputer WS01 -Properties msDS-AllowedToActOnBehalfOfOtherIdentity" 2>&1
    return ($result -match "WS01")
}

function Test-DC02Join {
    $result = vagrant winrm dc02 -c "Get-ADDomainController" 2>&1
    return ($result -match "DC02")
}

function Test-DC03Join {
    $result = vagrant winrm dc03 -c "Get-ADDomain" 2>&1
    return ($result -match "it")
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
    $result = vagrant winrm ws02 -c "Get-LocalUser localadmin" 2>&1
    return ($result -match "localadmin")
}

function Test-Hardened {
    param([string]$VMName)
    $result = vagrant winrm $VMName -c "Get-LocalUser vagrant | Select-Object Enabled" 2>&1
    return ($result -match "False")
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
    $SkipVagrant = $NoVagrantAdd

    $ServerISOPath = if ($ServerISO) { $ServerISO } else { $DefaultServerISO }
    $Win10ISOPath  = if ($Win10ISO)  { $Win10ISO }  else { $DefaultWin10ISO }

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
    Remove-Item -Recurse -Force "$env:USERPROFILE\VirtualBox VMs\packer-windows-server-2022" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "$env:USERPROFILE\VirtualBox VMs\packer-windows-10" -ErrorAction SilentlyContinue
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
    vagrant winrm dc01 -c @'
$zone = "secscope.corp"
Get-DnsServerResourceRecord -ZoneName $zone -RRType A -ErrorAction SilentlyContinue | ForEach-Object {
    $ip = $_.RecordData.IPv4Address.IPAddressToString
    if ($ip -like "10.0.2.*") {
        Write-Host "Removing: $($_.HostName) -> $ip"
        dnscmd localhost /RecordDelete $zone $($_.HostName) A $ip /f 2>&1 | Out-Null
    }
}
'@ 2>&1 | Out-Null
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

    if ($DC01Only) {
        Write-Host ""
        Write-Info "--dc01-only set - stopping after DC01 build"
        $Script:SkippedSteps += @("DC02 join","DC03 join","SRV01 services","WS01 misconfig","WS02 misconfig","DC01 objects (final)","Harden")
        $elapsed = (Get-Date) - $StartTime
        Write-Host "`nDC01 Build Complete in $([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
        exit 0
    }

    Step-BootRemaining
    Step-DCJoins
    Step-MemberProvisioning
    Step-DC01ObjectsFinal
    Step-Hardening

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
    Write-Host ""
    Write-Host "BUILD-BOXES OPTIONS:"
    Write-Host "  -ServerOnly          Build only Windows Server 2022 box"
    Write-Host "  -WorkstationOnly     Build only Windows 10 box"
    Write-Host "  -NoVagrantAdd        Build boxes but don't add to Vagrant"
    Write-Host "  -ServerISO <path>    Custom Server 2022 ISO path"
    Write-Host "  -Win10ISO <path>     Custom Windows 10 ISO path"
    Write-Host ""
    Write-Host "OUTPUT OPTIONS:"
    Write-Host "  -Verbose             Show all provisioning output"
    Write-Host "  -Quiet               Minimal output"
    Write-Host "  -Debug               Show suppressed WinRM errors too"
    Write-Host "  -NoColor             Disable colored output (not applicable in PS)"
    Write-Host ""
    Write-Host "EXAMPLES:"
    Write-Host "  .\setup.ps1                            Full deploy"
    Write-Host "  .\setup.ps1 deploy -VMs dc01,ws01      Deploy only DC01 and WS01"
    Write-Host "  .\setup.ps1 deploy -DC01Only           Deploy DC01 only"
    Write-Host "  .\setup.ps1 deploy -SkipMisconfig      Deploy without WS vulns"
    Write-Host "  .\setup.ps1 deploy -Verbose            Full output"
    Write-Host "  .\setup.ps1 build-boxes -ServerOnly    Build Server 2022 box only"
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
