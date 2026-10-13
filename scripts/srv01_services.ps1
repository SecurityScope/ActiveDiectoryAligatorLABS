$ErrorActionPreference = "Continue"

Write-Host "[srv01_services] Starting service installation..."

$domain    = $env:DOMAIN
$adminPass = $env:ADMIN_PASS

Write-Host "[srv01_services] Installing IIS..."
Install-WindowsFeature -Name Web-Server, Web-Mgmt-Tools -IncludeManagementTools
Write-Host "[srv01_services] IIS installed"

# ── PowerShell Web Access (PSWA) ──────────────────────────────────────────
# The lab material (09_Lateral_Movement.md) references PSWA on SRV01 at the
# /pswa endpoint (HTTPS 443). Install + configure the gateway with a self-signed
# cert and a permissive authorization rule so Domain Users can reach it. PSWA is
# deprecated but still installable on Server 2022. Idempotent + non-fatal.
Write-Host "[srv01_services] Installing PowerShell Web Access (PSWA)..."
try {
    if ((Get-WindowsFeature WindowsPowerShellWebAccess).InstallState -ne "Installed") {
        Install-WindowsFeature -Name WindowsPowerShellWebAccess -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-Host "[srv01_services] PSWA feature installed"
    } else {
        Write-Host "[srv01_services] PSWA feature already installed"
    }
    Import-Module PowerShellWebAccess -ErrorAction SilentlyContinue
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    # Create the /pswa IIS web app on HTTPS 443 (idempotent).
    if (-not (Get-WebApplication -Name "pswa" -Site "Default Web Site" -ErrorAction SilentlyContinue)) {
        Install-PswaWebApplication -WebApplicationName "pswa" -UseTestCertificate -ErrorAction Stop
        Write-Host "[srv01_services] PSWA web app published at https://srv01.secscope.corp/pswa"
    } else {
        Write-Host "[srv01_services] PSWA web app already present"
    }
    # Install-PswaWebApplication -UseTestCertificate issues a SHA-1 cert, which
    # modern browsers (and .NET/Schannel) REJECT - the TLS handshake fails before
    # the page loads ("can't establish a secure connection"). Replace the 443
    # binding with a SHA-256 self-signed cert so PSWA is actually reachable.
    $bound = netsh http show sslcert ipport=0.0.0.0:443 2>$null | Select-String "Certificate Hash\s*:\s*([0-9a-fA-F]+)"
    $needCert = $true
    if ($bound) {
        $th = ($bound.Matches[0].Groups[1].Value)
        $cur = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $th }
        if ($cur -and $cur.SignatureAlgorithm.FriendlyName -eq "sha256RSA") { $needCert = $false }
    }
    if ($needCert) {
        $sha256 = New-SelfSignedCertificate -DnsName "srv01.secscope.corp","srv01","192.168.200.20" `
            -CertStoreLocation Cert:\LocalMachine\My -HashAlgorithm SHA256 -KeyLength 2048 -NotAfter (Get-Date).AddYears(5)
        Remove-Item "IIS:\SslBindings\0.0.0.0!443" -ErrorAction SilentlyContinue
        New-Item "IIS:\SslBindings\0.0.0.0!443" -Value $sha256 | Out-Null
        Write-Host "[srv01_services] Replaced PSWA test cert with a SHA-256 cert on 443"
    } else {
        Write-Host "[srv01_services] PSWA 443 cert already SHA-256"
    }
    # Authorization rule (permissive, for the lab): any user -> any computer -> any
    # session config. Must use the wildcard '*' form, NOT a -UserGroupName rule:
    # this provisioner runs as the LOCAL account srv01\vagrant, which cannot perform
    # the AD query a group rule needs ("must be run by a user account with
    # permissions to perform Active Directory queries"). '*' needs no AD lookup.
    if (-not (Get-PswaAuthorizationRule -ErrorAction SilentlyContinue)) {
        Add-PswaAuthorizationRule -UserName * -ComputerName * -ConfigurationName * -ErrorAction Stop | Out-Null
        Write-Host "[srv01_services] PSWA authorization rule added (* -> * -> *)"
    } else {
        Write-Host "[srv01_services] PSWA authorization rule already present"
    }
} catch {
    Write-Host "[srv01_services] WARNING: PSWA setup incomplete: $_"
}

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
    # Use Microsoft's permanent fwlink redirect, NOT a hardcoded download.microsoft.com
    # path (those rotate and 404 - the old direct URL returned a 404 HTML page that
    # got logged as the "SQL install failed" error). Offline-first: if a bundled
    # SQL2022-SSEI-Expr.exe is dropped in the repo root it is used instead.
    $sqlUrl   = "https://go.microsoft.com/fwlink/?linkid=2216019"
    $ssei     = "C:\Temp\SQL2022-SSEI-Expr.exe"
    if (Test-Path "C:\vagrant\SQL2022-SSEI-Expr.exe") {
        New-Item -ItemType Directory -Force -Path C:\Temp | Out-Null
        Copy-Item "C:\vagrant\SQL2022-SSEI-Expr.exe" $ssei -Force
        Write-Host "[srv01_services] Using bundled SQL installer from C:\vagrant"
    }
    $mediaDir = "C:\SQLMedia"
    $extract  = "C:\SQLExtract"
    New-Item -ItemType Directory -Force -Path C:\Temp | Out-Null
    if (-not (Test-Path $ssei)) {
        Invoke-WebRequest -Uri $sqlUrl -OutFile $ssei -TimeoutSec 300 -ErrorAction Stop
    }
    Write-Host "[srv01_services] SSEI ready, fetching full media (this can take a few minutes)..."
    Start-Process $ssei -ArgumentList "/ACTION=Download /MEDIAPATH=$mediaDir /MEDIATYPE=Core /QUIET" -Wait
    $expr = Get-ChildItem $mediaDir -Filter "SQLEXPR*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $expr) { throw "Full media download failed; no SQLEXPR*.exe in $mediaDir" }
    Write-Host "[srv01_services] Extracting $($expr.Name)..."
    Start-Process $expr.FullName -ArgumentList "/Q /X:$extract" -Wait
    Write-Host "[srv01_services] Installing SQL engine from extracted media..."
    # /SQLSYSADMINACCOUNTS takes ONE account here. Multiple accounts must each be
    # SEPARATELY quoted ("a" "b"); cramming two into one quoted string makes Setup
    # treat it as a single invalid account and fail silently under /Q (this is why
    # the earlier 'SQLAdmins Domain Admins' value left MSSQL$SQLEXPRESS uninstalled).
    # Prefer SECSCOPE\SQLAdmins; fall back to SECSCOPE\Domain Admins (always present)
    # if the group isn't resolvable yet.
    $sysadminAccounts = "SECSCOPE\Domain Admins"
    try {
        $null = (New-Object System.Security.Principal.NTAccount("SECSCOPE","SQLAdmins")).Translate([System.Security.Principal.SecurityIdentifier])
        $sysadminAccounts = "SECSCOPE\SQLAdmins"
        Write-Host "[srv01_services] SQLAdmins group resolved; using it for SQL sysadmin"
    } catch {
        Write-Host "[srv01_services] WARNING: SECSCOPE\SQLAdmins not resolvable yet; installing with Domain Admins as sysadmin"
    }
    $sqlProc = Start-Process "$extract\SETUP.EXE" -ArgumentList "/Q /ACTION=Install /FEATURES=SQLEngine /INSTANCENAME=SQLEXPRESS /SECURITYMODE=SQL /SAPWD=`"$adminPass`" /SQLSYSADMINACCOUNTS=`"$sysadminAccounts`" /TCPENABLED=1 /NPENABLED=1 /IACCEPTSQLSERVERLICENSETERMS" -Wait -PassThru
    Write-Host "[srv01_services] SQL SETUP.EXE exit code: $($sqlProc.ExitCode)"
    if (Get-Service "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue) {
        Write-Host "[srv01_services] SQL Server Express installed"
        $sqlInstalled = $true
    } else {
        Write-Host "[srv01_services] WARNING: SQL setup ran (exit $($sqlProc.ExitCode)) but MSSQL`$SQLEXPRESS not found. Check C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt"
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

Write-Host "[srv01_services] Creating a linked SQL server (SQL-links lateral path)..."
if ($connected) {
    try {
        $sqlConn = New-Object System.Data.SqlClient.SqlConnection(
            "Server=(local)\SQLEXPRESS;User Id=sa;Password=$adminPass;")
        $sqlConn.Open()
        $sqlCmd = $sqlConn.CreateCommand()
        # Self-referential linked server with 'rpc out' + an sa login mapping. Lets
        # an attacker on SQLEXPRESS enumerate links (sys.servers / sp_linkedservers)
        # and pivot via  EXEC ('...') AT [SRV01_LINK]  / OPENQUERY - the classic
        # MSSQL linked-server exercise (Module 10). Single instance, so it loops
        # back to itself, which is enough to practise the technique end-to-end.
        $sqlCmd.CommandText = @"
IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = 'SRV01_LINK')
BEGIN
    EXEC sp_addlinkedserver @server=N'SRV01_LINK', @srvproduct=N'', @provider=N'SQLNCLI', @datasrc=N'SRV01\SQLEXPRESS';
    EXEC sp_serveroption @server=N'SRV01_LINK', @optname=N'rpc out', @optvalue=N'true';
    EXEC sp_serveroption @server=N'SRV01_LINK', @optname=N'data access', @optvalue=N'true';
    EXEC sp_addlinkedsrvlogin @rmtsrvname=N'SRV01_LINK', @useself=N'false', @locallogin=NULL, @rmtuser=N'sa', @rmtpassword=N'$adminPass';
END
"@
        $sqlCmd.ExecuteNonQuery() | Out-Null
        $sqlConn.Close()
        Write-Host "[srv01_services] Linked server SRV01_LINK created (rpc out enabled)"
    } catch {
        Write-Host "[srv01_services] WARNING: linked server setup failed: $_"
    }
} else {
    Write-Host "[srv01_services] Skipping linked server (SQL not reachable)"
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

# ── WebDAV (server) + WebClient (HTTP->LDAP / ADCS-ESC8 relay coercion target) ─
Write-Host "[srv01_services] Enabling WebDAV + WebClient (relay/coercion target)..."
try {
    Install-WindowsFeature -Name Web-DAV-Publishing -ErrorAction SilentlyContinue | Out-Null
    # WebClient (the WebDAV client redirector) is what lets this host be coerced
    # into authenticating to an attacker over HTTP, enabling NTLM relay to LDAP/ADCS
    # (Module 09/10). The feature may need a reboot before the service registers.
    Install-WindowsFeature -Name WebDAV-Redirector -ErrorAction SilentlyContinue | Out-Null
    $wc = Get-Service WebClient -ErrorAction SilentlyContinue
    if ($wc) {
        Set-Service WebClient -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service WebClient -ErrorAction SilentlyContinue
        Write-Host "[srv01_services] WebClient service enabled + started"
    } else {
        Write-Host "[srv01_services] WebClient not present yet (WebDAV-Redirector registers it after a reboot)"
    }
} catch {
    Write-Host "[srv01_services] WARNING: WebDAV/WebClient setup incomplete: $_"
}

# ── DHCP server role (Module 04 DHCP enumeration target) ──────────────────────
# Scope is OUTSIDE the lab's static range (.10-.99) so it never hands a lab host a
# conflicting lease - the whole lab is static, so nothing sends DHCP DISCOVER.
# Authorizing a DHCP server needs Enterprise Admin, which this local-account
# provisioner may lack; the role + scope stay enumerable even if auth is skipped.
Write-Host "[srv01_services] Installing DHCP server role (enumeration target)..."
try {
    if ((Get-WindowsFeature DHCP).InstallState -ne "Installed") {
        Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-Host "[srv01_services] DHCP role installed"
    } else {
        Write-Host "[srv01_services] DHCP role already installed"
    }
    Import-Module DhcpServer -ErrorAction SilentlyContinue
    try {
        Add-DhcpServerInDC -DnsName "srv01.$domain" -IPAddress 192.168.200.20 -ErrorAction Stop
        Write-Host "[srv01_services] DHCP server authorized in AD"
    } catch {
        Write-Host "[srv01_services] NOTE: DHCP AD authorization skipped (needs Enterprise Admin): $_"
    }
    if (-not (Get-DhcpServerv4Scope -ScopeId 192.168.200.0 -ErrorAction SilentlyContinue)) {
        Add-DhcpServerv4Scope -Name "LabScope" -StartRange 192.168.200.200 -EndRange 192.168.200.220 `
            -SubnetMask 255.255.255.0 -State Active -ErrorAction SilentlyContinue
        Set-DhcpServerv4OptionValue -ScopeId 192.168.200.0 -DnsServer 192.168.200.10 `
            -Router 192.168.200.1 -ErrorAction SilentlyContinue
        Write-Host "[srv01_services] DHCP scope 192.168.200.200-220 created (non-conflicting)"
    } else {
        Write-Host "[srv01_services] DHCP scope already present"
    }
} catch {
    Write-Host "[srv01_services] WARNING: DHCP setup incomplete: $_"
}

Write-Host "[srv01_services] Done"
