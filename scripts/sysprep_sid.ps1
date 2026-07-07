$ErrorActionPreference = "Continue"

Write-Host "[sysprep] Creating unattend file..."
$unattend = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>vagrant</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <AutoLogon>
                <Password>
                    <Value>vagrant</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Username>Administrator</Username>
                <Enabled>true</Enabled>
            </AutoLogon>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>*</ComputerName>
        </component>
    </settings>
</unattend>
'@

$unattendPath = "C:\Windows\Temp\unattend_sid.xml"
$unattend | Out-File -FilePath $unattendPath -Encoding UTF8
Write-Host "[sysprep] Unattend file written to $unattendPath"

Write-Host "[sysprep] Launching sysprep /generalize /oobe /reboot..."
$proc = Start-Process -FilePath "C:\Windows\System32\Sysprep\sysprep.exe" `
    -ArgumentList "/generalize", "/oobe", "/reboot", "/unattend:$unattendPath" `
    -Wait:$false -PassThru
Write-Host "[sysprep] Sysprep launched (PID $($proc.Id)). Machine will reboot shortly."
Start-Sleep 5
if ($proc.HasExited -and $proc.ExitCode -ne 0) {
    Write-Host "[sysprep] ERROR: Sysprep failed with exit code $($proc.ExitCode)"
    exit 1
}
Write-Host "[sysprep] After reboot, run: vagrant up <name> to reconnect."
