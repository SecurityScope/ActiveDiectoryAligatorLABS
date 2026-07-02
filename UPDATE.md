# Active Directory Alligator Labs — AI Agent Master Prompt

> **How to use:** Upload all existing project files alongside this document.
> Tell DeepSeek: "Read every uploaded file completely, confirm line counts,
> then follow this specification exactly. Plan first, then ask for approval
> before writing any code."

---

## 0. Project Overview

We are rebuilding and rebranding the **SecScope AD Lab** into
**Active Directory Alligator Labs** — a comprehensive Active Directory
penetration testing lab for security students.

### What changes
- Project branding and display name
- Box source: Vagrant Cloud → Packer-built boxes from UUP Dump ISOs
- Setup scripts: add resume logic, help flags, packer build steps
- GitHub structure: issue templates, logo placeholder

### What stays the same
- Domain: `secscope.corp` (baked into AD — cannot change)
- All IP addresses, credentials, VM names
- All provisioning scripts in `scripts/`
- All AD objects, users, groups, misconfigurations
- `vagrant_plugins/winrm_quiet.rb`
- `Vagrantfile` network and provisioner logic

---

## 1. New Folder & Branding

### 1.1 Project folder name
```
ActiveDirectoryAlligatorLABS/
```

### 1.2 Banner text replacements
Apply these renames in ALL display strings, banners, and echo messages:

| Old | New |
|-----|-----|
| SecScope AD Lab | Active Directory Alligator Labs |
| SecScope Lab | AD Alligator Labs |
| SecScope AD Lab — Setup Script | Active Directory Alligator Labs — Setup Script |
| SecScope Lab — Build Packer Boxes | AD Alligator Labs — Build Packer Boxes |

### 1.3 DO NOT rename these (technical — baked into AD)
- `secscope.corp`
- `SECSCOPE`
- `child.secscope.corp`
- Any IP addresses
- Any user/group/OU names
- Any provisioner script content

---

## 2. Final Project Structure

```
ActiveDirectoryAlligatorLABS/
├── Vagrantfile
├── setup.sh
├── setup.ps1
├── build-boxes.sh
├── build-boxes.ps1
├── README.md
├── INSTALL.md
├── LOGO.md
├── .gitignore
├── .gitattributes
├── .github/
│   └── ISSUE_TEMPLATE/
│       ├── bug_report.md
│       └── feature_request.md
├── assets/
│   └── .gitkeep
├── scripts/              ← existing, unchanged
│   ├── common_windows.ps1
│   ├── dc01_base.ps1
│   ├── dc01_postboot.ps1
│   ├── dc01_dns.ps1
│   ├── dc01_objects.ps1
│   ├── dc02_base.ps1
│   ├── dc02_join.ps1
│   ├── dc03_base.ps1
│   ├── dc03_join.ps1
│   ├── srv01_join.ps1
│   ├── srv01_services.ps1
│   ├── ws01_join.ps1
│   ├── ws01_misconfig.ps1
│   ├── ws02_join.ps1
│   ├── ws02_misconfig.ps1
│   ├── lin01_setup.sh
│   └── harden_windows.ps1
├── configs/              ← existing, unchanged
│   ├── krb5.conf
│   └── sssd.conf
├── vagrant_plugins/      ← existing, unchanged
│   └── winrm_quiet.rb
├── iso/                  ← new, empty (students put ISOs here)
│   └── .gitkeep
└── packer/               ← new
    ├── UUP_DUMP_INSTRUCTIONS.md
    ├── windows-server-2022/
    │   ├── windows-server-2022.pkr.hcl
    │   ├── variables.pkrvars.hcl
    │   ├── vagrantfile-template.rb
    │   ├── autounattend/
    │   │   └── Autounattend.xml
    │   ├── scripts/
    │   │   ├── setup_winrm.ps1
    │   │   ├── setup_vagrant.ps1
    │   │   ├── install_vboxga.ps1
    │   │   ├── optimize.ps1
    │   │   └── cleanup.ps1
    │   └── boxes/
    │       └── .gitkeep
    └── windows-10-enterprise/
        ├── windows-10-enterprise.pkr.hcl
        ├── variables.pkrvars.hcl
        ├── vagrantfile-template.rb
        ├── autounattend/
        │   └── Autounattend.xml
        ├── scripts/
        │   ├── setup_winrm.ps1
        │   ├── setup_vagrant.ps1
        │   ├── install_vboxga.ps1
        │   ├── optimize.ps1
        │   └── cleanup.ps1
        └── boxes/
            └── .gitkeep
```

---

## 3. Vagrantfile Changes

### 3.1 Add USE_LOCAL_BOXES toggle at the very top

Insert before the existing plugin auto-install block:

```ruby
# ─── Box Source Configuration ─────────────────────────────────────────────
# Set USE_LOCAL_BOXES=true after running build-boxes.sh
# Set USE_LOCAL_BOXES=false (default) to use Vagrant Cloud boxes
USE_LOCAL_BOXES = ENV.fetch("USE_LOCAL_BOXES", "false") == "true"

SERVER_BOX = USE_LOCAL_BOXES ?
  "secscope/windows-server-2022" :
  "gusztavvargadr/windows-server-2022-standard"

WORKSTATION_BOX = USE_LOCAL_BOXES ?
  "secscope/windows-10-enterprise" :
  "gusztavvargadr/windows-10-22h2-enterprise"
# ──────────────────────────────────────────────────────────────────────────
```

