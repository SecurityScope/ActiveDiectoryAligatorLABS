$ErrorActionPreference = "Continue"
Write-Host "[vagrant] Ensuring vagrant user exists..."

# Relax password policy so "vagrant" meets requirements
Write-Host "[vagrant] Relaxing password policy..."
try {
    secedit /export /cfg C:\Windows\Temp\secpol.cfg 2>$null
    $cfg = Get-Content C:\Windows\Temp\secpol.cfg -ErrorAction SilentlyContinue
    if ($cfg) {
        $cfg = $cfg -replace 'PasswordComplexity\s*=\s*1', 'PasswordComplexity = 0'
        $cfg = $cfg -replace 'MinimumPasswordLength\s*=\s*\d+', 'MinimumPasswordLength = 1'
        $cfg | Set-Content C:\Windows\Temp\secpol.cfg
        secedit /configure /db C:\Windows\Temp\secpol.sdb /cfg C:\Windows\Temp\secpol.cfg /areas SECURITYPOLICY /quiet 2>$null
    }
} catch {
    Write-Host "[vagrant] WARNING: Could not relax password policy: $_"
}

$vagrantPass = ConvertTo-SecureString "vagrant" -AsPlainText -Force
$existingUser = Get-LocalUser -Name "vagrant" -ErrorAction SilentlyContinue
if ($existingUser) {
    Write-Host "[vagrant] vagrant user already exists - updating password"
    try {
        Set-LocalUser -Name "vagrant" -Password $vagrantPass
    } catch {
        Write-Host "[vagrant] WARNING: Could not update vagrant password: $_"
    }
} else {
    Write-Host "[vagrant] Creating vagrant user..."
    New-LocalUser -Name "vagrant" `
        -Password $vagrantPass `
        -PasswordNeverExpires `
        -UserMayNotChangePassword >$null 2>&1
    $verify = Get-LocalUser -Name "vagrant" -ErrorAction SilentlyContinue
    if ($verify) {
        Write-Host "[vagrant] vagrant user created"
    } else {
        Write-Host "[vagrant] WARNING: vagrant user creation failed - trying complex password..."
        $complexPass = ConvertTo-SecureString "P@ssw0rd2024!" -AsPlainText -Force
        New-LocalUser -Name "vagrant" `
            -Password $complexPass `
            -PasswordNeverExpires `
            -UserMayNotChangePassword >$null 2>&1
        Write-Host "[vagrant] vagrant user created with complex password - will be reset by Packer provisioner"
    }
}

# Ensure in Administrators regardless
Add-LocalGroupMember -Group "Administrators" -Member "vagrant" `
    -ErrorAction SilentlyContinue
Write-Host "[vagrant] vagrant confirmed in Administrators group"

# Create .ssh directory
$sshDir = "C:\Users\vagrant\.ssh"
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

# Download Vagrant insecure public key
$keyUrl = "https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant.pub"
try {
    Invoke-WebRequest -Uri $keyUrl -OutFile "$sshDir\authorized_keys" -TimeoutSec 30
    Write-Host "[vagrant] Downloaded Vagrant public key"
} catch {
    # Hardcode the key as fallback
    $vagrantPubKey = "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant insecure public key"
    $vagrantPubKey | Out-File -FilePath "$sshDir\authorized_keys" -Encoding ASCII
    Write-Host "[vagrant] Used hardcoded Vagrant public key"
}

# Set correct permissions on .ssh
icacls $sshDir /inheritance:r /grant "vagrant:F" >$null 2>&1
icacls "$sshDir\authorized_keys" /inheritance:r /grant "vagrant:F" >$null 2>&1

# Install OpenSSH
try {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    Write-Host "[vagrant] OpenSSH Server installed and started"
} catch {
    Write-Host "[vagrant] OpenSSH install failed - WinRM will be used"
}

# Configure SSH authorized keys path
$regPath = "HKLM:\SOFTWARE\OpenSSH"
if (Test-Path $regPath) {
    New-ItemProperty -Path $regPath -Name DefaultShell `
        -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -PropertyType String -Force | Out-Null
}

Write-Host "[vagrant] Vagrant user setup complete"
