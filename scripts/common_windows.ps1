$ErrorActionPreference = "Continue"

Write-Host "[common] Starting base Windows configuration..."

Write-Host "[common] Setting PowerShell execution policy..."
Set-ExecutionPolicy Unrestricted -Scope Process -Force *>$null

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

Write-Host "[common] Done"
