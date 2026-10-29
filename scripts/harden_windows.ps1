$ErrorActionPreference = "Continue"

Write-Host "[harden] Removing default vagrant credentials..."

# On a promoted DC the box's local 'vagrant' account is migrated into the
# domain (CN=vagrant,CN=Users,DC=...), NOT a local account anymore. Remove it
# with the AD cmdlets there; members/workstations keep the local-account path.
$isDc = ((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).DomainRole -ge 4)

if ($isDc) {
    # Use native net.exe on DCs: the ActiveDirectory module's default server
    # discovery fails on the child DC ("Server instance not found"), which made
    # Get-ADUser look like "user absent" and let harden silently pass. `net user`
    # targets the DC's SAM/AD directly, and its exit code is reliable.
    & net user vagrant > $null 2>&1
    if ($LASTEXITCODE -eq 0) {
        # Drop the Administrators membership first; the account is adminCount=1
        # (AdminSDHolder-protected) and may otherwise resist deletion.
        & net localgroup "Administrators" vagrant /delete > $null 2>&1
        & net user vagrant /delete > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[harden] vagrant domain user deleted"
        } else {
            Write-Host "[harden] Could not delete vagrant domain user (net user rc=$LASTEXITCODE)"
        }
    } else {
        Write-Host "[harden] vagrant domain user not present"
    }
} else {
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
        Write-Host "[harden] vagrant local user not present"
    }
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
# Belt-and-suspenders: take ownership first (the vagrant profile's .ssh ACL can
# deny Administrators), then remove any leftover profile directory.
try {
    if (Test-Path "C:\Users\vagrant") {
        & takeown /F "C:\Users\vagrant" /R /D Y > $null 2>&1
        & icacls "C:\Users\vagrant" /grant "Administrators:F" /T /C > $null 2>&1
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

# Final verification: fail the provisioner if a usable vagrant account survived,
# so 'finalize' does not silently seal an unhardened VM.
if ($isDc) {
    & net user vagrant > $null 2>&1
    $remaining = ($LASTEXITCODE -eq 0)
} else {
    $remaining = [bool](Get-LocalUser -Name "vagrant" -ErrorAction SilentlyContinue)
}
if ($remaining) {
    Write-Host "[harden] ERROR: vagrant account still present"
    exit 1
}
Write-Host "[harden] Done -- vagrant account removed"