### 3.2 Replace all hardcoded box names

In every Windows Server VM definition change:
```ruby
vm.vm.box = "gusztavvargadr/windows-server-2022-standard"
```
To:
```ruby
vm.vm.box = SERVER_BOX
```

In every Windows 10 VM definition change:
```ruby
vm.vm.box = "gusztavvargadr/windows-10-22h2-enterprise"
```
To:
```ruby
vm.vm.box = WORKSTATION_BOX
```

Debian lin01 stays unchanged: `vm.vm.box = "debian/bookworm64"`

### 3.3 No other Vagrantfile changes
Do not touch provisioners, IPs, ports, triggers, or any other config.

---

## 4. Packer Templates

### 4.1 Windows Server 2022
File: `packer/windows-server-2022/windows-server-2022.pkr.hcl`

```hcl
packer {
  required_plugins {
    virtualbox = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/virtualbox"
    }
  }
}

variable "iso_path" {
  type        = string
  default     = "../../iso/windows-server-2022.iso"
  description = "Path to Windows Server 2022 ISO from UUP Dump"
}

variable "iso_checksum" {
  type        = string
  default     = "none"
  description = "SHA256 checksum. Get with: sha256sum your.iso"
}

variable "output_directory" {
  type    = string
  default = "builds/windows-server-2022"
}

variable "box_output" {
  type    = string
  default = "boxes/windows-server-2022.box"
}

source "virtualbox-iso" "windows-server-2022" {
  vm_name              = "packer-windows-server-2022"
  iso_url              = var.iso_path
  iso_checksum         = var.iso_checksum == "none" ? "none" : "sha256:${var.iso_checksum}"
  disk_size            = 61440
  memory               = 4096
  cpus                 = 4
  headless             = true
  guest_os_type        = "Windows2022_64"
  communicator         = "winrm"
  winrm_username       = "vagrant"
  winrm_password       = "vagrant"
  winrm_timeout        = "2h"
  winrm_use_ssl        = false
  winrm_insecure       = true
  shutdown_command     = "shutdown /s /t 10 /f /d p:4:1"
  shutdown_timeout     = "15m"
  output_directory     = var.output_directory
  guest_additions_mode = "attach"

  floppy_files = [
    "autounattend/Autounattend.xml",
    "scripts/setup_winrm.ps1",
    "scripts/setup_vagrant.ps1"
  ]

  boot_wait    = "3s"
  boot_command = ["<spacebar><spacebar>"]

  vboxmanage = [
    ["modifyvm", "{{.Name}}", "--vram", "128"],
    ["modifyvm", "{{.Name}}", "--graphicscontroller", "vboxsvga"],
    ["modifyvm", "{{.Name}}", "--nat-localhostreachable1", "on"],
    ["modifyvm", "{{.Name}}", "--audio", "none"],
    ["modifyvm", "{{.Name}}", "--usb", "off"],
    ["modifyvm", "{{.Name}}", "--clipboard", "disabled"]
  ]
}

build {
  name    = "windows-server-2022"
  sources = ["source.virtualbox-iso.windows-server-2022"]

  provisioner "windows-shell" {
    scripts = ["scripts/setup_winrm.ps1"]
  }

  provisioner "windows-shell" {
    scripts = ["scripts/setup_vagrant.ps1"]
  }

  provisioner "windows-shell" {
    scripts = ["scripts/install_vboxga.ps1"]
  }

  provisioner "windows-shell" {
    scripts = ["scripts/optimize.ps1"]
  }

  provisioner "windows-shell" {
    scripts = ["scripts/cleanup.ps1"]
  }

  post-processor "vagrant" {
    output               = var.box_output
    vagrantfile_template = "vagrantfile-template.rb"
    keep_input_artifact  = false
  }
}
```

### 4.2 Windows 10 Enterprise
File: `packer/windows-10-enterprise/windows-10-enterprise.pkr.hcl`

Same structure as Server 2022 with these differences:
- `vm_name`: `packer-windows-10-enterprise`
- `iso_path` default: `../../iso/windows-10-enterprise.iso`
- `output_directory` default: `builds/windows-10-enterprise`
- `box_output` default: `boxes/windows-10-enterprise.box`
- `guest_os_type`: `Windows10_64`
- `build name`: `windows-10-enterprise`
- All `[source...]` and `[build...]` references updated accordingly

### 4.3 variables.pkrvars.hcl (both boxes)

```hcl
# Copy this file and fill in your values
# Usage: packer build -var-file="my.pkrvars.hcl" .
iso_path     = "../../iso/windows-server-2022.iso"
iso_checksum = ""  # Leave empty to skip checksum verification
```

### 4.4 vagrantfile-template.rb (both boxes)

```ruby
# -*- mode: ruby -*-
Vagrant.configure("2") do |config|
  config.vm.guest        = :windows
  config.vm.communicator = "winrm"
  config.winrm.username  = "vagrant"
  config.winrm.password  = "vagrant"
  config.vm.provider "virtualbox" do |v|
    v.customize ["modifyvm", :id, "--memory", "2048"]
    v.customize ["modifyvm", :id, "--cpus", "2"]
  end
end
```

