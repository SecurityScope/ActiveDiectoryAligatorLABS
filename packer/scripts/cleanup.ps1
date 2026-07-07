$ErrorActionPreference = "Continue"
Write-Host "[cleanup] Starting disk cleanup..."

# Clean Windows Update cache
Remove-Item -Recurse -Force "C:\Windows\SoftwareDistribution\Download\*" `
    -ErrorAction SilentlyContinue
Write-Host "[cleanup] Windows Update cache cleared"

# Clean temp files (skip Packer's own control/env-var files it still needs
# after this script returns)
Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue
Get-ChildItem "C:\Windows\Temp\*" -Exclude "packer-*" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "[cleanup] Temp files cleared"

# Clean Windows logs
try {
    $logs = wevtutil el
    foreach ($log in $logs) {
        wevtutil cl "$log" 2>$null
    }
    Write-Host "[cleanup] Event logs cleared"
} catch {}

Write-Host "[cleanup] Zeroing free space skipped (speed optimization)"

# Autounattend.xml/sysprep_sid.ps1 set AutoAdminLogon=1 with LogonCount=99 so
# Packer/sysprep can get through OOBE unattended. If left in place, every VM
# built from this box (WS01, WS02, DCs, SRV01) boots straight to an
# interactive desktop as the local built-in Administrator for ~99 reboots -
# not one of the lab's documented intentional vulnerabilities, just leftover
# build plumbing. Clear it here, before the box is captured, so deployed VMs
# require an explicit logon. WS01/WS02 re-enable AutoLogon post-domain-join
# under the intended lab account (anakin) in ws01_misconfig.ps1/ws02_misconfig.ps1.
Write-Host "[cleanup] Disabling AutoAdminLogon..."
$winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value "0" -Type String -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $winlogon -Name DefaultPassword -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $winlogon -Name AutoLogonCount -Force -ErrorAction SilentlyContinue
Write-Host "[cleanup] AutoAdminLogon disabled"

# Disable paging file last (after all installers are done)
Write-Host "[cleanup] Disabling paging file..."
try {
    $cs = Get-WmiObject Win32_ComputerSystem
    $cs.AutomaticManagedPagefile = $false
    $cs.Put() | Out-Null
    $pf = Get-WmiObject Win32_PageFileSetting
    if ($pf) { $pf.Delete() | Out-Null }
    Write-Host "[cleanup] Paging file disabled"
} catch {
    Write-Host "[cleanup] Could not disable paging file: $_"
}

Write-Host "[cleanup] Cleanup complete"
