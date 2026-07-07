$ErrorActionPreference = "Continue"

Write-Host "[ws02_misconfig] Configuring intentional vulnerabilities on WS02..."

Write-Host "[ws02_misconfig] Disabling SMB signing..."
Set-SmbServerConfiguration -RequireSecuritySignature $false -EnableSecuritySignature $false -Force
Set-SmbClientConfiguration -RequireSecuritySignature $false -Force
Write-Host "[ws02_misconfig] SMB signing disabled"

Write-Host "[ws02_misconfig] Enabling WDigest (plaintext creds in LSASS)..."
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest" -Name UseLogonCredential -Value 1 -Type DWORD -Force
Write-Host "[ws02_misconfig] WDigest enabled"

Write-Host "[ws02_misconfig] Adding anakin to local Administrators..."
Add-LocalGroupMember -Group "Administrators" -Member "SECSCOPE\anakin" -ErrorAction SilentlyContinue

Write-Host "[ws02_misconfig] Starting Print Spooler service (PrinterBug coercion target)..."
Set-Service -Name Spooler -StartupType Automatic
Start-Service Spooler -ErrorAction SilentlyContinue
Write-Host "[ws02_misconfig] Spooler service started"

Write-Host "[ws02_misconfig] NOTE: Unconstrained delegation on WS02 is set in AD by dc01_objects.ps1"

Write-Host "[ws02_misconfig] Configuring interactive AutoLogon as SECSCOPE\anakin..."
$winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value "1" -Type String -Force
Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value "anakin" -Type String -Force
Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value "SECSCOPE" -Type String -Force
Set-ItemProperty -Path $winlogon -Name DefaultPassword -Value "Vader2024!" -Type String -Force
Write-Host "[ws02_misconfig] WS02 will now boot to anakin's desktop (not local Administrator) - required for the unconstrained delegation TGT-capture scenario"

Write-Host "[ws02_misconfig] Done"