---

## 5. Autounattend.xml

### 5.1 Windows Server 2022
File: `packer/windows-server-2022/autounattend/Autounattend.xml`

Must include all these sections fully written out — no placeholders:

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <!-- windowsPE pass: disk setup + image selection -->
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Active>true</Active>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Order>1</Order>
              <PartitionID>1</PartitionID>
            </ModifyPartition>
          </ModifyPartitions>
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
        </Disk>
      </DiskConfiguration>

      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/NAME</Key>
              <Value>Windows Server 2022 SERVERSTANDARD</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>1</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>

      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Vagrant</FullName>
        <Organization>Vagrant</Organization>
      </UserData>

      <EnableFirewall>false</EnableFirewall>
    </component>
  </settings>

  <!-- specialize pass: computer name + regional -->
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>vagrant-build</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>

    <component name="Microsoft-Windows-ServerManager-SvrMgrNc"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <DoNotOpenServerManagerAtLogon>true</DoNotOpenServerManagerAtLogon>
    </component>
  </settings>

  <!-- oobeSystem pass: admin password + autologon + skip OOBE -->
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
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
        <Enabled>true</Enabled>
        <LogonCount>99</LogonCount>
        <Username>Administrator</Username>
      </AutoLogon>

      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>

      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell -ExecutionPolicy Bypass -File A:\setup_winrm.ps1</CommandLine>
          <Description>Setup WinRM</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <CommandLine>powershell -ExecutionPolicy Bypass -File A:\setup_vagrant.ps1</CommandLine>
          <Description>Setup Vagrant user</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>

</unattend>
```

### 5.2 Windows 10 Enterprise Autounattend.xml
Same structure with these differences:
- ImageName: `Windows 10 Enterprise`
- Add extra OOBE skip elements for Windows 10:
```xml
<SkipMachineOOBE>true</SkipMachineOOBE>
<SkipUserOOBE>true</SkipUserOOBE>
<HideEULAPage>true</HideEULAPage>
```
- Add in specialize pass:
```xml
<component name="Microsoft-Windows-Deployment" ...>
  <RunSynchronous>
    <RunSynchronousCommand wcm:action="add">
      <Order>1</Order>
      <Path>reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE /v DisablePrivacyExperience /t REG_DWORD /d 1 /f</Path>
    </RunSynchronousCommand>
  </RunSynchronous>
</component>
```

---

## 6. Packer Provisioner Scripts

### 6.1 setup_winrm.ps1 (both boxes — identical)

```powershell
$ErrorActionPreference = "Continue"
Write-Host "[winrm] Configuring WinRM..."

# Set execution policy
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Force

