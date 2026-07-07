# Active Directory Alligator Labs — Installation Guide

Step-by-step instructions to go from zero to a fully working Active Directory lab.

## Pre-Installation Checklist

| Requirement | Minimum |
|-------------|---------|
| RAM         | 16 GB   |
| Free disk   | 150 GB  |
| CPU         | 4 cores (2 for host, 2 for VMs) |
| Virtualization | Intel VT-x or AMD-V enabled in BIOS |
| Internet    | Stable connection (~25 GB of downloads) |
| Host OS     | Windows 10/11, macOS 12+, or Linux (kernel 5.x+) |

---

## 1. Install Dependencies

### Windows

1. **VirtualBox 7.0+**
   - Download: https://www.virtualbox.org/wiki/Downloads
   - Run installer with defaults. Accept the network adapter prompt.
   - Reboot after installation.

2. **Vagrant 2.3+**
   - Download: https://developer.hashicorp.com/vagrant/downloads
   - Run the MSI installer. Reboot after installation.

3. **Git** (to clone the project, or download ZIP from the repo)
   - Download: https://git-scm.com/download/win
   - Recommended: enable "Git Bash Here" during install.

4. Verify from **PowerShell (Admin)**:
   ```powershell
   vagrant --version          # must be >= 2.3.0
   VBoxManage --version       # must be >= 7.0
   ```

> **Hyper-V conflict:** If Vagrant fails to start VMs, disable Hyper-V, Windows Sandbox, and WSL2:
> ```powershell
> dism.exe /Online /Disable-Feature:Microsoft-Hyper-V
> bcdedit /set hypervisorlaunchtype off
> ```
> Reboot after running these commands. Re-enable when done: `bcdedit /set hypervisorlaunchtype auto`

---

### macOS

1. Install Homebrew if not present:
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

2. Install VirtualBox and Vagrant:
   ```bash
   brew install --cask virtualbox
   brew install --cask vagrant
   ```

3. Verify:
   ```bash
   vagrant --version
   vboxmanage --version
   ```

---

### Linux (Ubuntu/Debian)

1. **VirtualBox 7.0+** (from Oracle, not the distro package):
   ```bash
   wget -q https://www.virtualbox.org/download/oracle_vbox_2016.asc -O- | sudo apt-key add -
   sudo add-apt-repository "deb [arch=amd64] https://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib"
   sudo apt-get update
   sudo apt-get install -y virtualbox-7.0
   ```

2. **Vagrant 2.3+**:
   ```bash
   curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
   sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
   sudo apt-get update
   sudo apt-get install -y vagrant
   ```

3. **User permissions** — add your user to the `vboxusers` group:
   ```bash
   sudo usermod -aG vboxusers $USER
   # Log out and back in for this to take effect
   ```

4. Verify:
   ```bash
   vagrant --version
   vboxmanage --version
   ```

---

## 2. Hardware Verification

### Check available RAM
| OS | Command |
|----|---------|
| Windows | `systeminfo | findstr /C:"Total Physical Memory"` |
| macOS | `sysctl hw.memsize` (bytes) or `top -l 1 | head -n 10` |
| Linux | `free -h` |

### Check free disk space
| OS | Command |
|----|---------|
| Windows | `wmic logicaldisk get size,freespace,caption` |
| macOS | `df -h /` |
| Linux | `df -h` |

### Check virtualization support
| OS | Command |
|----|---------|
| Windows | `systeminfo | findstr /C:"Virtualization Enabled"` — if "No", enable VT-x in BIOS |
| macOS | Supported by default on Intel Macs |
| Linux | `egrep -c '(vmx|svm)' /proc/cpuinfo` — if 0, enable VT-x/AMD-V in BIOS |

> **Windows evaluation period:** Both Windows Server 2022 and Windows 10
> boxes are evaluation copies valid for **180 days**. After expiration,
> Windows shuts down every hour. Check inside the VM: `slmgr /dli`.
> Rearm (up to 3 times): `slmgr /rearm`.

---

## 3. Get the Project

