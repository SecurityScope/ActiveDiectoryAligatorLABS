$ErrorActionPreference = "Continue"

Write-Host "[harden] Removing default vagrant credentials..."

# On promoted DCs the local SAM is gone (only domain accounts remain), so the
# local "vagrant" user no longer exists there - every step below is a safe
# no-op in that case. On members/workstations this fully deletes the account.

$vagrantUser = Get-LocalUser -Name "vagrant" -ErrorAction SilentlyContinue

if ($vagrantUser) {
    # Remove vagrant from Administrators (ignore if not a member)
    try {
        Remove-LocalGroupMember -Group "Administrators" -Member "vagrant" -ErrorAction Stop
        Write-Host "[harden] vagrant removed from Administrators"
    } catch {
        Write-Host "[harden] vagrant already not in Administrators"
    }

    # Delete the local user account
    try {
        Remove-LocalUser -Name "vagrant" -ErrorAction Stop
        Write-Host "[harden] vagrant local user deleted"
    } catch {
        Write-Host "[harden] Could not delete vagrant user: $_"
    }
} else {
    Write-Host "[harden] vagrant local user not present (already removed or DC) - skipping user deletion"
}

# Delete the vagrant user profile (registry profile entry + C:\Users\vagrant).
# Using Win32_UserProfile removes the ProfileList registry key too, so the
# folder is not flagged as orphaned/corrupt afterwards.
try {
    $profile = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPath -eq "C:\Users\vagrant" }
    if ($profile) {
        Remove-CimInstance -InputObject $profile -ErrorAction Stop
        Write-Host "[harden] vagrant profile removed (Win32_UserProfile)"
    }
} catch {
    Write-Host "[harden] Win32_UserProfile removal failed: $_"
}
# Belt-and-suspenders: remove any leftover profile directory.
try {
    if (Test-Path "C:\Users\vagrant") {
        Remove-Item -Path "C:\Users\vagrant" -Recurse -Force -ErrorAction Stop
        Write-Host "[harden] C:\Users\vagrant directory removed"
    }
} catch {
    Write-Host "[harden] Could not remove C:\Users\vagrant (may be in use): $_"
}

# Clear autologon ONLY if it points at vagrant. ws01/ws02 deliberately
# autologon as the domain user "anakin" (ws0*_misconfig.ps1) - leave those.
try {
    $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $defUser = (Get-ItemProperty -Path $winlogon -Name DefaultUserName -ErrorAction SilentlyContinue).DefaultUserName
    if ($defUser -eq "vagrant") {
        Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value "0" -Type String -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $winlogon -Name DefaultUserName  -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $winlogon -Name DefaultPassword  -ErrorAction SilentlyContinue
        Write-Host "[harden] Autologon disabled (was set to vagrant)"
    } else {
        Write-Host "[harden] Autologon not set to vagrant (DefaultUserName='$defUser') - left untouched"
    }
} catch {
    Write-Host "[harden] Autologon check skipped: $_"
}

# Disable WinRM basic auth (no longer needed after provisioning)
try {
    winrm set winrm/config/service/auth '@{Basic="false"}'
    Write-Host "[harden] WinRM basic auth disabled"
} catch {
    Write-Host "[harden] WinRM basic auth already disabled"
}

Write-Host "[harden] Done -- vagrant account deleted"