# Enable WinRM
winrm quickconfig -q
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# Configure WinRM settings
winrm set winrm/config '@{MaxTimeoutms="1800000"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/client '@{AllowUnencrypted="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'
winrm set winrm/config/listener?Address=*+Transport=HTTP '@{Port="5985"}'

# Set WinRM service to auto-start
Set-Service WinRM -StartupType Automatic
Start-Service WinRM

# Disable UAC
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name EnableLUA -Value 0 -Force

# Set network profile to Private
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Disable firewall
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

# Allow WinRM through firewall anyway
netsh advfirewall firewall add rule name="WinRM HTTP" `
    dir=in action=allow protocol=TCP localport=5985

Write-Host "[winrm] WinRM configured successfully"
```

### 6.2 setup_vagrant.ps1 (both boxes — identical)

```powershell
$ErrorActionPreference = "Continue"
Write-Host "[vagrant] Setting up Vagrant user..."

# Create vagrant user if not exists
$vagrantPass = ConvertTo-SecureString "vagrant" -AsPlainText -Force
try {
    New-LocalUser -Name "vagrant" -Password $vagrantPass `
        -PasswordNeverExpires $true -UserMayNotChangePassword $true `
        -ErrorAction Stop
    Write-Host "[vagrant] Created vagrant user"
} catch {
    Set-LocalUser -Name "vagrant" -Password $vagrantPass
    Write-Host "[vagrant] Updated vagrant user password"
}

# Add to Administrators
Add-LocalGroupMember -Group "Administrators" -Member "vagrant" `
    -ErrorAction SilentlyContinue
Write-Host "[vagrant] vagrant added to Administrators"

# Create .ssh directory
$sshDir = "C:\Users\vagrant\.ssh"
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

# Download Vagrant insecure public key
$keyUrl = "https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant.pub"
try {
    Invoke-WebRequest -Uri $keyUrl -OutFile "$sshDir\authorized_keys" -TimeoutSec 30
    Write-Host "[vagrant] Downloaded Vagrant public key"
} catch {
    # Hardcode the key as fallback
    $vagrantPubKey = "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant insecure public key"
    $vagrantPubKey | Out-File -FilePath "$sshDir\authorized_keys" -Encoding ASCII
    Write-Host "[vagrant] Used hardcoded Vagrant public key"
}

# Set correct permissions on .ssh
icacls $sshDir /inheritance:r /grant "vagrant:F" | Out-Null
icacls "$sshDir\authorized_keys" /inheritance:r /grant "vagrant:F" | Out-Null

# Install OpenSSH
try {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    Write-Host "[vagrant] OpenSSH Server installed and started"
} catch {
    Write-Host "[vagrant] OpenSSH install failed - WinRM will be used"
}

# Configure SSH authorized keys path
$regPath = "HKLM:\SOFTWARE\OpenSSH"
if (Test-Path $regPath) {
    New-ItemProperty -Path $regPath -Name DefaultShell `
        -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -PropertyType String -Force | Out-Null
}

Write-Host "[vagrant] Vagrant user setup complete"
```

### 6.3 install_vboxga.ps1 (both boxes — identical)

```powershell
$ErrorActionPreference = "Continue"
Write-Host "[vboxga] Installing VirtualBox Guest Additions..."

# Find attached VBoxGuestAdditions ISO
$drive = $null
foreach ($d in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match "^[D-Z]:\\" })) {
    if (Test-Path "$($d.Root)VBoxWindowsAdditions.exe") {
        $drive = $d.Root
        Write-Host "[vboxga] Found VBoxGuestAdditions at: $drive"
        break
    }
}

if (-not $drive) {
    Write-Host "[vboxga] ERROR: VBoxGuestAdditions ISO not found"
    exit 1
}

# Install silently
$installer = "${drive}VBoxWindowsAdditions.exe"
Write-Host "[vboxga] Running installer: $installer"
$proc = Start-Process -FilePath $installer `
    -ArgumentList "/S", "/with_autologon" `
    -Wait -PassThru

if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
    Write-Host "[vboxga] VirtualBox Guest Additions installed successfully"
} else {
    Write-Host "[vboxga] WARNING: Installer exited with code $($proc.ExitCode)"
}
```

### 6.4 optimize.ps1 (both boxes — identical)

```powershell
$ErrorActionPreference = "Continue"
Write-Host "[optimize] Applying performance optimizations..."

# Disable unnecessary services
$services = @(
    "wuauserv",      # Windows Update
    "WSearch",       # Windows Search
    "SysMain",       # Superfetch
    "WerSvc",        # Windows Error Reporting
    "DiagTrack",     # Connected User Experiences
    "dmwappushservice" # WAP Push
)

foreach ($svc in $services) {
    try {
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
        Set-Service $svc -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host "[optimize] Disabled service: $svc"
    } catch {
        Write-Host "[optimize] Could not disable: $svc"
    }
}

# Disable hibernation
powercfg /h off
Write-Host "[optimize] Hibernation disabled"

# High performance power plan
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
Write-Host "[optimize] High performance power plan set"

# Disable System Restore
Disable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
Write-Host "[optimize] System Restore disabled"

# Disable paging file
$computerSystem = Get-WmiObject Win32_ComputerSystem
$computerSystem.AutomaticManagedPagefile = $false
$computerSystem.Put() | Out-Null
$pageFile = Get-WmiObject Win32_PageFileSetting
if ($pageFile) { $pageFile.Delete() }
Write-Host "[optimize] Paging file disabled"

# Disable Windows Defender scheduled scans
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Write-Host "[optimize] Windows Defender real-time disabled"
} catch {}

# Disable unnecessary scheduled tasks
$tasks = @(
    "\Microsoft\Windows\Defrag\ScheduledDefrag",
    "\Microsoft\Windows\Diagnosis\Scheduled",
    "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
    "\Microsoft\Windows\Maintenance\WinSAT",
    "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
)

foreach ($task in $tasks) {
    try {
        Disable-ScheduledTask -TaskPath (Split-Path $task) `
            -TaskName (Split-Path $task -Leaf) `
            -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}
Write-Host "[optimize] Scheduled tasks disabled"

Write-Host "[optimize] Optimizations complete"
```

### 6.5 cleanup.ps1 (both boxes — identical)

```powershell
$ErrorActionPreference = "Continue"
Write-Host "[cleanup] Starting disk cleanup..."

# Clean Windows Update cache
Remove-Item -Recurse -Force "C:\Windows\SoftwareDistribution\Download\*" `
    -ErrorAction SilentlyContinue
Write-Host "[cleanup] Windows Update cache cleared"

# Clean temp files
Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\Temp\*" -ErrorAction SilentlyContinue
Write-Host "[cleanup] Temp files cleared"

# Clean Windows logs
try {
    $logs = wevtutil el
    foreach ($log in $logs) {
        wevtutil cl "$log" 2>$null
    }
    Write-Host "[cleanup] Event logs cleared"
} catch {}

# Run Disk Cleanup
$cleanupKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
Get-ChildItem $cleanupKey | ForEach-Object {
    Set-ItemProperty -Path $_.PsPath -Name StateFlags0001 -Value 2 -Type DWORD -ErrorAction SilentlyContinue
}
Start-Process cleanmgr -ArgumentList "/sagerun:1" -Wait -ErrorAction SilentlyContinue
Write-Host "[cleanup] Disk Cleanup complete"

# Zero out free space for better box compression
Write-Host "[cleanup] Zeroing free space (this takes a while)..."
$zeroFile = "C:\zero.tmp"
try {
    $drive = Get-PSDrive C
    $freeBytes = $drive.Free
    $fs = [System.IO.File]::Create($zeroFile)
    $buf = New-Object byte[] 1MB
    $written = 0
    while ($written -lt ($freeBytes - 100MB)) {
        $fs.Write($buf, 0, $buf.Length)
        $written += $buf.Length
    }
    $fs.Close()
} catch {
    Write-Host "[cleanup] Zero file creation stopped (disk full - expected)"
} finally {
    Remove-Item $zeroFile -Force -ErrorAction SilentlyContinue
}
Write-Host "[cleanup] Free space zeroed"

Write-Host "[cleanup] Cleanup complete"
```

---

## 7. build-boxes.sh

```bash
#!/bin/bash
set -e

echo "╔══════════════════════════════════════════╗"
echo "║  AD Alligator Labs — Build Packer Boxes  ║"
echo "╚══════════════════════════════════════════╝"

show_help() {
    echo ""
    echo "USAGE: ./build-boxes.sh [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help          Show this help"
    echo "  --server-only       Build Windows Server 2022 box only"
    echo "  --workstation-only  Build Windows 10 Enterprise box only"
    echo "  --skip-vagrant-add  Build boxes but don't add to Vagrant"
    echo ""
    echo "ENVIRONMENT VARIABLES:"
    echo "  SERVER_ISO    Path to Windows Server 2022 ISO"
    echo "                Default: iso/windows-server-2022.iso"
    echo "  WIN10_ISO     Path to Windows 10 Enterprise ISO"
    echo "                Default: iso/windows-10-enterprise.iso"
    echo ""
    echo "EXAMPLES:"
    echo "  ./build-boxes.sh"
    echo "  SERVER_ISO=/tmp/server2022.iso ./build-boxes.sh"
    echo "  ./build-boxes.sh --server-only"
    echo ""
    echo "After building, run the lab with:"
    echo "  USE_LOCAL_BOXES=true ./setup.sh"
}

# Parse arguments
BUILD_SERVER=true
BUILD_WIN10=true
SKIP_VAGRANT_ADD=false

for arg in "$@"; do
    case $arg in
        -h|--help) show_help; exit 0 ;;
        --server-only) BUILD_WIN10=false ;;
        --workstation-only) BUILD_SERVER=false ;;
        --skip-vagrant-add) SKIP_VAGRANT_ADD=true ;;
        *) echo "Unknown option: $arg"; echo "Run --help for usage"; exit 1 ;;
    esac
