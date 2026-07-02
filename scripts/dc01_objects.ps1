$ErrorActionPreference = "Continue"
Import-Module ActiveDirectory -ErrorAction SilentlyContinue

Write-Host "[objects] Starting AD objects creation..."

Write-Host "[objects] Waiting for AD services..."
$ready = $false
for ($i = 1; $i -le 24; $i++) {
    try {
        $null = Get-ADDomain -ErrorAction Stop
        $null = Get-ADDomainController -Discover -ErrorAction Stop
        $ready = $true
        Write-Host "[objects] AD services ready (attempt $i)"
        break
    } catch {
        Write-Host "[objects] Attempt $i/24, waiting..."
        Start-Sleep 15
    }
}
if (-not $ready) {
    Write-Host "[objects] ERROR: AD Domain Services not found after 24 attempts."
    Write-Host "[objects] Did you run 'vagrant reload dc01' after the postboot provisioner?"
    exit 1
}

Write-Host "[objects] Setting weak domain password policy..."
Set-ADDefaultDomainPasswordPolicy -Identity $env:DOMAIN `
    -MinPasswordLength 4 `
    -ComplexityEnabled $false `
    -PasswordHistoryCount 0 `
    -MaxPasswordAge "0" `
    -MinPasswordAge "0" `
    -LockoutThreshold 0
Write-Host "[objects] Weak password policy applied"

$domain    = $env:DOMAIN
$domainDN  = (Get-ADDomain).DistinguishedName

Write-Host "[objects] Domain DN: $domainDN"

function New-OU-IfMissing {
    param($Name, $Path)
    try {
        $exists = Get-ADOrganizationalUnit -Identity "OU=$Name,$Path" -ErrorAction Stop
        if ($exists) { Write-Host "[objects] OU $Name already exists, skipping"; return }
    } catch {}
    New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false
    Write-Host "[objects] Created OU: $Name"
}

function New-User-IfMissing {
    param($Name, $Password, $Path, $Description, [switch]$PasswordNeverExpires)
    try {
        $exists = Get-ADUser -Identity $Name -ErrorAction Stop
        if ($exists) { Write-Host "[objects] User $Name already exists, skipping"; return }
    } catch {}
    $secPass = ConvertTo-SecureString $Password -AsPlainText -Force
    $params = @{
        Name                  = $Name
        SamAccountName        = $Name
        UserPrincipalName     = "$Name@$domain"
        Path                  = $Path
        AccountPassword       = $secPass
        Enabled               = $true
        Description           = $Description
        PasswordNeverExpires  = $PasswordNeverExpires.IsPresent
    }
    New-ADUser @params
    Write-Host "[objects] Created user: $Name"
}

function New-Group-IfMissing {
    param($Name, $Scope, $Path)
    try {
        $exists = Get-ADGroup -Identity $Name -ErrorAction Stop
        if ($exists) { Write-Host "[objects] Group $Name already exists, skipping"; return }
    } catch {}
    New-ADGroup -Name $Name -SamAccountName $Name -GroupScope $Scope -GroupCategory Security -Path $Path
    Write-Host "[objects] Created group: $Name"
}

function Add-GroupMember-IfMissing {
    param($Group, $Member)
    $members = Get-ADGroupMember -Identity $Group -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName
    if ($members -contains $Member) {
        Write-Host "[objects] $Member already in $Group, skipping"
        return
    }
    Add-ADGroupMember -Identity $Group -Members $Member
    Write-Host "[objects] Added $Member to $Group"
}

# ══════════════════════════════════════════════════════════════════════════
# OUs
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Creating OUs..."
$ous = @(
    @{Name="IT"; Path=$domainDN},
    @{Name="Admins"; Path="OU=IT,$domainDN"},
    @{Name="Workstations"; Path="OU=IT,$domainDN"},
    @{Name="HR"; Path=$domainDN},
    @{Name="HR-Workstations"; Path="OU=HR,$domainDN"},
    @{Name="Sales"; Path=$domainDN},
    @{Name="Sales-Workstations"; Path="OU=Sales,$domainDN"},
    @{Name="Servers"; Path=$domainDN},
    @{Name="ServiceAccounts"; Path=$domainDN},
    @{Name="Staging"; Path=$domainDN}
)
foreach ($ou in $ous) {
    New-OU-IfMissing -Name $ou.Name -Path $ou.Path
}

