$ErrorActionPreference = "Continue"

Write-Host "[dc01_postboot] Starting AD DS promotion..."

$domain      = $env:DOMAIN
$domainUpper = $env:DOMAIN_UPPER
$dsrmPass    = $env:DSRM_PASS

Write-Host "[dc01_postboot] Installing AD-Domain-Services, DNS, RSAT..."
Install-WindowsFeature -Name AD-Domain-Services, DNS, RSAT-AD-PowerShell -IncludeManagementTools

try {
    $null = Get-ADDomain -ErrorAction Stop
    Write-Host "[dc01_postboot] Domain $domain already exists, skipping promotion"
    exit 0
} catch {}

Write-Host "[dc01_postboot] Promoting to Domain Controller ($domain)..."
$dsrmSec = ConvertTo-SecureString $dsrmPass -AsPlainText -Force

Install-ADDSForest `
    -DomainName $domain `
    -SafeModeAdministratorPassword $dsrmSec `
    -Force `
    -NoRebootOnCompletion:$true

Write-Host "[dc01_postboot] Forest install completed. Reboot required (vagrant reload dc01)."