done

# Pre-flight checks
echo "[0] Checking requirements..."
for tool in packer vagrant VBoxManage sha256sum; do
    if ! command -v $tool &>/dev/null; then
        echo "ERROR: $tool not found in PATH"
        case $tool in
            packer) echo "  Install from: https://developer.hashicorp.com/packer/downloads" ;;
            vagrant) echo "  Install from: https://www.vagrantup.com/downloads" ;;
            VBoxManage) echo "  Install VirtualBox from: https://www.virtualbox.org" ;;
        esac
        exit 1
    fi
    echo "    [✓] $tool found"
done

# Check Packer version
PACKER_VERSION=$(packer version | head -1 | grep -oP '\d+\.\d+\.\d+')
echo "    [✓] Packer version: $PACKER_VERSION"

# Setup paths
SERVER_ISO="${SERVER_ISO:-iso/windows-server-2022.iso}"
WIN10_ISO="${WIN10_ISO:-iso/windows-10-enterprise.iso}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p boxes
mkdir -p packer/windows-server-2022/boxes
mkdir -p packer/windows-10-enterprise/boxes

START_TIME=$(date +%s)

# Build Windows Server 2022
if [ "$BUILD_SERVER" = true ]; then
    echo ""
    echo "[1] Building Windows Server 2022 box..."
    
    if [ ! -f "$SERVER_ISO" ]; then
        echo "ERROR: ISO not found at: $SERVER_ISO"
        echo "  See: packer/UUP_DUMP_INSTRUCTIONS.md"
        echo "  Or set: export SERVER_ISO=/path/to/your.iso"
        exit 1
    fi
    
    echo "    ISO: $SERVER_ISO"
    echo "    Calculating checksum..."
    SERVER_CHECKSUM=$(sha256sum "$SERVER_ISO" | cut -d' ' -f1)
    echo "    SHA256: $SERVER_CHECKSUM"
    echo "    Starting Packer build (45-90 minutes)..."
    
    cd packer/windows-server-2022
    packer init . 2>/dev/null || true
    packer build \
        -var "iso_path=$SCRIPT_DIR/$SERVER_ISO" \
        -var "iso_checksum=$SERVER_CHECKSUM" \
        windows-server-2022.pkr.hcl
    cd "$SCRIPT_DIR"
    
    if [ "$SKIP_VAGRANT_ADD" = false ]; then
        echo "    Adding to Vagrant..."
        vagrant box remove secscope/windows-server-2022 --force 2>/dev/null || true
        vagrant box add --name secscope/windows-server-2022 \
            packer/windows-server-2022/boxes/windows-server-2022.box
        echo "    [✓] Windows Server 2022 box added to Vagrant"
    fi
fi

