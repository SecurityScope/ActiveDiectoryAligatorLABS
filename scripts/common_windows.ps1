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

Write-Host "[common] Setting network profiles to Private..."
$profileSet = $false
for ($i = 1; $i -le 8; $i++) {
    try {
        Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction Stop
        Write-Host "[common] Network profiles set to Private"
        $profileSet = $true
        break
    } catch {
        Write-Host "[common] Waiting for network profiles... attempt $i/8"
        Start-Sleep 5
    }
}
if (-not $profileSet) {
    Write-Host "[common] WARNING: Could not set network profiles to Private"
}

Write-Host "[common] Enabling WinRM..."
winrm quickconfig -q
Enable-PSRemoting -Force

Write-Host "[common] Configuring WinRM for unencrypted and basic auth..."
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'

Write-Host "[common] Disabling IPv6..."
Get-NetAdapter | ForEach-Object {
    Disable-NetAdapterBinding -InterfaceAlias $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
}

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
#  - Restart-NetAdapter is NOT a strong enough NLA re-classification trigger
#    here; a full Disable/Enable cycle is required to flip the category. WinRM
#    rides the NAT adapter, so bouncing the internal adapter is session-safe.
if ($env:SKIP_NLA_FIX -eq "true") {
    Write-Host "[common] SKIP_NLA_FIX set - skipping NLA-Recheck task registration"
} elseif (Get-ScheduledTask -TaskName "NLA-Recheck" -ErrorAction SilentlyContinue) {
    Write-Host "[common] NLA-Recheck scheduled task already present"
} else {
    Write-Host "[common] Registering NLA-Recheck startup task..."
    $nlaDir    = "C:\ProgramData\SecScope"
    $nlaScript = Join-Path $nlaDir "nla_recheck.ps1"
    New-Item -ItemType Directory -Path $nlaDir -Force -ErrorAction SilentlyContinue | Out-Null
    $nlaBody = @'
try { Restart-Service NlaSvc -Force -ErrorAction Stop } catch {}
Start-Sleep 5
$internal = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Where-Object {
    (Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -like "192.168.*"
} | Select-Object -First 1
if ($internal) {
    $cat = (Get-NetConnectionProfile -InterfaceAlias $internal.Name -ErrorAction SilentlyContinue).NetworkCategory
    if ($cat -ne "DomainAuthenticated") {
        Disable-NetAdapter -Name $internal.Name -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 5
        Enable-NetAdapter -Name $internal.Name -Confirm:$false -ErrorAction SilentlyContinue
    }
}
'@
    Set-Content -Path $nlaScript -Value $nlaBody -Encoding UTF8
    $tr = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $nlaScript"
    schtasks.exe /create /tn "NLA-Recheck" /ru "SYSTEM" /sc ONSTART /delay 0000:30 /rl HIGHEST /f /tr $tr 2>&1 | Out-Null
    if (Get-ScheduledTask -TaskName "NLA-Recheck" -ErrorAction SilentlyContinue) {
        Write-Host "[common] NLA-Recheck task registered"
    } else {
        Write-Host "[common] WARNING: NLA-Recheck task registration failed"
    }
}

# ── NLA fix verification block ──
Get-Service NlaSvc,Netlogon -ErrorAction SilentlyContinue | Select-Object Name,StartType,Status | Format-Table -Auto | Out-String | Write-Host
Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object InterfaceAlias,NetworkCategory | Format-Table -Auto | Out-String | Write-Host

Write-Host "[common] Done"
