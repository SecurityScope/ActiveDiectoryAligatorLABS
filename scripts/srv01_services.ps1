$ErrorActionPreference = "Continue"

Write-Host "[srv01_services] Starting service installation..."

$domain    = $env:DOMAIN
$adminPass = $env:ADMIN_PASS

Write-Host "[srv01_services] Installing IIS..."
Install-WindowsFeature -Name Web-Server, Web-Mgmt-Tools -IncludeManagementTools
Write-Host "[srv01_services] IIS installed"

Write-Host "[srv01_services] Downloading SQL Server Express..."
$sqlInstalled = $false
if (Get-Service "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue) {
    Write-Host "[srv01_services] SQLEXPRESS instance already present, skipping install"
    $sqlInstalled = $true
}
if (-not $sqlInstalled) {
try {
    # SQL2022-SSEI-Expr.exe is only a ~4MB web bootstrapper; /ACTION=Install on it
    # does NOT reliably create an engine instance. Use it to DOWNLOAD the full
    # media package, extract the self-extracting SQLEXPR archive, then run its
    # real setup.exe with the unattended parameters.
    $sqlUrl   = "https://download.microsoft.com/download/5/1/4/5145fe04-4d30-4b85-b0d1-39533663a2f1/SQL2022-SSEI-Expr.exe"
    $ssei     = "C:\Temp\SQL2022-SSEI-Expr.exe"
    $mediaDir = "C:\SQLMedia"
    $extract  = "C:\SQLExtract"
    New-Item -ItemType Directory -Force -Path C:\Temp | Out-Null
    Invoke-WebRequest -Uri $sqlUrl -OutFile $ssei -TimeoutSec 300 -ErrorAction Stop
    Write-Host "[srv01_services] SSEI downloaded, fetching full media (this can take a few minutes)..."
    Start-Process $ssei -ArgumentList "/ACTION=Download /MEDIAPATH=$mediaDir /MEDIATYPE=Core /QUIET" -Wait
    $expr = Get-ChildItem $mediaDir -Filter "SQLEXPR*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $expr) { throw "Full media download failed; no SQLEXPR*.exe in $mediaDir" }
    Write-Host "[srv01_services] Extracting $($expr.Name)..."
    Start-Process $expr.FullName -ArgumentList "/Q /X:$extract" -Wait
    Write-Host "[srv01_services] Installing SQL engine from extracted media..."
    # /SQLSYSADMINACCOUNTS must name a principal SQL setup can resolve or the
    # install aborts. SECSCOPE\SQLAdmins is created by dc01_objects.ps1 - if that
    # hasn't propagated (or the group isn't resolvable yet), fall back to
    # SECSCOPE\Domain Admins (always present) so the engine still installs. The
    # SQLAdmins sysadmin role is re-asserted later via T-SQL in any case.
    $sysadminAccounts = "SECSCOPE\Domain Admins"
    try {
        $null = (New-Object System.Security.Principal.NTAccount("SECSCOPE","SQLAdmins")).Translate([System.Security.Principal.SecurityIdentifier])
        $sysadminAccounts = "SECSCOPE\SQLAdmins SECSCOPE\Domain Admins"
        Write-Host "[srv01_services] SQLAdmins group resolved; using it for SQL sysadmin"
    } catch {
        Write-Host "[srv01_services] WARNING: SECSCOPE\SQLAdmins not resolvable yet; installing with Domain Admins as sysadmin"
    }
    Start-Process "$extract\SETUP.EXE" -ArgumentList "/Q /ACTION=Install /FEATURES=SQLEngine /INSTANCENAME=SQLEXPRESS /SECURITYMODE=SQL /SAPWD=`"$adminPass`" /SQLSYSADMINACCOUNTS=`"$sysadminAccounts`" /TCPENABLED=1 /NPENABLED=1 /IACCEPTSQLSERVERLICENSETERMS" -Wait
    if (Get-Service "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue) {
        Write-Host "[srv01_services] SQL Server Express installed"
        $sqlInstalled = $true
    } else {
        Write-Host "[srv01_services] WARNING: SQL setup ran but MSSQL`$SQLEXPRESS service not found"
    }
} catch {
    Write-Host "[srv01_services] WARNING: SQL install failed: $_"
}
}

Write-Host "[srv01_services] Starting SQL Express service..."
Start-Service MSSQL'$'SQLEXPRESS -ErrorAction SilentlyContinue
Start-Sleep 15

