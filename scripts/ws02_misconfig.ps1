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

Write-Host "[ws02_misconfig] Seeding Domain Cached Credentials (DCC2) for SECSCOPE\anakin (AutoLogon offline fallback)..."
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
[IntPtr]$anakinToken = [IntPtr]::Zero
$anakinLogonOk = [CachedLogonHelper]::LogonUser("anakin", "SECSCOPE", "Vader2024!", $LOGON32_LOGON_INTERACTIVE, $LOGON32_PROVIDER_DEFAULT, [ref]$anakinToken)
if ($anakinLogonOk) {
    [CachedLogonHelper]::CloseHandle($anakinToken) | Out-Null
    Write-Host "[ws02_misconfig] anakin's DCC2 verifier cached - AutoLogon will now survive early-boot domain unavailability"
} else {
    Write-Host "[ws02_misconfig] WARNING: interactive LogonUser failed for anakin (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
}

Write-Host "[ws02_misconfig] Configuring interactive AutoLogon as SECSCOPE\anakin..."
$winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value "1" -Type String -Force
Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value "anakin" -Type String -Force
Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value "SECSCOPE" -Type String -Force
Set-ItemProperty -Path $winlogon -Name DefaultPassword -Value "Vader2024!" -Type String -Force
Set-ItemProperty -Path $winlogon -Name AutoLogonCount -Value 5 -Type DWord -Force
Write-Host "[ws02_misconfig] WS02 will now boot to anakin's desktop (not local Administrator) - required for the unconstrained delegation TGT-capture scenario"

Write-Host "[ws02_misconfig] Installing LAPS client CSE (so the LAPS GPO can manage the local admin password)..."
# See ws01_misconfig.ps1 for rationale. Offline-first from the synced folder,
# else from Microsoft; idempotent and non-fatal. GP refresh applies the LAPS GPO
# linked by dc01_objects.ps1 to OU=Workstations,OU=IT.
if (-not (Test-Path "C:\Program Files\LAPS\CSE\AdmPwd.dll")) {
    $lapsMsi = $null
    if (Test-Path "C:\vagrant\LAPS.x64.msi") { $lapsMsi = "C:\vagrant\LAPS.x64.msi" }
    else {
        try {
            $lapsMsi = "C:\Windows\Temp\LAPS.x64.msi"
            Invoke-WebRequest -Uri "https://download.microsoft.com/download/C/7/A/C7AAD914-A8A6-4904-88A1-29E657445D03/LAPS.x64.msi" -OutFile $lapsMsi -TimeoutSec 60 -ErrorAction Stop
        } catch { $lapsMsi = $null; Write-Host "[ws02_misconfig] WARNING: LAPS CSE unavailable (offline + download failed); LAPS exercise will not populate" }
    }
    if ($lapsMsi) {
        Start-Process msiexec.exe -ArgumentList "/i `"$lapsMsi`" /quiet /norestart ADDLOCAL=CSE" -Wait
        Write-Host "[ws02_misconfig] LAPS CSE installed"
    }
} else {
    Write-Host "[ws02_misconfig] LAPS CSE already installed"
}
gpupdate /target:computer /force 2>&1 | Out-Null

Write-Host "[ws02_misconfig] Done"
