$ErrorActionPreference = "Continue"

Write-Host "[ws01_misconfig] Configuring intentional vulnerabilities on WS01..."

Write-Host "[ws01_misconfig] Disabling SMB signing..."
Set-SmbServerConfiguration -RequireSecuritySignature $false -EnableSecuritySignature $false -Force
Set-SmbClientConfiguration -RequireSecuritySignature $false -Force
Write-Host "[ws01_misconfig] SMB signing disabled"

Write-Host "[ws01_misconfig] Enabling WDigest (plaintext creds in LSASS)..."
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest" -Name UseLogonCredential -Value 1 -Type DWORD -Force
Write-Host "[ws01_misconfig] WDigest enabled"

Write-Host "[ws01_misconfig] Disabling LSA protection..."
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name RunAsPPL -Value 0 -Type DWORD -Force
Write-Host "[ws01_misconfig] LSA protection disabled"

Write-Host "[ws01_misconfig] Enabling NTLMv1 (downgrade for hash capture)..."
New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name LMCompatibilityLevel -Value 0 -Type DWORD -Force
Write-Host "[ws01_misconfig] NTLMv1 enabled (LMCompatibilityLevel=0)"

Write-Host "[ws01_misconfig] Enabling LLMNR and mDNS (multicast name resolution poisoning targets)..."
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Name EnableMulticast -Value 1 -Type DWORD -Force
Write-Host "[ws01_misconfig] LLMNR/mDNS enabled"

Write-Host "[ws01_misconfig] Enabling NetBIOS over TCP/IP..."
$adapters = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true }
foreach ($adapter in $adapters) {
    $adapter.SetTcpipNetbios(1) | Out-Null
}
Write-Host "[ws01_misconfig] NetBIOS enabled"

Write-Host "[ws01_misconfig] Creating local admin account..."
$localPass = ConvertTo-SecureString "LocalAdmin2024!" -AsPlainText -Force
New-LocalUser -Name "localadmin" -Password $localPass -PasswordNeverExpires:$true -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group "Administrators" -Member "localadmin" -ErrorAction SilentlyContinue
Write-Host "[ws01_misconfig] Local admin 'localadmin' created"

Write-Host "[ws01_misconfig] Adding domain users to local Remote Desktop Users..."
Add-LocalGroupMember -Group "Remote Desktop Users" -Member "SECSCOPE\han", "SECSCOPE\leia" -ErrorAction SilentlyContinue

Write-Host "[ws01_misconfig] Seeding Domain Cached Credentials (DCC2) for SECSCOPE\han..."
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CachedLogonHelper {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LogonUser(string lpszUsername, string lpszDomain, string lpszPassword,
        int dwLogonType, int dwLogonProvider, out IntPtr phToken);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    public static extern bool CloseHandle(IntPtr handle);
}
"@
$LOGON32_LOGON_INTERACTIVE = 2
$LOGON32_PROVIDER_DEFAULT = 0
[IntPtr]$hanToken = [IntPtr]::Zero
$hanLogonOk = [CachedLogonHelper]::LogonUser("han", "SECSCOPE", "Solo2024!", $LOGON32_LOGON_INTERACTIVE, $LOGON32_PROVIDER_DEFAULT, [ref]$hanToken)
if ($hanLogonOk) {
    [CachedLogonHelper]::CloseHandle($hanToken) | Out-Null
    Write-Host "[ws01_misconfig] han's logon was validated by the DC - DCC2 verifier now cached in the local SECURITY hive"
} else {
    Write-Host "[ws01_misconfig] WARNING: interactive LogonUser failed for han (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
}

Write-Host "[ws01_misconfig] Planting credentials in PowerShell history..."
$histPath = "C:\Users\anakin\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine"
New-Item -ItemType Directory -Force -Path $histPath | Out-Null
@"
net use \\dc01\sysvol /user:SECSCOPE\han Solo2024!
Invoke-Command -ComputerName dc01 -Credential (New-Object PSCredential('SECSCOPE\anakin', (ConvertTo-SecureString 'Vader2024!' -AsPlainText -Force))) -ScriptBlock { whoami }
"@ | Out-File -FilePath "$histPath\ConsoleHost_history.txt" -Encoding UTF8
Write-Host "[ws01_misconfig] PowerShell history planted"

Write-Host "[ws01_misconfig] Creating scheduled task (leaves credentials in LSA Secrets)..."
schtasks.exe /create /tn "DailyMaintenance" /tr "C:\Windows\System32\notepad.exe" /sc daily /st 03:00 /ru "SECSCOPE\taskuser" /rp "Task1234!" /F
Write-Host "[ws01_misconfig] Scheduled task 'DailyMaintenance' created"

Write-Host "[ws01_misconfig] Creating Windows service with domain credentials (LSA Secrets)..."
sc.exe create "BackupSvc" binpath= "C:\Windows\System32\cmd.exe /c echo backup" obj="SECSCOPE\svc_backup" password="Backup123" start= demand
Write-Host "[ws01_misconfig] Service 'BackupSvc' created"

Write-Host "[ws01_misconfig] Configuring interactive AutoLogon as SECSCOPE\anakin..."
$winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value "1" -Type String -Force
Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value "anakin" -Type String -Force
Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value "SECSCOPE" -Type String -Force
Set-ItemProperty -Path $winlogon -Name DefaultPassword -Value "Vader2024!" -Type String -Force
Write-Host "[ws01_misconfig] WS01 will now boot to anakin's desktop (not local Administrator)"

Write-Host "[ws01_misconfig] Done"