Write-Host "[srv01_services] Enabling xp_cmdshell..."
$connected = $false
for ($i = 1; $i -le 5; $i++) {
    try {
        $sqlConn = New-Object System.Data.SqlClient.SqlConnection(
            "Server=(local)\SQLEXPRESS;User Id=sa;Password=$adminPass;")
        $sqlConn.Open()
        $sqlCmd = $sqlConn.CreateCommand()
        $sqlCmd.CommandText = "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'xp_cmdshell', 1; RECONFIGURE;"
        $sqlCmd.ExecuteNonQuery() | Out-Null
        $sqlConn.Close()
        $connected = $true
        Write-Host "[srv01_services] xp_cmdshell enabled (attempt $i)"
        break
    } catch {
        Write-Host "[srv01_services] SQL connect attempt $i/5, waiting..."
        Start-Sleep 10
    }
}
if (-not $connected) {
    Write-Host "[srv01_services] WARNING: Could not enable xp_cmdshell after 5 attempts"
}

Write-Host "[srv01_services] Installing ADCS (Certificate Authority)..."
Install-WindowsFeature -Name AD-Certificate, ADCS-Cert-Authority, ADCS-Web-Enrollment -IncludeManagementTools
$secPass = ConvertTo-SecureString $adminPass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("SECSCOPE\Administrator", $secPass)

