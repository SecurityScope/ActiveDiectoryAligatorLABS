# run_detached.ps1
# ---------------------------------------------------------------------------
# Generic "run this provisioner outside the WinRM session" wrapper.
#
# AD DS promotion (Install-ADDSForest / Install-ADDSDomainController /
# Install-ADDSDomain) replaces the local SAM while it runs. That invalidates the
# WinRM session executing the provisioner: Vagrant gets a 401 ~60-90s in and the
# caller must not force-reload the VM (that leaves a half-promoted DC). So we
# launch the real script as a one-shot SYSTEM scheduled task - it survives the
# WinRM loss - and reboot the guest ourselves when it succeeds.
#
# Inputs (Vagrant provisioner env):
#   LAB_SCRIPT  absolute guest path to the real script (e.g.
#               C:\vagrant\scripts\dc02_join.ps1)
#   LAB_TASK    scheduled-task name (e.g. DC02-Join)
#   LAB_DONE    marker file written with "rc=<exitcode>" (e.g.
#               C:\Windows\Temp\dc02_join.done)
#   LAB_REBOOT  "0" to not reboot on success (default: reboot)
#
# Every env var the real scripts read is copied into the generated task script.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Continue'

$taskName  = $env:LAB_TASK
$labScript = $env:LAB_SCRIPT
$donePath  = $env:LAB_DONE
$doReboot  = ($env:LAB_REBOOT -ne '0')

Write-Host "[detach] Preparing detached provisioner..."

if (-not $taskName -or -not $labScript -or -not $donePath) {
    Write-Host "[detach] ERROR: LAB_TASK, LAB_SCRIPT and LAB_DONE are all required."
    exit 2
}
if (-not (Test-Path -LiteralPath $labScript)) {
    Write-Host "[detach] ERROR: script not found: $labScript"
    exit 2
}

# Copy the script into the guest's own disk: the VirtualBox shared folder
# (C:\vagrant) is not guaranteed to be reachable from a SYSTEM scheduled task.
$localScript = "C:\Windows\Temp\$taskName-real.ps1"
Copy-Item -LiteralPath $labScript -Destination $localScript -Force
Remove-Item -LiteralPath $donePath -Force -ErrorAction SilentlyContinue

$names = @(
    'DOMAIN', 'DOMAIN_UPPER', 'CHILD_DOMAIN', 'CHILD_UPPER', 'CHILD_NETBIOS',
    'ADMIN_PASS', 'DSRM_PASS',
    'DC_IP', 'DC01_IP', 'DC02_IP', 'DC03_IP', 'SRV01_IP', 'WS01_IP',
    'WS02_IP', 'LIN01_IP', 'KALI_IP',
    'LOG_PREFIX', 'DNS_SERVER', 'VM_IP', 'VM_NAME', 'VM_OU', 'MEMBER_SCOPE'
)
$lines = @('$ErrorActionPreference = ''Continue''')
foreach ($n in $names) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($null -ne $v) {
        $lines += ('$env:' + $n + ' = ''' + ($v -replace "'", "''") + '''')
    }
}
# Capture the real script's output so a failed join leaves evidence (the old
# wrapper discarded it and only wrote the rc marker).
$outLog = "C:\Windows\Temp\$taskName.out.log"
$errLog = "C:\Windows\Temp\$taskName.err.log"
$lines += ('$p = Start-Process -FilePath powershell.exe -ArgumentList @("-NonInteractive","-NoProfile","-ExecutionPolicy","Bypass","-File","' + $localScript + '") -RedirectStandardOutput ''' + $outLog + ''' -RedirectStandardError ''' + $errLog + ''' -Wait -PassThru')
$lines += ('Set-Content -Path ''' + $donePath + ''' -Value ("rc=" + $p.ExitCode) -Encoding ASCII')
if ($doReboot) {
    $lines += 'if ($p.ExitCode -eq 0) { Restart-Computer -Force }'
}
$lines += 'exit 0'

$taskScript = "C:\Windows\Temp\$taskName.ps1"
Set-Content -Path $taskScript -Value ($lines -join "`r`n") -Encoding UTF8

$action = "powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File $taskScript"
schtasks.exe /create /tn $taskName /tr $action /sc ONCE /st 23:59 /ru SYSTEM /rl HIGHEST /f 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[detach] ERROR: could not register scheduled task '$taskName' (rc=$LASTEXITCODE)."
    schtasks.exe /create /tn $taskName /tr $action /sc ONCE /st 23:59 /ru SYSTEM /rl HIGHEST /f 2>&1 | Write-Host
    exit 1
}
schtasks.exe /run /tn $taskName 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[detach] ERROR: could not start scheduled task '$taskName' (rc=$LASTEXITCODE)."
    exit 1
}

Write-Host "[detach] $taskName launched. Real script: $localScript"
Write-Host "[detach] Exiting now; WinRM will drop while the local SAM is replaced."
exit 0