# Build Windows 10 Enterprise
if [ "$BUILD_WIN10" = true ]; then
    echo ""
    echo "[2] Building Windows 10 Enterprise box..."
    
    if [ ! -f "$WIN10_ISO" ]; then
        echo "ERROR: ISO not found at: $WIN10_ISO"
        echo "  See: packer/UUP_DUMP_INSTRUCTIONS.md"
        echo "  Or set: export WIN10_ISO=/path/to/your.iso"
        exit 1
    fi
    
    echo "    ISO: $WIN10_ISO"
    echo "    Calculating checksum..."
    WIN10_CHECKSUM=$(sha256sum "$WIN10_ISO" | cut -d' ' -f1)
    echo "    SHA256: $WIN10_CHECKSUM"
    echo "    Starting Packer build (45-90 minutes)..."
    
    cd packer/windows-10-enterprise
    packer init . 2>/dev/null || true
    packer build \
        -var "iso_path=$SCRIPT_DIR/$WIN10_ISO" \
        -var "iso_checksum=$WIN10_CHECKSUM" \
        windows-10-enterprise.pkr.hcl
    cd "$SCRIPT_DIR"
    
    if [ "$SKIP_VAGRANT_ADD" = false ]; then
        echo "    Adding to Vagrant..."
        vagrant box remove secscope/windows-10-enterprise --force 2>/dev/null || true
        vagrant box add --name secscope/windows-10-enterprise \
            packer/windows-10-enterprise/boxes/windows-10-enterprise.box
        echo "    [✓] Windows 10 Enterprise box added to Vagrant"
    fi
fi

# Summary
END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║           All boxes built!               ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Time taken: ${ELAPSED} minutes"
echo ""
echo "Available boxes:"
vagrant box list | grep secscope || echo "  (none added yet — run without --skip-vagrant-add)"
echo ""
echo "Next step:"
echo "  USE_LOCAL_BOXES=true ./setup.sh"
```

---

## 8. build-boxes.ps1

PowerShell equivalent of build-boxes.sh:

```powershell
param(
    [switch]$Help,
    [switch]$ServerOnly,
    [switch]$WorkstationOnly,
    [switch]$SkipVagrantAdd,
    [string]$ServerISO = "iso\windows-server-2022.iso",
    [string]$Win10ISO  = "iso\windows-10-enterprise.iso"
)

$ErrorActionPreference = "Stop"

function Show-Help {
    Write-Host "╔══════════════════════════════════════════╗"
    Write-Host "║  AD Alligator Labs — Build Packer Boxes  ║"
    Write-Host "╚══════════════════════════════════════════╝"
    Write-Host ""
    Write-Host "USAGE:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File build-boxes.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "OPTIONS:"
    Write-Host "  -Help               Show this help"
    Write-Host "  -ServerOnly         Build Windows Server 2022 only"
    Write-Host "  -WorkstationOnly    Build Windows 10 Enterprise only"
    Write-Host "  -SkipVagrantAdd     Build but don't add to Vagrant"
    Write-Host "  -ServerISO <path>   Path to Server 2022 ISO"
    Write-Host "  -Win10ISO <path>    Path to Windows 10 ISO"
    Write-Host ""
    Write-Host "EXAMPLES:"
    Write-Host "  .\build-boxes.ps1"
    Write-Host "  .\build-boxes.ps1 -ServerOnly"
    Write-Host "  .\build-boxes.ps1 -ServerISO D:\isos\server2022.iso"
    Write-Host ""
    Write-Host "After building:"
    Write-Host "  `$env:USE_LOCAL_BOXES='true'; .\setup.ps1"
}

if ($Help) { Show-Help; exit 0 }

Write-Host "╔══════════════════════════════════════════╗"
Write-Host "║  AD Alligator Labs — Build Packer Boxes  ║"
Write-Host "╚══════════════════════════════════════════╝"

$BuildServer = -not $WorkstationOnly
$BuildWin10  = -not $ServerOnly

# Pre-flight checks
Write-Host "`n[0] Checking requirements..."
foreach ($tool in @("packer", "vagrant", "VBoxManage")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: $tool not found in PATH"
        exit 1
    }
    Write-Host "    [OK] $tool found"
}

$ScriptDir = $PSScriptRoot
$StartTime = Get-Date

New-Item -ItemType Directory -Force -Path "boxes" | Out-Null
New-Item -ItemType Directory -Force -Path "packer\windows-server-2022\boxes" | Out-Null
New-Item -ItemType Directory -Force -Path "packer\windows-10-enterprise\boxes" | Out-Null

# Build Windows Server 2022
if ($BuildServer) {
    Write-Host "`n[1] Building Windows Server 2022 box..."
    
    if (-not (Test-Path $ServerISO)) {
        Write-Host "ERROR: ISO not found at: $ServerISO"
        Write-Host "  See: packer\UUP_DUMP_INSTRUCTIONS.md"
        exit 1
    }
    
    Write-Host "    ISO: $ServerISO"
    Write-Host "    Calculating checksum..."
    $ServerChecksum = (Get-FileHash -Algorithm SHA256 $ServerISO).Hash.ToLower()
    Write-Host "    SHA256: $ServerChecksum"
    Write-Host "    Starting Packer build (45-90 minutes)..."
    
    Push-Location "packer\windows-server-2022"
    packer init . 2>$null
    packer build `
        -var "iso_path=$ScriptDir\$ServerISO" `
        -var "iso_checksum=$ServerChecksum" `
        windows-server-2022.pkr.hcl
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Packer build failed"; exit 1 }
    Pop-Location
    
    if (-not $SkipVagrantAdd) {
        Write-Host "    Adding to Vagrant..."
        vagrant box remove secscope/windows-server-2022 --force 2>$null
        vagrant box add --name secscope/windows-server-2022 `
            "packer\windows-server-2022\boxes\windows-server-2022.box"
        Write-Host "    [OK] Windows Server 2022 box added"
    }
}