try {
    Install-AdcsCertificationAuthority `
        -CAType EnterpriseRootCa `
        -CACommonName "SecScope-CA" `
        -KeyLength 2048 `
        -HashAlgorithmName SHA256 `
        -Credential $cred `
        -Force `
        -ErrorAction Stop
    Write-Host "[srv01_services] CA installed"
} catch {
    Write-Host "[srv01_services] CA already installed: $_"
}

try {
    Install-AdcsWebEnrollment -Force -ErrorAction Stop
    Write-Host "[srv01_services] Web Enrollment installed"
} catch {
    Write-Host "[srv01_services] Web Enrollment already installed: $_"
}
Write-Host "[srv01_services] ADCS installed"

Write-Host "[srv01_services] Creating ESC1 certificate template..."
try {
    Write-Host "[srv01_services] Installing RSAT-AD-PowerShell..."
    Install-WindowsFeature -Name RSAT-AD-PowerShell -IncludeManagementTools
    Import-Module ActiveDirectory -ErrorAction Stop
    # These objects live in the Configuration NC; the provisioner runs as the
    # local 'vagrant' account which has no AD write rights, so every AD call
    # must be made with domain credentials against a DC.
    $adServer = "$domain"
    $configNC = (Get-ADRootDSE -Server $adServer -Credential $cred).configurationNamingContext
    $templateContainer = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNC"
    $esc1TemplateDN = "CN=ESC1,$templateContainer"
    # A credentialed AD: drive so Get-Acl/Set-Acl also run as domain admin.
    Remove-PSDrive -Name ADCred -ErrorAction SilentlyContinue
    New-PSDrive -Name ADCred -PSProvider ActiveDirectory -Root "//RootDSE/" -Server $adServer -Credential $cred -Scope Global | Out-Null

    try {
        $exists = Get-ADObject -Identity $esc1TemplateDN -Server $adServer -Credential $cred -ErrorAction Stop
        Write-Host "[srv01_services] ESC1 template already exists"
    } catch {
        # Build ESC1 by CLONING the built-in 'User' template (a valid schema-v2
        # template) rather than hand-crafting attributes. A from-scratch object
        # is missing binary/flag attributes and a registered OID object, so the
        # CA silently rejects it (never appears in 'certutil -template'). Cloning
        # copies every required attribute; we then flip the ESC1 vuln settings.
        $userDN  = "CN=User,$templateContainer"
        $userTpl = Get-ADObject -Identity $userDN -Properties * -Server $adServer -Credential $cred

        # Register a unique OID object in the OID container (required for v2).
        $oidContainer = "CN=OID,CN=Public Key Services,CN=Services,$configNC"
        $forestOID    = ($userTpl.'msPKI-Cert-Template-OID' -replace '\.\d+\.\d+$','')
        $suffix       = "{0}.{1}" -f (Get-Random -Minimum 1000000 -Maximum 99999999), (Get-Random -Minimum 10000000 -Maximum 99999999)
        $esc1OID      = "$forestOID.$suffix"
        $oidName      = [System.Guid]::NewGuid().ToString().Replace('-','')
        $oidAttrs = @{
            "DisplayName"             = "ESC1"
            "flags"                   = 1
            "msPKI-Cert-Template-OID" = $esc1OID
        }
        New-ADObject -Name $oidName -Type "msPKI-Enterprise-Oid" -Path $oidContainer `
            -OtherAttributes $oidAttrs -Server $adServer -Credential $cred
        Write-Host "[srv01_services] Registered ESC1 OID object ($esc1OID)"

        # Copy every meaningful attribute from User, then override for ESC1.
        $copyAttrs = @{}
        $copyFrom = @(
            'flags','msPKI-Certificate-Name-Flag','msPKI-Enrollment-Flag',
            'msPKI-Minimal-Key-Size','msPKI-Private-Key-Flag','msPKI-RA-Signature',
            'msPKI-Template-Minor-Revision','msPKI-Template-Schema-Version',
            'pKICriticalExtensions','pKIDefaultCSPs','pKIDefaultKeySpec',
            'pKIExpirationPeriod','pKIExtendedKeyUsage','pKIKeyUsage',
            'pKIMaxIssuingDepth','pKIOverlapPeriod','revision'
        )
        foreach ($p in $copyFrom) {
            $val = $userTpl.$p
            if ($null -ne $val) { $copyAttrs[$p] = $val }
        }
        # ESC1 overrides:
        $copyAttrs["displayName"]                 = "ESC1"
        $copyAttrs["msPKI-Cert-Template-OID"]     = $esc1OID
        # ENROLLEE_SUPPLIES_SUBJECT (0x1) — the core ESC1 misconfiguration.
        $copyAttrs["msPKI-Certificate-Name-Flag"] = 1
        # No manager approval, no RA signatures, publish to AD.
        $copyAttrs["msPKI-Enrollment-Flag"]       = 0
        $copyAttrs["msPKI-RA-Signature"]          = 0
        # Client Authentication EKU so the cert can be used for auth.
        $copyAttrs["pKIExtendedKeyUsage"]         = @("1.3.6.1.5.5.7.3.2")
        $copyAttrs["msPKI-Certificate-Application-Policy"] = @("1.3.6.1.5.5.7.3.2")

        New-ADObject -Name "ESC1" `
            -Type "pKICertificateTemplate" `
            -Path $templateContainer `
            -OtherAttributes $copyAttrs `
            -Server $adServer -Credential $cred
        Write-Host "[srv01_services] ESC1 template object created (cloned from User)"

        Start-Sleep 5

        $domainUsersSID = (Get-ADGroup "Domain Users" -Server $adServer -Credential $cred).SID
        $acl = Get-Acl "ADCred:\$esc1TemplateDN"
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $domainUsersSID,
            [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
            [System.Security.AccessControl.AccessControlType]::Allow,
            [Guid]"0e10c968-78fb-11d2-90d4-00c04f79dc55",
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
        )
        $acl.AddAccessRule($rule)
        Set-Acl "ADCred:\$esc1TemplateDN" $acl
        Write-Host "[srv01_services] Domain Users granted Enroll on ESC1 template"

        # Give AD a moment to replicate the new template to the CA's DC before
        # publishing. The publish loop below also pulses/retries.
        Start-Sleep 15

        Write-Host "[srv01_services] Publishing ESC1 template to CA..."
        $published = $false
        for ($p = 1; $p -le 6; $p++) {
            certutil -pulse 2>&1 | Out-Null
            certutil -setCAtemplates +"ESC1" 2>&1 | Out-Null
            if ((certutil -CATemplates 2>&1 | Select-String -Quiet "ESC1")) {
                $published = $true
                Write-Host "[srv01_services] ESC1 template published to CA (attempt $p)"
                break
            }
            Write-Host "[srv01_services] Publish attempt $p/6, waiting for replication..."
            Start-Sleep 15
        }
        if (-not $published) {
            Write-Host "[srv01_services] WARNING: ESC1 created but CA publish not confirmed; run 'certutil -setCAtemplates +ESC1' after replication."
        }
    }
    Write-Host "[srv01_services] ESC1 template configured (ENROLLEE_SUPPLIES_SUBJECT, Client Auth EKU, Domain Users enroll)"
} catch {
    Write-Host "[srv01_services] ESC1 template creation failed: $_"
    Write-Host "[srv01_services] Manual: certsrv.msc -> Duplicate 'User' -> Supply in request -> Domain Users Enroll"
}

Write-Host "[srv01_services] Done"