```bash
git clone <repository-url> ActiveDirectoryAlligatorLABS
cd ActiveDirectoryAlligatorLABS
```

Or download and extract the ZIP into a directory called `ActiveDirectoryAlligatorLABS/`.

---

## 4. Build Vagrant Boxes

Windows boxes must be built from ISO before any VMs can be started.

### Download ISOs

| ISO | Download | Expected Filename | SHA256 |
|-----|----------|-------------------|--------|
| Windows Server 2022 | [Direct download](https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso) | `SERVER_EVAL_x64FRE_en-us.iso` | `3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325` |
| Windows 10 22H2 | [Download page](https://www.microsoft.com/en-us/software-download/windows10ISO) | `Win10_22H2_English_x64v1.iso` | `a6f470ca6d331eb353b815c043e327a347f594f37ff525f17764738fe812852e` |

Download the ISOs, rename them to match the expected filenames above, and place them
in the `iso/` directory. Verify the checksums match:

**Linux/macOS:**
```bash
sha256sum iso/SERVER_EVAL_x64FRE_en-us.iso
sha256sum iso/Win10_22H2_English_x64v1.iso
```

**Windows PowerShell:**
```powershell
Get-FileHash -Algorithm SHA256 iso\SERVER_EVAL_x64FRE_en-us.iso
Get-FileHash -Algorithm SHA256 iso\Win10_22H2_English_x64v1.iso
```

> Microsoft may update the ISO builds over time. If your checksum does not match the
> values above, you may have a newer build — adjust the `iso_checksum` variable in
> the Packer `.pkr.hcl` files, or pass it as a variable (`-var "iso_checksum=..."`).

### Build Boxes

Build the Windows boxes sequentially:

```bash
# Build Windows Server 2022 box (~45-90 minutes)
./setup.sh build-boxes --server-only

# Build Windows 10 box (~45-90 minutes)
./setup.sh build-boxes --workstation-only
```

Or build both at once:
```bash
./setup.sh build-boxes
```

**Windows PowerShell:**
```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1 build-boxes
```

Verify boxes:
```bash
vagrant box list | grep secscope
```

Should show:
```
secscope/windows-10                (virtualbox, x.x.x)
secscope/windows-server-2022       (virtualbox, x.x.x)
```

Debian (`debian/bookworm64`) for lin01 is auto-downloaded from Vagrant Cloud on first `vagrant up`.

If a `vagrant up` fails with "box not found", run `./setup.sh build-boxes` first.

---

## 5. Build the Lab

### Automated Build (Recommended)

Use the setup script to build the entire lab automatically:

**Linux / macOS:**
```bash
./setup.sh
```

**Windows PowerShell:**
```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

The script runs all `vagrant up` and `vagrant provision` commands in the correct dependency order,
handles reloads automatically, runs DC02+DC03 joins in parallel, and performs a final AD objects pass
after all VMs are up. Total build time: ~75-90 minutes.

### Build Options

```bash
# Build only DC01 (test environment)
./setup.sh deploy --dc01-only

# Deploy specific VMs only
./setup.sh deploy --vms dc01,ws01,srv01

# Skip certain steps
./setup.sh deploy --skip-services    # Skip SRV01 IIS/SQL/ADCS
./setup.sh deploy --skip-misconfig   # Skip WS01/WS02 vulnerabilities
./setup.sh deploy --skip-hardening   # Skip vagrant account disable
./setup.sh deploy --skip-linux       # Skip LIN01
```

---

## 6. Verify the Lab

```bash
./setup.sh status
```

Expected output — all VMs `running`:
```
dc01    running (virtualbox)
dc02    running (virtualbox)
dc03    running (virtualbox)
srv01   running (virtualbox)
ws01    running (virtualbox)
ws02    running (virtualbox)
lin01   running (virtualbox)
```

If any VM shows `poweroff` or `not created`, re-run the build:
```bash
./setup.sh
```

---

## 7. Kali Linux Installation

Kali is **not** managed by Vagrant. Install it manually as an attacker workstation.

### 7.1 Download and Import

1. Download the VirtualBox image from: https://www.kali.org/get-kali/#kali-virtual-machines
2. In VirtualBox, go to **File > Import Appliance** and select the downloaded OVA.
3. Start the VM once imported (default credentials: `kali` / `kali`).

### 7.2 Attach to the Lab Network

1. With the Kali VM powered off, go to **Settings > Network > Adapter 1**
2. Set **Attached to: NAT Network**
3. Set **Name: SECSCOPE.CORP** (created automatically by the Vagrantfile trigger)
4. Start the Kali VM.

### 7.3 Configure Static IP

```bash
sudo ip addr add 192.168.200.99/24 dev eth0
```

To make this permanent, edit `/etc/network/interfaces`:
```
auto eth0
iface eth0 inet static
    address 192.168.200.99
    netmask 255.255.255.0
```

### 7.4 Install Attack Tools

```bash
sudo apt-get update -qq

sudo apt-get install -y -qq \
    impacket-scripts \
    responder \
    bloodhound \
    neo4j \
    crackmapexec \
    evil-winrm \
    smbclient \
    ldap-utils \
    krb5-user \
    hashcat \
    john \
    seclists \
    wordlists \
    nmap \
    netcat-openbsd \
    python3-pip \
    golang

pip3 install bloodhound --quiet
```

### 7.5 Configure Host Resolution

```bash
sudo tee -a /etc/hosts <<EOF
192.168.200.10  dc01.secscope.corp dc01
192.168.200.11  dc02.secscope.corp dc02
192.168.200.12  dc03.secscope.corp dc03 it.secscope.corp
192.168.200.20  srv01.secscope.corp srv01
192.168.200.30  ws01.secscope.corp ws01
192.168.200.31  ws02.secscope.corp ws02
192.168.200.40  lin01.secscope.corp lin01
EOF
```

### 7.6 Configure Kerberos

```bash
sudo tee /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = SECSCOPE.CORP
    dns_lookup_realm = false
    dns_lookup_kdc = true

[realms]
    SECSCOPE.CORP = {
        kdc = dc01.secscope.corp
        admin_server = dc01.secscope.corp
    }

[domain_realm]
    .secscope.corp = SECSCOPE.CORP
    secscope.corp = SECSCOPE.CORP
EOF
```

---

## 8. Verification / Smoke Tests

Run these from the Kali VM to confirm the lab is functional.

### Basic connectivity
```bash
for ip in 10 11 12 20 30 31 40; do
    ping -c 1 192.168.200.$ip && echo "192.168.200.$ip OK" || echo "192.168.200.$ip FAIL"
done
```

### DNS resolution
```bash
nslookup dc01.secscope.corp 192.168.200.10
nslookup ws01.secscope.corp 192.168.200.10
```

### Domain authentication (SMB)
```bash
crackmapexec smb 192.168.200.10 -u anakin -p 'Vader2024!'
# Expected: [+] secscope.corp\anakin (Pwn3d!)
```

### Kerberos
```bash
echo 'Vader2024!' | kinit anakin@SECSCOPE.CORP
klist
# Expected: Ticket cache shows anakin@SECSCOPE.CORP
```

### ASREPRoast
```bash
impacket-GetNPUsers secscope.corp/nopreauth -no-pass -request
# Expected: Returns a TGT encrypted with nopreauth's RC4 key
```

### SMB Shares
```bash
smbclient -L //192.168.200.10 -U anakin%'Vader2024!'
# Expected: Lists SYSVOL, NETLOGON, and other shares
```

### Linux SSH
```bash
ssh labuser@192.168.200.40
# Password: LabUser2024!
# Expected: Successful login
```

---

## 9. Tool Inventory

Tools installed automatically on each VM by provisioning scripts:

| VM   | Software Installed |
|------|--------------------|
| dc01 | Active Directory Domain Services, DNS Server, RSAT AD PowerShell, LAPS MSI |
| dc02 | Active Directory Domain Services, DNS Server |
| dc03 | Active Directory Domain Services, DNS Server |
| srv01 | IIS Web Server, SQL Server Express (attempted), ADCS Certificate Authority, ADCS Web Enrollment |
| ws01 | (Intentionally misconfigured: WDigest, NTLMv1, LLMNR/mDNS/NetBIOS, disabled SMB signing/LSA, local admin, scheduled task, service credentials, AutoLogon as anakin, cached DCC2 creds for anakin+han) |
| ws02 | (Intentionally misconfigured: WDigest, disabled SMB signing, Print Spooler, AutoLogon as anakin) |
| lin01 | SSSD, realmd, adcli, Kerberos utilities, Samba, OpenSSH, Python3, nmap |

---

## 10. Time Estimates

| Stage | Approximate Time |
|-------|-----------------|
| Install VirtualBox + Vagrant | 10-15 min |
| Build Windows Server 2022 box | 45-90 min |
| Build Windows 10 box | 45-90 min |
| Deploy lab (./setup.sh) | 75-90 min |
| Kali VM setup | 15-20 min |
| **Total (excluding box builds)** | **~2 hours** |

---

## 11. Common Installation Issues

### VirtualBox / Hyper-V Conflict (Windows)
**Symptom:** `VT-x is not available` or VM fails to start with `VERR_VMX_NO_VMX`.

**Fix:** Only one hypervisor can use VT-x at a time. Disable Hyper-V:
```powershell
dism.exe /Online /Disable-Feature:Microsoft-Hyper-V
bcdedit /set hypervisorlaunchtype off
```
Reboot. To re-enable: `bcdedit /set hypervisorlaunchtype auto`

Also disable **Windows Sandbox**, **WSL2**, and **Credential Guard** if enabled.

### Vagrant Box Not Found
**Symptom:** `The box 'secscope/windows-server-2022' could not be found.`

**Fix:** Boxes must be built from ISO before running the lab:
```bash
./setup.sh build-boxes
```

### WinRM Timeout
**Symptom:** `Timed out while waiting for the machine to boot` or WinRM connection errors.

**Fix:** Windows VMs are slow on first boot. The Vagrantfile sets `boot_timeout = 300` (5 min).
If you still hit timeouts, increase this in the Vagrantfile temporarily.

### Port Conflicts
**Symptom:** Vagrant cannot forward WinRM ports (5985, 5986).

**Fix:** These ports are used by each Windows VM. VirtualBox maps them to random host ports,
but if the host is running WinRM itself, stop it:
```powershell
# Windows host only
Stop-Service WinRM
```

### NAT Network Already Exists
**Symptom:** VBoxManage error about an existing NAT Network.

**Fix:** This is harmless. The Vagrantfile trigger handles this automatically.
If you need to reset it:
```bash
VBoxManage natnetwork remove --netname SECSCOPE.CORP
```

### DC01 Objects Script — "WS01 not found"
**Symptom:** During objects provisioning, WS01 and WS02 computer objects may not exist yet.

**Fix:** The script gracefully skips computer ACLs for VMs that are absent and prints a clear message.
The setup scripts run a final objects pass after all VMs are up. Or re-run manually:
```bash
vagrant provision dc01 --provision-with objects
```

### Low Disk Space
**Symptom:** `vagrant up` fails with disk errors.

**Fix:**
- Each Windows VM box is ~10 GB compressed, ~40 GB expanded
- Total lab uses ~100-120 GB after all VMs are created
- Clean up old boxes: `vagrant box remove <name>`
- Or free space in: `~/.vagrant.d/boxes/` (Linux/macOS) or `%USERPROFILE%\.vagrant.d\boxes\` (Windows)

---

## 12. Uninstalling / Rebuilding

### Destroy all VMs (keep boxes)
```bash
./setup.sh destroy
```

### Destroy everything including boxes
```bash
./setup.sh destroy
vagrant box remove secscope/windows-server-2022
vagrant box remove secscope/windows-10
vagrant box remove debian/bookworm64
```

### Full rebuild from scratch
```bash
./setup.sh destroy
./setup.sh
```