# ══════════════════════════════════════════════════════════════════════════
# Users
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Creating users..."
New-User-IfMissing -Name "anakin"    -Password "Vader2024!"     -Path "OU=Admins,OU=IT,$domainDN" -Description "IT Admin"
New-User-IfMissing -Name "han"       -Password "Solo2024!"      -Path "OU=IT,$domainDN"          -Description "IT User"
New-User-IfMissing -Name "leia"      -Password "Princess2024!"  -Path "OU=HR,$domainDN"          -Description "HR Manager"
New-User-IfMissing -Name "luke"      -Password "password"       -Path "OU=Sales,$domainDN"       -Description "Sales user"
New-User-IfMissing -Name "svc_sql"   -Password "SqlService123"  -Path "OU=ServiceAccounts,$domainDN" -Description "MSSQL service" -PasswordNeverExpires
New-User-IfMissing -Name "svc_web"   -Password "WebService123"  -Path "OU=ServiceAccounts,$domainDN" -Description "IIS service" -PasswordNeverExpires
New-User-IfMissing -Name "svc_backup"-Password "Backup123"      -Path "OU=ServiceAccounts,$domainDN" -Description "Backup service" -PasswordNeverExpires
New-User-IfMissing -Name "taskuser"  -Password "Task1234!"      -Path "OU=ServiceAccounts,$domainDN" -Description "Scheduled task user" -PasswordNeverExpires
New-User-IfMissing -Name "nopreauth" -Password "NoPreAuth123"   -Path "OU=Sales,$domainDN"       -Description "ASREPRoast target"

# ══════════════════════════════════════════════════════════════════════════
# Groups
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Creating groups..."
New-Group-IfMissing -Name "IT-Team"                -Scope "Global" -Path "OU=IT,$domainDN"
New-Group-IfMissing -Name "HR-Team"                -Scope "Global" -Path "OU=HR,$domainDN"
New-Group-IfMissing -Name "HelpDesk"               -Scope "Global" -Path "OU=IT,$domainDN"
New-Group-IfMissing -Name "SQLAdmins"              -Scope "Global" -Path "OU=Servers,$domainDN"
New-Group-IfMissing -Name "Backup-Operators-Custom"-Scope "Global" -Path "OU=IT,$domainDN"

# ══════════════════════════════════════════════════════════════════════════
# Group memberships
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Setting group memberships..."

Add-GroupMember-IfMissing -Group "Domain Admins" -Member "anakin"

Add-GroupMember-IfMissing -Group "IT-Team"    -Member "anakin"
Add-GroupMember-IfMissing -Group "IT-Team"    -Member "han"
Add-GroupMember-IfMissing -Group "HR-Team"    -Member "leia"
Add-GroupMember-IfMissing -Group "HelpDesk"   -Member "han"
Add-GroupMember-IfMissing -Group "SQLAdmins"  -Member "svc_sql"
Add-GroupMember-IfMissing -Group "SQLAdmins"  -Member "anakin"
Add-GroupMember-IfMissing -Group "Backup-Operators-Custom" -Member "svc_backup"

Add-GroupMember-IfMissing -Group "Backup Operators"    -Member "svc_backup"
Add-GroupMember-IfMissing -Group "Remote Desktop Users"-Member "han"
Add-GroupMember-IfMissing -Group "Remote Desktop Users"-Member "leia"
Add-GroupMember-IfMissing -Group "Account Operators"   -Member "han"

# ══════════════════════════════════════════════════════════════════════════
# AdminSDHolder abuse -- han in Account Operators (protected group)
# This enables SDProp-based persistence exercises
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Configuring AdminSDHolder ACL for han..."
try {
    $adminSDHolderDN = "CN=AdminSDHolder,CN=System,$domainDN"
    $hanSID = (Get-ADUser han).SID
    $acl = Get-Acl "AD:\$adminSDHolderDN"
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $hanSID,
        [System.DirectoryServices.ActiveDirectoryRights]::GenericWrite,
        [System.Security.AccessControl.AccessControlType]::Allow,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    )
    $acl.AddAccessRule($rule)
    Set-Acl "AD:\$adminSDHolderDN" $acl
    Write-Host "[objects] GenericWrite on AdminSDHolder granted to han"
} catch {
    Write-Host "[objects] AdminSDHolder ACL may already be set: $_"
}

