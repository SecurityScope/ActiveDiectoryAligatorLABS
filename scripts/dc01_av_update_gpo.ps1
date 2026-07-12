$ErrorActionPreference = "Continue"

Write-Host "[av_update_gpo] Creating domain GPO to disable Windows Defender AV and Windows Update..."

$domain  = $env:DOMAIN
$gpoName = "Disable AV and Windows Update"

Write-Host "[av_update_gpo] Ensuring Group Policy management tools are available..."
if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
    Write-Host "[av_update_gpo] GroupPolicy module missing, installing GPMC feature..."
    Install-WindowsFeature -Name GPMC -ErrorAction SilentlyContinue | Out-Null
}
Import-Module GroupPolicy -ErrorAction Stop

Write-Host "[av_update_gpo] Waiting for AD services..."
$ready = $false
for ($i = 1; $i -le 12; $i++) {
    try {
        $null = Get-ADDomain -ErrorAction Stop
        $ready = $true
        Write-Host "[av_update_gpo] AD services ready (attempt $i)"
        break
    } catch {
        Write-Host "[av_update_gpo] Attempt $i/12, waiting..."
        Start-Sleep 5
    }
}
if (-not $ready) {
    Write-Host "[av_update_gpo] ERROR: AD Domain Services not found after 60s."
    exit 1
}

$domainDN = (Get-ADDomain).DistinguishedName
Write-Host "[av_update_gpo] Domain DN: $domainDN"

# ── Create the GPO (idempotent) ────────────────────────────────────────────
$gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
if ($gpo) {
    Write-Host "[av_update_gpo] GPO '$gpoName' already exists, updating settings"
} else {
    $gpo = New-GPO -Name $gpoName -Comment "Lab policy: disable Defender AV and Windows Update on all domain machines"
    Write-Host "[av_update_gpo] Created GPO '$gpoName'"
}

# ── Windows Defender ────────────────────────────────────────────────────────
Write-Host "[av_update_gpo] Setting Windows Defender disable policy..."
$defenderKey = "HKLM\Software\Policies\Microsoft\Windows Defender"
$rtpKey      = "HKLM\Software\Policies\Microsoft\Windows Defender\Real-Time Protection"
Set-GPRegistryValue -Name $gpoName -Key $defenderKey -ValueName "DisableAntiSpyware"          -Type DWord -Value 1 | Out-Null
Set-GPRegistryValue -Name $gpoName -Key $rtpKey      -ValueName "DisableRealtimeMonitoring"   -Type DWord -Value 1 | Out-Null
Set-GPRegistryValue -Name $gpoName -Key $rtpKey      -ValueName "DisableBehaviorMonitoring"   -Type DWord -Value 1 | Out-Null
Set-GPRegistryValue -Name $gpoName -Key $rtpKey      -ValueName "DisableOnAccessProtection"   -Type DWord -Value 1 | Out-Null
Set-GPRegistryValue -Name $gpoName -Key $rtpKey      -ValueName "DisableScanOnRealtimeEnable" -Type DWord -Value 1 | Out-Null
Write-Host "[av_update_gpo] Defender policy set"

# ── Windows Update ──────────────────────────────────────────────────────────
Write-Host "[av_update_gpo] Setting Windows Update disable policy..."
$auKey = "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU"
Set-GPRegistryValue -Name $gpoName -Key $auKey -ValueName "NoAutoUpdate" -Type DWord -Value 1 | Out-Null
Write-Host "[av_update_gpo] Windows Update policy set (Configure Automatic Updates = Disabled)"

# ── Link at the domain root (applies to all domain machines, incl. DCs) ─────
$linked = $false
try {
    $links = (Get-GPInheritance -Target $domainDN).GpoLinks
    if ($links | Where-Object { $_.DisplayName -eq $gpoName }) { $linked = $true }
} catch {}
if ($linked) {
    Write-Host "[av_update_gpo] GPO already linked at domain root"
} else {
    New-GPLink -Name $gpoName -Target $domainDN -LinkEnabled Yes -ErrorAction SilentlyContinue | Out-Null
    Write-Host "[av_update_gpo] GPO linked at domain root ($domainDN)"
}

Write-Host "[av_update_gpo] Done -- '$gpoName' applies to all domain-joined Windows machines"