# Build Windows 10 Enterprise
if ($BuildWin10) {
    Write-Host "`n[2] Building Windows 10 Enterprise box..."
    
    if (-not (Test-Path $Win10ISO)) {
        Write-Host "ERROR: ISO not found at: $Win10ISO"
        Write-Host "  See: packer\UUP_DUMP_INSTRUCTIONS.md"
        exit 1
    }
    
    Write-Host "    ISO: $Win10ISO"
    Write-Host "    Calculating checksum..."
    $Win10Checksum = (Get-FileHash -Algorithm SHA256 $Win10ISO).Hash.ToLower()
    Write-Host "    SHA256: $Win10Checksum"
    Write-Host "    Starting Packer build (45-90 minutes)..."
    
    Push-Location "packer\windows-10-enterprise"
    packer init . 2>$null
    packer build `
        -var "iso_path=$ScriptDir\$Win10ISO" `
        -var "iso_checksum=$Win10Checksum" `
        windows-10-enterprise.pkr.hcl
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Packer build failed"; exit 1 }
    Pop-Location
    
    if (-not $SkipVagrantAdd) {
        Write-Host "    Adding to Vagrant..."
        vagrant box remove secscope/windows-10-enterprise --force 2>$null
        vagrant box add --name secscope/windows-10-enterprise `
            "packer\windows-10-enterprise\boxes\windows-10-enterprise.box"
        Write-Host "    [OK] Windows 10 Enterprise box added"
    }
}

$Elapsed = [int]((Get-Date) - $StartTime).TotalMinutes

Write-Host ""
Write-Host "╔══════════════════════════════════════════╗"
Write-Host "║           All boxes built!               ║"
Write-Host "╚══════════════════════════════════════════╝"
Write-Host ""
Write-Host "Time taken: $Elapsed minutes"
Write-Host ""
Write-Host "Next step:"
Write-Host "  `$env:USE_LOCAL_BOXES='true'; .\setup.ps1"
```

---

## 9. UUP Dump Instructions

File: `packer/UUP_DUMP_INSTRUCTIONS.md`

```markdown
# Getting Windows ISOs from UUP Dump

UUP Dump lets you download Windows ISOs directly from Microsoft's
update servers. The resulting ISOs are legitimate evaluation media.

## Windows Server 2022

1. Go to https://uupdump.net
2. Search: "Windows Server 2022"
3. Select the latest build (highest number)
4. Language: English (United States)
5. Edition: Windows Server 2022 Standard
6. Click "Next" → "Create download package"
7. Extract the downloaded ZIP
8. Run the conversion script:
   - Linux/macOS: chmod +x uup_download_linux.sh && ./uup_download_linux.sh
   - Windows:     double-click uup_download_windows.cmd
9. Script downloads (~4GB) and creates: SERVERSTANDARD_*.iso
10. Rename to: windows-server-2022.iso
11. Place in: ActiveDirectoryAlligatorLABS/iso/windows-server-2022.iso

## Windows 10 Enterprise 22H2

1. Go to https://uupdump.net
2. Search: "Windows 10 22H2"
3. Select the latest build
4. Language: English (United States)
5. Edition: Windows 10 Enterprise
6. Follow steps 6-11 above
7. Rename to: windows-10-enterprise.iso
8. Place in: ActiveDirectoryAlligatorLABS/iso/windows-10-enterprise.iso

## Notes

- ISO creation takes 15-30 minutes (internet speed dependent)
- Final ISOs are approximately 4-5GB each
- These are evaluation versions valid for 180 days
- The iso/ folder is in .gitignore — never commit ISOs to GitHub
- Run sha256sum on your ISO and save the hash for verification

## Verify ISO

```bash
sha256sum iso/windows-server-2022.iso
sha256sum iso/windows-10-enterprise.iso
```

## After Getting ISOs

```bash
./build-boxes.sh
# OR
USE_LOCAL_BOXES=true ./setup.sh
```
```

---

## 10. GitHub Files

### 10.1 LOGO.md

```markdown
# Active Directory Alligator Labs

> A fierce green alligator attacking Windows servers and domain
> controllers — built for learning AD penetration testing.

## Logo

Place your logo at: `assets/logo.png`

Suggested dimensions: 800x400px

The pixel art logo should show a green alligator attacking
Windows servers on a dark blue background.

## Lab Domain

The technical domain `secscope.corp` is used internally for all
AD configuration. The project branding is "Active Directory
Alligator Labs" but the domain name remains secscope.corp
throughout all lab exercises.
```

### 10.2 .github/ISSUE_TEMPLATE/bug_report.md

```markdown
---
name: Bug Report
about: Report an issue with the lab build
title: '[BUG] '
labels: bug
---