# ══════════════════════════════════════════════════════════════════════════
# SPNs (Kerberoastable)
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Setting SPNs for Kerberoasting..."
try {
    Set-ADUser svc_sql -ServicePrincipalNames @{Add="MSSQLSvc/srv01.secscope.corp:1433","MSSQLSvc/SRV01:1433"}
    Write-Host "[objects] SPNs set on svc_sql"
} catch { Write-Host "[objects] SPNs on svc_sql may already exist" }

try {
    Set-ADUser svc_web -ServicePrincipalNames @{Add="HTTP/srv01.secscope.corp","HTTP/SRV01"}
    Write-Host "[objects] SPNs set on svc_web"
} catch { Write-Host "[objects] SPNs on svc_web may already exist" }

# ══════════════════════════════════════════════════════════════════════════
# ASREPRoast
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Setting DoesNotRequirePreAuth on nopreauth..."
Set-ADAccountControl nopreauth -DoesNotRequirePreAuth $true

# ══════════════════════════════════════════════════════════════════════════
# ACL: han WriteDACL on domain object (enables DCSync setup)
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Granting han WriteDACL on domain object..."
try {
    $hanSID = (Get-ADUser han).SID
    $acl = Get-Acl "AD:\$domainDN"
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $hanSID,
        [System.DirectoryServices.ActiveDirectoryRights]::WriteDacl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule)
    Set-Acl "AD:\$domainDN" $acl
    Write-Host "[objects] WriteDACL granted to han over domain"
} catch {
    Write-Host "[objects] WriteDACL on domain may already be set: $_"
}

# ══════════════════════════════════════════════════════════════════════════
# ACL: HelpDesk GenericWrite over WS01 computer object (enables RBCD)
# ══════════════════════════════════════════════════════════════════════════

if ($env:SKIP_COMPUTERS -eq "true") {

    Write-Host "[objects] SKIP_COMPUTERS=true -- skipping WS01 computer object ACLs"

} else {

Write-Host "[objects] Waiting for WS01 computer object..."
$ws01DN = $null
$attempts = 0
while (-not $ws01DN -and $attempts -lt 24) {
    Start-Sleep 10
    $attempts++
    try { $ws01DN = (Get-ADComputer WS01).DistinguishedName } catch {}
    Write-Host "[objects] Waiting for WS01$... attempt $attempts/24"
}
if ($ws01DN) {
    try {
        $helpdeskSID = (Get-ADGroup HelpDesk).SID
        $acl = Get-Acl "AD:\$ws01DN"
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $helpdeskSID,
            [System.DirectoryServices.ActiveDirectoryRights]::GenericWrite,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
        Set-Acl "AD:\$ws01DN" $acl
        Write-Host "[objects] GenericWrite granted to HelpDesk over WS01"
    } catch {
        Write-Host "[objects] GenericWrite on WS01 failed: $_"
    }
} else {
    Write-Host "[objects] WS01 not found - skipping computer object ACLs. Re-run this provisioner after WS01 joins the domain."
}

}

if ($env:SKIP_COMPUTERS -eq "true") {

    Write-Host "[objects] SKIP_COMPUTERS=true -- skipping WS02 computer object ACLs"

} else {

# ══════════════════════════════════════════════════════════════════════════
# ACL: Unconstrained delegation on WS02
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Waiting for WS02 computer object..."
$ws02DN = $null
$attempts = 0
while (-not $ws02DN -and $attempts -lt 24) {
    Start-Sleep 10
    $attempts++
    try { $ws02DN = (Get-ADComputer WS02).DistinguishedName } catch {}
    Write-Host "[objects] Waiting for WS02$... attempt $attempts/24"
}
if ($ws02DN) {
    try {
        Set-ADComputer WS02 -TrustedForDelegation $true
        Write-Host "[objects] Unconstrained delegation set on WS02"
    } catch {
        Write-Host "[objects] Unconstrained delegation on WS02 failed: $_"
    }
} else {
    Write-Host "[objects] WS02 not found - skipping computer object delegation. Re-run this provisioner after WS02 joins the domain."
}

}

# ══════════════════════════════════════════════════════════════════════════
# ACL: Constrained delegation on SRV01 (to CIFS on WS01, no protocol transition)
# ══════════════════════════════════════════════════════════════════════════

