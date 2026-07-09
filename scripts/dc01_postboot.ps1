$ErrorActionPreference = "Continue"

Write-Host "[dc01_postboot] Starting AD DS promotion..."

$domain      = $env:DOMAIN
$domainUpper = $env:DOMAIN_UPPER
$dsrmPass    = $env:DSRM_PASS

Write-Host "[dc01_postboot] Installing AD-Domain-Services, DNS, RSAT..."
Install-WindowsFeature -Name AD-Domain-Services, DNS, RSAT-AD-PowerShell -IncludeManagementTools

Write-Host "[dc01_postboot] Waiting for ADWS before domain check..."
$adwsReady = $false
for ($i = 1; $i -le 12; $i++) {
    try {
        $status = (Get-Service ADWS -ErrorAction Stop).Status
        if ($status -eq "Running") { $adwsReady = $true; break }
    } catch {}
    Start-Sleep 5
}
if ($adwsReady) {
    try {
        $null = Get-ADDomain -ErrorAction Stop
        Write-Host "[dc01_postboot] Domain $domain already exists, skipping promotion"
        exit 0
    } catch {}
}

Write-Host "[dc01_postboot] Promoting to Domain Controller ($domain)..."

# Run Install-ADDSForest in a genuinely detached process (Start-Process),
# NOT a PowerShell background job, and with every parameter on a single
# line (no backtick line-continuation). A prior bug in this file combined
# CRLF line endings with backtick continuation, which silently split the
# Install-ADDSForest call into multiple statements - the cmdlet then ran
# with none of its parameters, and PowerShell blocked forever prompting
# (non-interactively, so it could never be answered) for the missing
# mandatory -DomainName value. Keeping this as a single line avoids that
# entire class of bug regardless of file line-ending handling.
$innerScriptPath = "C:\Windows\Temp\dc01_addsforest.ps1"
$innerLines = @(
    '$ProgressPreference = ''SilentlyContinue''',
    '$WarningPreference = ''SilentlyContinue''',
    '$ConfirmPreference = ''None''',
    'Import-Module ADDSDeployment',
    ('$dsrmSec = ConvertTo-SecureString ' + "'" + $dsrmPass + "'" + ' -AsPlainText -Force'),
    ('Install-ADDSForest -DomainName ' + "'" + $domain + "'" + ' -SafeModeAdministratorPassword $dsrmSec -DomainNetbiosName ' + "'" + $domainUpper + "'" + ' -InstallDns:$true -CreateDnsDelegation:$false -Force -Confirm:$false -NoRebootOnCompletion:$true -ErrorAction Stop')
)
Set-Content -Path $innerScriptPath -Value $innerLines -Encoding UTF8

$stdout = "C:\Windows\Temp\dc01_addsforest.out.log"
$stderr = "C:\Windows\Temp\dc01_addsforest.err.log"
$stdin  = "C:\Windows\Temp\dc01_addsforest.in.txt"
Remove-Item $stdout,$stderr,$stdin -ErrorAction SilentlyContinue
Set-Content -Path $stdin -Value "" -Encoding ASCII

$startArgs = @{
    FilePath               = "powershell.exe"
    ArgumentList           = @("-NonInteractive", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $innerScriptPath)
    RedirectStandardInput  = $stdin
    RedirectStandardOutput = $stdout
    RedirectStandardError  = $stderr
    WindowStyle            = "Hidden"
    PassThru               = $true
}
$proc = Start-Process @startArgs

$finished = Wait-Process -Id $proc.Id -Timeout 240 -ErrorAction SilentlyContinue
if (-not $finished -and -not $proc.HasExited) {
    Write-Host "[dc01_postboot] ERROR: Install-ADDSForest timed out after 240s (hung). Killing process."
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Get-Content $stdout,$stderr -ErrorAction SilentlyContinue | Write-Host
    exit 1
}

Get-Content $stdout -ErrorAction SilentlyContinue | Write-Host
$errContent = Get-Content $stderr -ErrorAction SilentlyContinue
if ($errContent) {
    Write-Host "[dc01_postboot] STDERR:"
    $errContent | Write-Host
}
$okExit = ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3 -or [string]::IsNullOrEmpty("$($proc.ExitCode)"))
if (-not $okExit) {
    if ($errContent -match "Name change pending") {
        Write-Host "[dc01_postboot] ERROR: Computer rename has not been applied (reboot missing)."
        Write-Host "[dc01_postboot] Run 'vagrant reload dc01 --force' first, then retry this provisioner."
    }
    Write-Host "[dc01_postboot] ERROR: Install-ADDSForest exited with code $($proc.ExitCode)"
    exit 1
}
Write-Host "[dc01_postboot] Install-ADDSForest exited with code $($proc.ExitCode) (0=success, 3=reboot required)"

Write-Host "[dc01_postboot] Forest install completed. Reboot required (vagrant reload dc01)."
Remove-Item $innerScriptPath -ErrorAction SilentlyContinue