## VM Affected
<!-- dc01 / dc02 / dc03 / srv01 / ws01 / ws02 / lin01 / all -->

## Provisioner That Failed
<!-- Which step? e.g. postboot / dns / objects / join -->

## Error Output
```
paste the full error output here
```

## Steps to Reproduce
1.
2.
3.

## Host Environment
- OS: <!-- Linux / Windows 10 / Windows 11 / macOS -->
- Vagrant version: <!-- vagrant --version -->
- VirtualBox version: <!-- VBoxManage --version -->
- RAM available: <!-- e.g. 16GB -->
- Disk free: <!-- e.g. 200GB -->

## Box Type
- [ ] Vagrant Cloud boxes (default)
- [ ] Custom Packer boxes (USE_LOCAL_BOXES=true)

## Additional Context
<!-- Any other relevant information -->
```

### 10.3 .github/ISSUE_TEMPLATE/feature_request.md

```markdown
---
name: Feature Request
about: Suggest a new attack scenario or lab module
title: '[FEATURE] '
labels: enhancement
---

## Attack Technique
<!-- What AD attack technique should this lab cover? -->

## Course Module
<!-- Which module does this relate to?
     01_AD_Foundations / 02_AD_Objects / 03_AD_Database /
     04_Network_Recon / 05_NTLM / 06_Kerberos /
     07_Credentials / 08_Authorization / 09_Lateral /
     10_Extras -->

## Current Gap
<!-- What can't students practice with the current lab? -->

## Suggested Implementation
<!-- How should this be implemented?
     New VM? New misconfiguration? New AD object? -->

## Difficulty Level
- [ ] Beginner
- [ ] Intermediate
- [ ] Advanced

## References
<!-- Links to research papers, blog posts, or tool documentation -->
```

---

## 11. .gitignore Updates

Replace entire .gitignore with:

```gitignore
# Vagrant
.vagrant/
*.box
Vagrantfile.local

# Packer build artifacts
packer/*/builds/
packer/*/boxes/*.box
packer/windows-server-2022/builds/
packer/windows-10-enterprise/builds/

# ISO files - never commit these
iso/*.iso
*.iso
*.img

# VM artifacts
*.ova
*.ovf
*.vmdk
*.vhd
*.vhdx

# Logs
*.log
packer-manifest.json

# OS files
.DS_Store
Thumbs.db
desktop.ini

# Editor
.vscode/
.idea/
*.swp
*.swo

# Keep directory structure
!packer/windows-server-2022/boxes/.gitkeep
!packer/windows-10-enterprise/boxes/.gitkeep
!iso/.gitkeep
!assets/.gitkeep
```

---

## 12. .gitattributes

```gitattributes
# Enforce correct line endings
*.sh        text eol=lf
*.ps1       text eol=crlf
*.psm1      text eol=crlf
*.psd1      text eol=crlf
*.rb        text eol=lf
*.pkr.hcl   text eol=lf
*.pkrvars.hcl text eol=lf
Vagrantfile text eol=lf
*.md        text eol=lf
*.xml       text eol=lf
*.conf      text eol=lf
*.json      text eol=lf
*.yaml      text eol=lf
*.yml       text eol=lf

# Binary files
*.box       binary
*.iso       binary
*.ova       binary
*.vmdk      binary
*.png       binary
*.jpg       binary
*.gif       binary
```

---

## 13. Agent Instructions

### The agent MUST

1. Read every uploaded file completely before planning
2. Confirm file list with line counts before starting
3. Create every file listed in Section 2 Project Structure
4. Write all scripts completely — no placeholders or TODOs
5. Keep `secscope.corp` domain unchanged everywhere
6. Preserve all existing provisioner script content in `scripts/`
7. Test all PowerShell syntax mentally before writing
8. Use HCL2 format for all Packer templates
9. Make Vagrantfile backward compatible — default must use Vagrant Cloud

### The agent MUST NOT

1. Change any IP addresses or passwords
2. Change any provisioner script in `scripts/`
3. Change `vagrant_plugins/winrm_quiet.rb`
4. Use JSON format for Packer templates
5. Leave any file partially written
6. Change the domain name `secscope.corp`

### Idempotency

All PowerShell scripts must be safe to run multiple times.
Use try/catch around object creation. Check existence before creating.

---

## 14. Plan Phase

Before writing any code:

1. List every file to be created with one-line description
2. List every file to be modified with what changes
3. List every file that stays unchanged
4. Flag any risks or conflicts found in uploaded files
5. Ask for approval

## 15. Build Phase (after approval)

Implement in this order:
1. .gitignore and .gitattributes
2. Vagrantfile (USE_LOCAL_BOXES toggle only)
3. packer/windows-server-2022/ (all files)
4. packer/windows-10-enterprise/ (all files)
5. build-boxes.sh
6. build-boxes.ps1
7. LOGO.md
8. .github/ templates
9. packer/UUP_DUMP_INSTRUCTIONS.md
10. README.md (branding + new sections)
11. setup.sh (branding only)
12. setup.ps1 (branding only)

After each file confirm line count and show first/last 5 lines.

