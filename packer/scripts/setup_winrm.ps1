$ErrorActionPreference = "Continue"
Write-Host "[winrm] Configuring WinRM..."

# Wait for network stack to be fully ready
Write-Host "[winrm] Waiting for network..."
$maxAttempts = 60
for ($i = 0; $i -lt $maxAttempts; $i++) {
    $nic = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -notlike "*Hyper-V*" } | Select-Object -First 1
    if ($nic) { break }
    Write-Host "[winrm] No active network adapter yet, retrying... ($($i+1)/$maxAttempts)"
    Start-Sleep -Seconds 10
}
if (-not $nic) {
    Write-Host "[winrm] WARNING: No network adapter after $maxAttempts attempts"
}

# Kill firewall completely before WinRM config
Write-Host "[winrm] Disabling firewall..."
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
netsh advfirewall set allprofiles state off
netsh advfirewall firewall add rule name="WinRM HTTP" dir=in action=allow protocol=TCP localport=5985

# Set network profile to Private
$maxProfileAttempts = 10
for ($i = 0; $i -lt $maxProfileAttempts; $i++) {
    try {
        Get-NetConnectionProfile -ErrorAction Stop | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction Stop
        Write-Host "[winrm] Network profile set to Private"
        break
    } catch {
        Write-Host "[winrm] Waiting for network profile... ($($i+1)/$maxProfileAttempts)"
        Start-Sleep -Seconds 6
    }
}

# Disable UAC
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name EnableLUA -Value 0 -Force

# Step 1: Create WinRM listener FIRST using Enable-PSRemoting
Write-Host "[winrm] Creating WinRM listener..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck
if ($LASTEXITCODE -ne 0) {
    Write-Host "[winrm] Enable-PSRemoting returned non-zero, trying quickconfig..."
    winrm quickconfig -q
}

# Step 2: Verify listener exists
$listenerCheck = winrm enumerate winrm/config/listener 2>&1
if ($listenerCheck -match "Port = 5985") {
    Write-Host "[winrm] Listener found on port 5985"
} else {
    Write-Host "[winrm] No listener on 5985 - creating manually..."
    winrm create winrm/config/Listener?Address=*+Transport=HTTP
    Start-Sleep -Seconds 3
    $listenerCheck = winrm enumerate winrm/config/listener 2>&1
    if ($listenerCheck -match "Port = 5985") {
        Write-Host "[winrm] Listener created on port 5985"
    } else {
        Write-Host "[winrm] WARNING: Could not verify listener"
    }
}

# Step 3: NOW configure WinRM auth (listener must exist first)
Write-Host "[winrm] Configuring WinRM auth..."
winrm set winrm/config '@{MaxTimeoutms="1800000"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/client '@{AllowUnencrypted="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'

# Also set via registry for persistence across service restarts
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Service" /v allow_unencrypted /t REG_DWORD /d 1 /f 2>$null
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Client" /v allow_unencrypted /t REG_DWORD /d 1 /f 2>$null
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Service" /v auth_basic /t REG_DWORD /d 1 /f 2>$null

# Step 4: Configure listener port (only if listener exists)
winrm set winrm/config/listener?Address=*+Transport=HTTP '@{Port="5985"}'

# Step 5: Restart WinRM ONCE to apply listener/port changes.
# IMPORTANT: AllowUnencrypted/Basic auth must be (re)applied AFTER this,
# and WinRM must NOT be restarted again afterward - restarting the service
# re-reads config and has been observed to drop AllowUnencrypted=true.
Write-Host "[winrm] Restarting WinRM service (listener/port changes)..."
Restart-Service WinRM -Force
Set-Service WinRM -StartupType Automatic
Start-Sleep -Seconds 5

# Step 6: (Re)apply auth settings AFTER the restart above, and do not
# restart WinRM again after this point.
Write-Host "[winrm] Applying final WinRM auth settings (post-restart)..."
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/client '@{AllowUnencrypted="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Service" /v allow_unencrypted /t REG_DWORD /d 1 /f 2>$null
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Service" /v auth_basic /t REG_DWORD /d 1 /f 2>$null

# Step 7: Verify WinRM is working
Write-Host "[winrm] Verifying WinRM connectivity..."
$verifyResult = winrm id -remote:localhost 2>&1
if ($verifyResult -match "IdentifyResponse") {
    Write-Host "[winrm] WinRM verification PASSED"
} else {
    Write-Host "[winrm] WARNING: WinRM local test output:"
    Write-Host $verifyResult
}

# Step 8: Final verification (no restart - just re-set if something looks off)
Write-Host "[winrm] Final verification..."
$svcCheck = winrm get winrm/config/service 2>&1
$basicOK = $svcCheck -match "Basic = true"
$unencOK = $svcCheck -match "AllowUnencrypted = true"

if ($basicOK -and $unencOK) {
    Write-Host "[winrm] Basic auth and AllowUnencrypted confirmed"
} else {
    Write-Host "[winrm] Re-applying settings (no service restart)..."
    if (-not $basicOK) {
        winrm set winrm/config/service/auth '@{Basic="true"}'
    }
    if (-not $unencOK) {
        winrm set winrm/config/service '@{AllowUnencrypted="true"}'
    }
    Start-Sleep -Seconds 2
    $svcCheck2 = winrm get winrm/config/service 2>&1
    if ($svcCheck2 -match "Basic = true" -and $svcCheck2 -match "AllowUnencrypted = true") {
        Write-Host "[winrm] Settings confirmed"
    } else {
        Write-Host "[winrm] WARNING: Settings may not be fully applied"
        Write-Host $svcCheck2
    }
}

Write-Host "[winrm] WinRM configured successfully"
