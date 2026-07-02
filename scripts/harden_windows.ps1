$ErrorActionPreference = "Continue"

Write-Host "[harden] Removing default vagrant credentials..."

# Disable vagrant local user account
try {
    Disable-LocalUser -Name "vagrant" -ErrorAction Stop
    Write-Host "[harden] vagrant account disabled"
} catch {
    Write-Host "[harden] vagrant account already disabled or not found"
}

# Remove vagrant from Administrators group
try {
    Remove-LocalGroupMember -Group "Administrators" -Member "vagrant" -ErrorAction Stop
    Write-Host "[harden] vagrant removed from Administrators"
} catch {
    Write-Host "[harden] vagrant already not in Administrators"
}

# Remove vagrant SSH authorized keys
try {
    $vagrantSSH = "C:\Users\vagrant\.ssh\authorized_keys"
    if (Test-Path $vagrantSSH) {
        Clear-Content $vagrantSSH
        Write-Host "[harden] vagrant SSH keys cleared"
    }
} catch {
    Write-Host "[harden] No SSH keys to clear"
}

# Disable WinRM basic auth (no longer needed after provisioning)
try {
    winrm set winrm/config/service/auth '@{Basic="false"}'
    Write-Host "[harden] WinRM basic auth disabled"
} catch {
    Write-Host "[harden] WinRM basic auth already disabled"
}

Write-Host "[harden] Done -- vagrant account disabled"
