$ErrorActionPreference = "Continue"

Write-Host "[srv01_services] Starting service installation..."

$domain    = $env:DOMAIN
$adminPass = $env:ADMIN_PASS

Write-Host "[srv01_services] Installing IIS..."
Install-WindowsFeature -Name Web-Server, Web-Mgmt-Tools -IncludeManagementTools
Write-Host "[srv01_services] IIS installed"

Write-Host "[srv01_services] Downloading SQL Server Express..."
try {
    $sqlUrl  = "https://download.microsoft.com/download/5/1/4/5145fe04-4d30-4b85-b0d1-39533663a2f1/SQL2022-SSEI-Expr.exe"
    $sqlPath = "C:\Temp\sqlexpress.exe"
    New-Item -ItemType Directory -Force -Path C:\Temp | Out-Null
    Invoke-WebRequest -Uri $sqlUrl -OutFile $sqlPath -TimeoutSec 120 -ErrorAction Stop
    Write-Host "[srv01_services] SQL downloaded, installing..."
    Start-Process $sqlPath -ArgumentList "/Q /ACTION=Install /FEATURES=SQLEngine /INSTANCENAME=SQLEXPRESS /SECURITYMODE=SQL /SAPWD=`"$adminPass`" /SQLSYSADMINACCOUNTS=`"SECSCOPE\SQLAdmins`" /TCPENABLED=1 /NPENABLED=1 /IACCEPTSQLSERVERLICENSETERMS" -Wait
    Write-Host "[srv01_services] SQL Server Express installed"
} catch {
    Write-Host "[srv01_services] WARNING: SQL download failed. Install SQL Server Express manually."
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
    $configNC = (Get-ADRootDSE).configurationNamingContext
    $templateContainer = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNC"
    $esc1TemplateDN = "CN=ESC1,$templateContainer"

    try {
        $exists = Get-ADObject -Identity $esc1TemplateDN -ErrorAction Stop
        Write-Host "[srv01_services] ESC1 template already exists"
    } catch {
        $otherAttrs = @{
            "displayName"                      = "ESC1"
            "msPKI-Cert-Template-OID"          = "1.3.6.1.4.1.311.21.8.9999999.1"
            "msPKI-Certificate-Name-Flag"      = 1
            "msPKI-Enrollment-Flag"            = 0
            "msPKI-RA-Signature"               = 0
            "msPKI-Minimal-Key-Size"           = 2048
            "msPKI-Template-Schema-Version"    = 2
            "msPKI-Template-Minor-Revision"    = 0
            "msPKI-Certificate-Application-Policy" = @("1.3.6.1.5.5.7.3.2")
            "pKIExtendedKeyUsage"              = @("1.3.6.1.5.5.7.3.2")
            "revision"                         = 100
            "pKIDefaultKeySpec"                = 1
            "pKIMaxIssuingDepth"               = 0
            "flags"                            = 131680
        }
        New-ADObject -Name "ESC1" `
            -Type "pKICertificateTemplate" `
            -Path $templateContainer `
            -OtherAttributes $otherAttrs
        Write-Host "[srv01_services] ESC1 template object created"

        Start-Sleep 5

        $domainUsersSID = (Get-ADGroup "Domain Users").SID
        $acl = Get-Acl "AD:\$esc1TemplateDN"
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $domainUsersSID,
            [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
            [System.Security.AccessControl.AccessControlType]::Allow,
            [Guid]"0e10c968-78fb-11d2-90d4-00c04f79dc55",
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
        )
        $acl.AddAccessRule($rule)
        Set-Acl "AD:\$esc1TemplateDN" $acl
        Write-Host "[srv01_services] Domain Users granted Enroll on ESC1 template"

        Write-Host "[srv01_services] Publishing ESC1 template to CA..."
        try {
            certutil -setCAtemplates +"ESC1" 2>&1 | Out-Null
            Write-Host "[srv01_services] ESC1 template published to CA"
        } catch {
            Write-Host "[srv01_services] CA template binding may need manual step: $_"
        }
    }
    Write-Host "[srv01_services] ESC1 template configured (ENROLLEE_SUPPLIES_SUBJECT, Client Auth EKU, Domain Users enroll)"
} catch {
    Write-Host "[srv01_services] ESC1 template creation failed: $_"
    Write-Host "[srv01_services] Manual: certsrv.msc -> Duplicate 'User' -> Supply in request -> Domain Users Enroll"
}

Write-Host "[srv01_services] Done"