if ($env:SKIP_COMPUTERS -eq "true") {

    Write-Host "[objects] SKIP_COMPUTERS=true -- skipping SRV01 computer object ACLs"

} else {

Write-Host "[objects] Waiting for SRV01 computer object..."
$srv01DN = $null
$attempts = 0
while (-not $srv01DN -and $attempts -lt 24) {
    Start-Sleep 10
    $attempts++
    try { $srv01DN = (Get-ADComputer SRV01).DistinguishedName } catch {}
    Write-Host "[objects] Waiting for SRV01$... attempt $attempts/24"
}
if ($srv01DN) {
    try {
        Set-ADComputer SRV01 -Add @{'msDS-AllowedToDelegateTo'=@('CIFS/ws01.secscope.corp','CIFS/WS01')}
        Set-ADAccountControl "SRV01$" -TrustedToAuthForDelegation $false
        Write-Host "[objects] Constrained delegation set on SRV01 (CIFS/ws01)"
    } catch {
        Write-Host "[objects] Constrained delegation on SRV01 failed: $_"
    }
} else {
    Write-Host "[objects] WARNING: SRV01 not found. Run 'vagrant provision dc01 --provision-with objects' again after SRV01 joins."
}

}

# ══════════════════════════════════════════════════════════════════════════
# ACL: HelpDesk WriteProperty over Domain Admins member attribute
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Granting HelpDesk WriteProperty over Domain Admins group membership..."
try {
    $daDN = (Get-ADGroup "Domain Admins").DistinguishedName
    $helpdeskSID = (Get-ADGroup HelpDesk).SID
    $acl = Get-Acl "AD:\$daDN"
    $memberGuid = [Guid]"bf9679c0-0de6-11d0-a285-00aa003049e2"
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $helpdeskSID,
        [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
        [System.Security.AccessControl.AccessControlType]::Allow,
        $memberGuid,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    )
    $acl.AddAccessRule($rule)
    Set-Acl "AD:\$daDN" $acl
    Write-Host "[objects] WriteProperty over Domain Admins member granted to HelpDesk"
} catch {
    Write-Host "[objects] WriteProperty ACL on Domain Admins may already be set: $_"
}

# ══════════════════════════════════════════════════════════════════════════
# LAPS permissions -- grant han read access to LAPS passwords
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Configuring LAPS permissions..."
try {
    Import-Module AdmPwd.PS -ErrorAction Stop
    $workstationsOU = "OU=Workstations,OU=IT,$domainDN"
    Set-AdmPwdReadPasswordPermission -Identity $workstationsOU -AllowedPrincipals "han" -ErrorAction SilentlyContinue
    Write-Host "[objects] LAPS read permission granted to han on Workstations OU"
} catch {
    Write-Host "[objects] NOTE: AdmPwd.PS module not available. Install LAPS on DC01 (via dc01_postboot.ps1) and run: Set-AdmPwdReadPasswordPermission -Identity 'OU=Workstations,OU=IT,$domainDN' -AllowedPrincipals 'han'"
}

# ══════════════════════════════════════════════════════════════════════════
# GPP cpassword in SYSVOL
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Creating GPP cpassword file in SYSVOL..."
$gppPath = "C:\Windows\SYSVOL\domain\Policies\{LEGACY-GPP-001}\Machine\Preferences\Groups"
New-Item -ItemType Directory -Force -Path $gppPath | Out-Null
$gppXml = @'
<?xml version="1.0" encoding="utf-8"?>
<Groups clsid="{3125E937-EB16-4b4c-9934-544FC6D24D26}">
  <User clsid="{DF5F1855-51E5-4d24-8B1A-D9BDE98BA1D1}"
        name="LocalAdmin" image="2"
        changed="2019-06-15 09:00:00"
        uid="{11111111-1111-1111-1111-111111111111}">
    <Properties
      action="C"
      fullName="Local Admin"
      description="Legacy local admin"
      cpassword="AzVJmXh65BYKuNew0en4PA=="
      changeLogon="0"
      noChange="0"
      neverExpires="1"
      acctDisabled="0"
      userName="LocalAdmin"/>
  </User>
</Groups>
'@
$gppXml | Out-File -FilePath "$gppPath\Groups.xml" -Encoding UTF8
Write-Host "[objects] GPP file created at $gppPath\Groups.xml"

# ══════════════════════════════════════════════════════════════════════════
# Exchange-style permission groups (without Exchange server install)
# Simulates the Exchange attack path: EXCH01 -> Exchange Trusted Subsystem
#   -> Exchange Windows Permissions -> WriteDACL on domain -> DCSync
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] Creating Exchange-style groups..."
New-Group-IfMissing -Name "Exchange Windows Permissions" -Scope "DomainLocal" -Path "OU=Servers,$domainDN"
New-Group-IfMissing -Name "Exchange Trusted Subsystem"    -Scope "DomainLocal" -Path "OU=Servers,$domainDN"
New-Group-IfMissing -Name "Organization Management"       -Scope "Universal"   -Path "OU=Servers,$domainDN"

