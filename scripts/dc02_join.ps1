$ErrorActionPreference = "Continue"

Write-Host "[dc02_join] Starting AD DS promotion..."

$domain    = $env:DOMAIN
$adminPass = $env:ADMIN_PASS
$dc01IP    = $env:DC01_IP

Write-Host "[dc02_join] Waiting for DC01 to be reachable..."
$reachable = $false
for ($i = 1; $i -le 20; $i++) {
    if (Test-Connection $dc01IP -Count 1 -Quiet) {
        $reachable = $true
        Write-Host "[dc02_join] DC01 reachable"
        break
    }
    Write-Host "[dc02_join] Attempt $i/20, waiting..."
    Start-Sleep 15
}
if (-not $reachable) {
    Write-Host "[dc02_join] ERROR: DC01 not reachable after 20 attempts"
    exit 1
}

Write-Host "[dc02_join] Pinning secscope.corp to DC01 IP in hosts file..."
if (-not (Select-String -Path "$env:windir\System32\drivers\etc\hosts" `
        -Pattern "secscope.corp" -SimpleMatch -Quiet)) {
    Add-Content -Path "$env:windir\System32\drivers\etc\hosts" `
        -Value "$dc01IP secscope.corp dc01.secscope.corp dc01" -Force
    Write-Host "[dc02_join] Hosts file entry added"
} else {
    Write-Host "[dc02_join] Hosts file entry already exists"
}

Write-Host "[dc02_join] Syncing clock with DC01 ($dc01IP)..."
try {
    net time \\$dc01IP /set /y 2>&1 | Out-Null
    $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[dc02_join] Clock synced. Current time: $currentTime"
} catch {
    Write-Host "[dc02_join] WARNING: Time sync failed: $_"
    Write-Host "[dc02_join] Current time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "[dc02_join] AD requires clocks within 5 minutes of each other."
}

Write-Host "[dc02_join] Installing AD-Domain-Services..."
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

Write-Host "[dc02_join] Joining as additional domain controller..."
try {
    $dcRole = (Get-WmiObject Win32_ComputerSystem).DomainRole
    if ($dcRole -ge 4) {
        Write-Host "[dc02_join] Already a domain controller (role $dcRole), skipping promotion"
        exit 0
    }
} catch {}
$secPass = ConvertTo-SecureString $adminPass -AsPlainText -Force
Write-Host "[dc02_join] Promoting to additional DC (retry up to 20 times)..."
$dsrmSec = ConvertTo-SecureString $adminPass -AsPlainText -Force

$credFormats = @(
    "Administrator@$domain",
    "SECSCOPE\Administrator",
    "Administrator"
)

$promoted = $false
for ($i = 1; $i -le 20; $i++) {
    foreach ($credFormat in $credFormats) {
        Write-Host "[dc02_join] Attempt $i/20 -- credential: $credFormat"
        $cred = New-Object System.Management.Automation.PSCredential($credFormat, $secPass)
        try {
            Install-ADDSDomainController `
                -DomainName $domain `
                -Credential $cred `
                -SafeModeAdministratorPassword $dsrmSec `
                -Force `
                -NoRebootOnCompletion:$true `
                -ErrorAction Stop
            $promoted = $true
            Write-Host "[dc02_join] Promotion succeeded with credential: $credFormat"
            break
        } catch {
            Write-Host "[dc02_join] Failed with $credFormat`: $_"
            Start-Sleep -Seconds 15
        }
    }
    if ($promoted) { break }
    Write-Host "[dc02_join] All formats failed on attempt $i/20, waiting..."
    Start-Sleep -Seconds 30
}
if (-not $promoted) {
    Write-Host "[dc02_join] ERROR: Failed to promote after 20 attempts"
    exit 1
}

Write-Host "[dc02_join] Promotion completed. Reboot required (vagrant reload dc02)."
