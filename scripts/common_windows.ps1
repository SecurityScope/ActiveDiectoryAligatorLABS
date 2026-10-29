$ErrorActionPreference = "Continue"

Write-Host "[common] Starting base Windows configuration..."

Write-Host "[common] Setting PowerShell execution policy..."
Set-ExecutionPolicy Unrestricted -Scope Process -Force *>$null
Set-ExecutionPolicy Unrestricted -Scope LocalMachine -Force *>$null

Write-Host "[common] Disabling Windows Automatic Repair / WinRE on boot failure..."
# This build reboots a VM many times (sysprep, base, promotion, join). Whenever
# `vagrant reload` has to hard power-off a guest that is still busy, Windows
# otherwise boots into the Automatic Repair / Recovery environment ("It looks
# like Windows didn't load correctly") and waits for someone to click "Restart
# my PC" - which never happens headless, so the next boot times out and the
# build fails. Tell the boot manager to ignore boot failures and never auto-
# launch WinRE, so every reboot goes straight back into Windows.
bcdedit /set "{default}" bootstatuspolicy ignoreallfailures *>$null
bcdedit /set "{default}" recoveryenabled No *>$null
bcdedit /set "{current}" bootstatuspolicy ignoreallfailures *>$null
bcdedit /set "{current}" recoveryenabled No *>$null

Write-Host "[common] Disabling Windows Firewall..."
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

Write-Host "[common] Disabling Windows Defender real-time protection..."
Set-MpPreference -DisableRealtimeMonitoring $true

Write-Host "[common] Disabling Windows Update..."
Set-Service wuauserv -StartupType Disabled
Stop-Service wuauserv -ErrorAction SilentlyContinue

Write-Host "[common] Network profile changes deferred to dc_base/NLA-Recheck..."
# Do NOT call Set-NetConnectionProfile here. At this point the internal
# natnetwork adapter has no DHCP address (the SECSCOPE.CORP network has DHCP
# off), so it reports IPv4Connectivity=NoTraffic. Setting its category blocks
# inside NLA/WMI for minutes per attempt - the old "Waiting for network
# profiles... attempt 3/8" stall. dc_base.ps1 sets the static IP and the
# NLA-Recheck startup task reclassifies the adapter after base-reload.

Write-Host "[common] Enabling WinRM..."
winrm quickconfig -q
Enable-PSRemoting -Force

Write-Host "[common] Configuring WinRM for unencrypted and basic auth..."
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'

Write-Host "[common] Disabling IPv6 (registry; applied at next boot)..."
# Do NOT unbind ms_tcpip6 from the live NAT adapter. Disable-NetAdapterBinding
# resets TCP on that adapter and drops the WinRM session mid-provision (seen on
# dc03). DisabledComponents=0xFF disables IPv6 stack-wide on the next boot; the
# base-reload provisioner reboots right after common, before any AD/DNS work.
$tcpip6 = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
if (-not (Test-Path $tcpip6)) { New-Item -Path $tcpip6 -Force | Out-Null }
Set-ItemProperty -Path $tcpip6 -Name 'DisabledComponents' -Value 0xFF -Type DWord -Force

Write-Host "[common] Setting timezone to UTC..."
try {
    Set-TimeZone -Id "UTC" -ErrorAction Stop
} catch {
    try { Set-TimeZone -Name "UTC" -ErrorAction Stop } catch {}
}

Write-Host "[common] Ensuring AD Web Services available..."
Set-Service ADWS -StartupType Automatic -ErrorAction SilentlyContinue

# ── Durable NLA domain-detection fix ────────────────────────────────────────
# NLA classifies the network at NIC link-up, before Netlogon/DNS can verify
# domain trust, then caches "Private"/"Public" and never retries on its own.
# The provisioning scripts bounce the internal adapter once, but that does NOT
# survive later reboots. Register an AtStartup task that re-triggers NLA ~30s
# after boot so the internal (192.168.x) profile flips to DomainAuthenticated
# without any manual adapter toggling, on every reboot.
#
# Notes learned the hard way:
#  - Register-ScheduledTask over WinRM can create an orphaned task (task file
#    on disk but no TaskCache registry entry, wrong LogonType) that vanishes on
#    reboot. schtasks.exe /create is reliable across the WinRM channel.
#  - schtasks /tr is capped at 261 chars, so the logic lives in a helper file.
#  - The task is ALWAYS rewritten/re-registered (not only when missing) so
#    existing VMs pick up fixes to the NLA logic on the next provisioner run.
if ($env:SKIP_NLA_FIX -eq "true") {
    Write-Host "[common] SKIP_NLA_FIX set - skipping NLA-Recheck task registration"
} else {
    Write-Host "[common] Writing + registering NLA-Recheck startup task..."
    $nlaDir    = "C:\ProgramData\SecScope"
    $nlaScript = Join-Path $nlaDir "nla_recheck.ps1"
    New-Item -ItemType Directory -Path $nlaDir -Force -ErrorAction SilentlyContinue | Out-Null
    Copy-Item -Path "C:\vagrant\scripts\nla_recheck.ps1" -Destination $nlaScript -Force
    $tr = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $nlaScript"
    schtasks.exe /create /tn "NLA-Recheck" /ru "SYSTEM" /sc ONSTART /delay 0000:30 /rl HIGHEST /f /tr $tr 2>&1 | Out-Null
    if (Get-ScheduledTask -TaskName "NLA-Recheck" -ErrorAction SilentlyContinue) {
        Write-Host "[common] NLA-Recheck task registered/refreshed"
    } else {
        Write-Host "[common] WARNING: NLA-Recheck task registration failed"
    }
}

# ── NLA fix verification block ──
Get-Service NlaSvc,Netlogon -ErrorAction SilentlyContinue | Select-Object Name,StartType,Status | Format-Table -Auto | Out-String | Write-Host
Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object InterfaceAlias,NetworkCategory | Format-Table -Auto | Out-String | Write-Host

Write-Host "[common] Done"