Add-GroupMember-IfMissing -Group "Exchange Windows Permissions" -Member "Exchange Trusted Subsystem"

Write-Host "[objects] Granting Exchange Windows Permissions WriteDACL on domain object..."
try {
    $exchWPSID = (Get-ADGroup "Exchange Windows Permissions").SID
    $acl = Get-Acl "AD:\$domainDN"
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $exchWPSID,
        [System.DirectoryServices.ActiveDirectoryRights]::WriteDacl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule)
    Set-Acl "AD:\$domainDN" $acl
    Write-Host "[objects] WriteDACL granted to Exchange Windows Permissions over domain"
} catch {
    Write-Host "[objects] Exchange WriteDACL may already be set: $_"
}

Write-Host "[objects] Granting Organization Management WriteProperty over Exchange Windows Permissions membership..."
try {
    $exchWPDN = (Get-ADGroup "Exchange Windows Permissions").DistinguishedName
    $orgMgmtSID = (Get-ADGroup "Organization Management").SID
    $acl = Get-Acl "AD:\$exchWPDN"
    $memberGuid = [Guid]"bf9679c0-0de6-11d0-a285-00aa003049e2"
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $orgMgmtSID,
        [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
        [System.Security.AccessControl.AccessControlType]::Allow,
        $memberGuid,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    )
    $acl.AddAccessRule($rule)
    Set-Acl "AD:\$exchWPDN" $acl
    Write-Host "[objects] WriteProperty over Exchange Windows Permissions member granted to Organization Management"
} catch {
    Write-Host "[objects] Organization Management ACL may already be set: $_"
}

Write-Host "[objects] Creating Exchange users and machine..."
New-User-IfMissing -Name "exch_admin" -Password "Exchange2024!" -Path "OU=Admins,OU=IT,$domainDN" -Description "Exchange administrator" -PasswordNeverExpires
Add-GroupMember-IfMissing -Group "Organization Management" -Member "exch_admin"

# Create EXCH01 computer account (simulated Exchange server)
try {
    $exchExists = Get-ADComputer "EXCH01" -ErrorAction SilentlyContinue
    if (-not $exchExists) {
        New-ADComputer -Name "EXCH01" -SamAccountName "EXCH01" -Path "OU=Servers,$domainDN" -Enabled $true
        Write-Host "[objects] Created computer EXCH01"
    }
} catch {
    Write-Host "[objects] EXCH01 computer may already exist"
}
Write-Host "[objects] Waiting for EXCH01$ to commit..."
$exch01Ready = $false
for ($i = 1; $i -le 5; $i++) {
    Start-Sleep 2
    try {
        $null = Get-ADComputer "EXCH01" -ErrorAction Stop
        $exch01Ready = $true
        break
    } catch {
        Write-Host "[objects] EXCH01$ not yet visible, attempt $i/5..."
    }
}
if ($exch01Ready) {
    Add-GroupMember-IfMissing -Group "Exchange Trusted Subsystem" -Member "EXCH01$"
} else {
    Write-Host "[objects] WARNING: EXCH01$ not visible after waiting. Skipping group membership."
}

# ══════════════════════════════════════════════════════════════════════════
# Cross-domain trust exploitation setup (it.secscope.corp)
# After dc03 subdomain is promoted, the trust accounts are created:
#   - IT$ in secscope.corp (trust account, stores trust key)
#   - SECSCOPE$ in it.secscope.corp
# The trust key stored in IT$ NT hash can be used to forge inter-realm
# TGTs. Member of Domain Admins can dump IT$ hash via DCSync.
# Additionally, subdomain Enterprise Admins are nested into parent
# domain Administrators group for SID History abuse.
# ══════════════════════════════════════════════════════════════════════════

Write-Host "[objects] NOTE: Cross-domain trust will be established when dc03 (it.secscope.corp) joins the forest."
Write-Host "[objects] The IT$ trust account in secscope.corp stores the inter-realm trust key."
Write-Host "[objects] To exploit: DCSync IT$ -> forge inter-realm TGT -> Enterprise Admin in subdomain."

Write-Host "[objects] All AD objects and misconfigurations created"
