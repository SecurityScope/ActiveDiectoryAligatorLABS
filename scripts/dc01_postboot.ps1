$ErrorActionPreference = "Continue"

Write-Host "[dc01_postboot] Starting AD DS promotion..."

$domain      = $env:DOMAIN
$domainUpper = $env:DOMAIN_UPPER
$dsrmPass    = $env:DSRM_PASS

Write-Host "[dc01_postboot] Installing AD-Domain-Services, DNS, RSAT..."
Install-WindowsFeature -Name AD-Domain-Services, DNS, RSAT-AD-PowerShell -IncludeManagementTools

# Idempotent resume: if the forest already exists (e.g. an earlier run was
# interrupted after promotion), skip re-promotion.
try {
    $null = Get-ADDomain -ErrorAction Stop
    Write-Host "[dc01_postboot] Domain $domain already exists, skipping promotion"
    exit 0
} catch {}

# ── Why the promotion is launched as a scheduled task ───────────────────────
# Install-ADDSForest replaces the local SAM while it runs. That invalidates the
# WinRM session that is executing this provisioner: ~60-90s in, Vagrant gets a
# 401 ("An authorization error occurred while connecting to WinRM"). Previously
# the detached process happened to survive long enough on a warmed-up box, but
# on a fresh box setup.py saw the 401, force-reloaded the VM, and killed the
# promotion mid-flight (leaving a half-promoted DC that never boots).
#
# Running the promotion under a one-shot SYSTEM scheduled task removes that
# dependency entirely: the task keeps running after WinRM auth is lost, writes
# the result, then reboots the guest itself. setup.py waits for AD to come back
# instead of reloading.
Write-Host "[dc01_postboot] Preparing detached forest promotion..."

$innerScriptPath = "C:\Windows\Temp\dc01_addsforest.ps1"
$logPath         = "C:\Windows\Temp\dc01_addsforest.out.log"
$errPath         = "C:\Windows\Temp\dc01_addsforest.err.log"
$donePath        = "C:\Windows\Temp\dc01_addsforest.done"
$taskName        = "DC01-ADDSForest"

Remove-Item $logPath,$errPath,$donePath -ErrorAction SilentlyContinue

# The Install-ADDSForest call stays on ONE line. A prior bug combined CRLF line
# endings with backtick continuation and split the cmdlet into parameterless
# statements, which blocked forever on the missing mandatory -DomainName.
$innerScript = @'
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'
$ConfirmPreference     = 'None'
$ErrorActionPreference = 'Stop'
$log  = 'C:\Windows\Temp\dc01_addsforest.out.log'
$err  = 'C:\Windows\Temp\dc01_addsforest.err.log'
$done = 'C:\Windows\Temp\dc01_addsforest.done'
try {
    # Another attempt (or a resumed build) may already have promoted this box.
    try {
        $null = Get-ADDomain -ErrorAction Stop
        'already-promoted' | Set-Content -Path $done -Encoding ASCII
        exit 0
    } catch {}
    Import-Module ADDSDeployment
    $dsrmSec = ConvertTo-SecureString '__DSRM_PASS__' -AsPlainText -Force
    Install-ADDSForest -DomainName '__DOMAIN__' -SafeModeAdministratorPassword $dsrmSec -DomainNetbiosName '__DOMAIN_UPPER__' -InstallDns:$true -CreateDnsDelegation:$false -Force -Confirm:$false -NoRebootOnCompletion:$true -ErrorAction Stop *>&1 | Tee-Object -FilePath $log
    'ok' | Set-Content -Path $done -Encoding ASCII
    schtasks.exe /Delete /TN "DC01-ADDSForest" /F 2>&1 | Out-Null
    Remove-Item -LiteralPath "C:\Windows\Temp\dc01_addsforest.ps1" -Force -ErrorAction SilentlyContinue
    Restart-Computer -Force
} catch {
    ($_ | Out-String) | Set-Content -Path $err -Encoding UTF8
    ('failed: ' + $_) | Add-Content -Path $log
    'failed' | Set-Content -Path $done -Encoding ASCII
    schtasks.exe /Delete /TN "DC01-ADDSForest" /F 2>&1 | Out-Null
    Remove-Item -LiteralPath "C:\Windows\Temp\dc01_addsforest.ps1" -Force -ErrorAction SilentlyContinue
    exit 1
}
'@

$dsrmPass    = $dsrmPass -replace "'", "''"
$domain      = $domain -replace "'", "''"
$domainUpper = $domainUpper -replace "'", "''"
$innerScript = $innerScript.Replace('__DSRM_PASS__', $dsrmPass).Replace('__DOMAIN__', $domain).Replace('__DOMAIN_UPPER__', $domainUpper)
Set-Content -Path $innerScriptPath -Value $innerScript -Encoding UTF8

$action = "powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File $innerScriptPath"
schtasks.exe /create /tn $taskName /tr $action /sc ONCE /st 23:59 /ru SYSTEM /rl HIGHEST /f 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[dc01_postboot] ERROR: could not register scheduled task '$taskName' (rc=$LASTEXITCODE)."
    schtasks.exe /create /tn $taskName /tr $action /sc ONCE /st 23:59 /ru SYSTEM /rl HIGHEST /f 2>&1 | Write-Host
    exit 1
}

schtasks.exe /run /tn $taskName 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[dc01_postboot] ERROR: could not start scheduled task '$taskName' (rc=$LASTEXITCODE)."
    exit 1
}

Write-Host "[dc01_postboot] Promotion launched as scheduled task '$taskName'."
Write-Host "[dc01_postboot] Exiting now: WinRM will drop while the local SAM is replaced, then the guest reboots."
exit 0
