# Active Directory Alligator Labs — Installation Guide

Step-by-step instructions to go from zero to a fully working Active Directory penetration testing lab.

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
   # Add Oracle VirtualBox repo
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
> Enterprise boxes are evaluation copies valid for **180 days**. After
> expiration, Windows shuts down every hour. Check inside the VM:
> `slmgr /dli`. Rearm (up to 3 times): `slmgr /rearm`.

---

## 3. Get the Project

```bash
git clone <repository-url> ActiveDirectoryAlligatorLABS
cd ActiveDirectoryAlligatorLABS
```

Or download and extract the ZIP into a directory called `ActiveDirectoryAlligatorLABS/`.

---

## 4. Build Vagrant Boxes (Required)

The lab uses custom Packer-built boxes. Download Windows ISOs (see `packer/ISO_INSTRUCTIONS.md`), then build:

```bash
# Download ISOs — see packer/ISO_INSTRUCTIONS.md
# Place ISOs in the iso/ directory

# Build Windows Server 2022 box (~45-90 minutes)
./build-boxes.sh --server-only

# Build Windows 10 Enterprise box (~45-90 minutes)
./build-boxes.sh --workstation-only
```

Or build both at once:
```bash
./build-boxes.sh
```

Verify boxes:
```bash
vagrant box list | grep secscope
```

Should show `secscope/windows-server-2022` and `secscope/windows-10-enterprise`.
Debian (`debian/bookworm64`) for lin01 is downloaded automatically from Vagrant Cloud on first `vagrant up`.

Expected output:
```
debian/bookworm64                  (virtualbox, 12.x.x)
secscope/windows-10-enterprise     (virtualbox, x.x.x)
secscope/windows-server-2022       (virtualbox, x.x.x)
```

---

## 5. Build the Lab

VMs **must** be started in dependency order. Each step must complete before moving to the next.
Total build time: ~2-3 hours (excluding box downloads).

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

The script runs all `vagrant up` and `vagrant provision` commands in dependency order,
handles the postboot reload automatically, and runs a final objects pass after all VMs are up.

### Manual Step-by-Step Build

Follow these steps if you prefer to run each command individually.

### Step 1 — Primary Domain Controller (DC01)

```bash
vagrant up dc01
```

- Renames computer to DC01, sets static IP
- **Triggers automatic reboot** — Vagrant will wait and reconnect via WinRM
- Duration: ~10-15 minutes

### Step 2 — DC01 Post-Boot (AD DS Forest Promotion)

```bash
vagrant provision dc01 --provision-with postboot
```

- Installs AD DS, DNS Server, RSAT tools
- Promotes to Domain Controller (forest root: `secscope.corp`)
- **No reboot is triggered** — `Install-ADDSForest` runs with `-NoRebootOnCompletion:$true`
- :warning: **EXPECTED ERROR:** A red `WinRM::WinRMAuthorizationError` will appear at the very end. This is cosmetic — the script exited successfully before the error occurred. Ignore it and proceed.
- Duration: ~10-15 minutes

### Step 3 — DC01 Reload (Mandatory)

```bash
vagrant reload dc01 --force
```

- Reboots DC01 to complete the AD DS promotion and start AD services
- **`--force` is required** — WinRM is dead after promotion; a plain `vagrant reload` will hang
- **This step is mandatory** — do not skip it
- Duration: ~5 minutes

### Step 4 — DC01 DNS Configuration

```bash
vagrant provision dc01 --provision-with dns
```

- Waits for AD services to be ready
- Creates DNS forwarder, reverse zone, A records for all lab machines
- Configures DHCP server and WPAD option
- Downloads and installs LAPS MSI (if internet available)
- Duration: ~3-5 minutes

### Step 5 — Secondary Domain Controller (DC02)

```bash
vagrant up dc02
```

- Renames to DC02, sets static IP
- **Triggers automatic reboot**
- Duration: ~10-15 minutes

### Step 6 — DC02 Domain Join (Promote as Additional DC)

```bash
vagrant provision dc02 --provision-with join
```

- Waits for DC01 to be reachable
- Installs AD DS, DNS Server
- Promotes as additional domain controller in `secscope.corp`
- **Triggers automatic reboot**
- Duration: ~15-20 minutes

### Step 7 — Subdomain Controller (DC03)

```bash
vagrant up dc03
```

- Renames to DC03, sets static IP
- **Triggers automatic reboot**
- Duration: ~10-15 minutes

### Step 8 — DC03 Domain Join (Subdomain Promotion)

```bash
vagrant provision dc03 --provision-with join
```

- Waits for DC01 to be reachable
- Installs AD DS, DNS Server
- Promotes as first DC in subdomain `it.secscope.corp`
- **Triggers automatic reboot**
- Duration: ~15-20 minutes

### Step 9 — Application Server (SRV01)

```bash
vagrant up srv01
```

- Renames to SRV01, sets static IP
- Waits for DC01, joins domain
- **Triggers automatic reboot** for domain join
- Duration: ~20-25 minutes

### Step 10 — Workstation 1 (WS01)

```bash
vagrant up ws01
```

- Renames to WS01, sets static IP
- Waits for DC01, joins domain
- **Triggers automatic reboot**
- Duration: ~10-15 minutes

### Step 11 — Workstation 2 (WS02)

```bash
vagrant up ws02
```

- Renames to WS02, sets static IP
- Waits for DC01, joins domain
- **Triggers automatic reboot**
- Duration: ~10-15 minutes

### Step 12 — Linux Domain Member (LIN01)

```bash
vagrant up lin01
```

- Installs SSSD, realmd, Kerberos packages
- Joins the domain via `realm join`
- Configures SSH, plants credentials and keys
- Duration: ~5-10 minutes

### Step 13 — AD Objects and ACL Misconfigurations

```bash
vagrant provision dc01 --provision-with objects
```

- Creates OUs, users, groups, SPNs
- Applies ACL misconfigurations (WriteDACL, GenericWrite, delegations)
- Creates GPP cpassword file in SYSVOL
- Sets weak password policy
- Duration: ~3-5 minutes

### Step 14 — SRV01 Services

```bash
vagrant provision srv01 --provision-with services
```

- Installs IIS web server
- Attempts SQL Server Express download and installation
- Enables xp_cmdshell
- Installs ADCS Enterprise Root CA + Web Enrollment
- Duration: ~10-15 minutes

### Step 15 — WS01 Misconfigurations

```bash
vagrant provision ws01 --provision-with misconfig
```

- Disables SMB signing, enables WDigest, disables LSA protection
- Enables NTLMv1, LLMNR/mDNS, NetBIOS
- Creates local admin, plants PowerShell history, scheduled task, service credentials
- Duration: ~2-3 minutes

### Step 16 — WS02 Misconfigurations

```bash
vagrant provision ws02 --provision-with misconfig
```

- Disables SMB signing, enables WDigest
- Adds anakin to local Administrators
- Enables Print Spooler service (PrinterBug coercion target)
- Duration: ~2-3 minutes

---

## 6. Verify VM Status

```bash
vagrant status
```

Expected output — all 7 VMs `running`:
```
dc01    running (virtualbox)
dc02    running (virtualbox)
dc03    running (virtualbox)
srv01   running (virtualbox)
ws01    running (virtualbox)
ws02    running (virtualbox)
lin01   running (virtualbox)
```

If any VM shows `poweroff` or `not created`, re-run its `vagrant up` command.

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
# Ping all lab VMs
for ip in 10 11 20 30 31 40; do
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
| srv01 | IIS Web Server, SQL Server Express (attempted), ADCS Certificate Authority, ADCS Web Enrollment |
| ws01 | (Intentionally misconfigured: WDigest, NTLMv1, LLMNR/mDNS/NetBIOS, disabled SMB signing/LSA, local admin, scheduled task, service credentials) |
| ws02 | (Intentionally misconfigured: WDigest, disabled SMB signing, Print Spooler) |
| lin01 | SSSD, realmd, adcli, Kerberos utilities, Samba, OpenSSH, Python3, nmap |
| Kali | (Manual install): impacket, responder, bloodhound, neo4j, crackmapexec, evil-winrm, smbclient, hashcat, john, seclists, nmap, netcat |

---

## 10. Time Estimates

| Stage | Approximate Time |
|-------|-----------------|
| Install VirtualBox + Vagrant | 10-15 min |
| Pre-download boxes | 1-4 hours (internet-dependent) |
| vagrant up dc01 | 10-15 min |
| dc01 postboot provision | 10-15 min |
| vagrant reload dc01 | 5 min |
| dc01 dns provision | 3-5 min |
| vagrant up dc02 | 10-15 min |
| dc02 join provision | 15-20 min |
| vagrant up dc03 | 10-15 min |
| dc03 join provision | 15-20 min |
| vagrant up srv01 | 20-25 min |
| vagrant up ws01 | 10-15 min |
| vagrant up ws02 | 10-15 min |
| vagrant up lin01 | 5-10 min |
| dc01 objects provision | 3-5 min |
| srv01 services provision | 10-15 min |
| ws01 misconfig provision | 2-3 min |
| ws02 misconfig provision | 2-3 min |
| Kali VM setup | 15-20 min |
| **Total (excluding downloads)** | **~2-3 hours** |

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

### Vagrant Box Download Fails
**Symptom:** `An error occurred while downloading the remote file.`

**Fix:**
1. Check internet connectivity: `ping 8.8.8.8`
2. Ensure boxes are built: `./build-boxes.sh` (see section 4 above)
3. If you need to use a pre-built box, build it from the packer directory:
   ```bash
   cd packer/windows-server-2022
   packer build windows-server-2022.pkr.hcl
   ```

### WinRM Timeout
**Symptom:** `Timed out while waiting for the machine to boot` or WinRM connection errors.

**Fix:** Windows VMs are slow on first boot. The Vagrantfile sets `boot_timeout = 900` (15 min).
If you still hit timeouts:
```bash
# Increase in Vagrantfile temporarily:
config.vm.boot_timeout = 1200
```

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

**Fix:** This is harmless. The Vagrantfile trigger handles this automatically
(on Windows: `& exit 0` suppresses the error; on Linux/macOS: `2>/dev/null` does the same).
If you need to reset it:
```bash
VBoxManage natnetwork remove --netname SECSCOPE.CORP
```

### DC01 Objects Script — "WS01 not found"
**Symptom:** During objects provisioning, WS01 and WS02 computer objects may not exist yet (VMs not booted).

**Fix:** The script now gracefully skips computer ACLs for VMs that are absent and prints a clear message. The setup scripts (`setup.sh` / `setup.ps1`) run a final objects pass after all VMs are up. Or re-run manually:
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

### Destroy all VMs (keep downloaded boxes)
```bash
vagrant destroy -f
```

### Destroy everything including boxes
```bash
vagrant destroy -f
vagrant box remove secscope/windows-server-2022
vagrant box remove secscope/windows-10-enterprise
vagrant box remove debian/bookworm64
```

### Full rebuild from scratch
```bash
vagrant destroy -f
vagrant up dc01
# ... repeat build steps from Section 5
```

---

## 13. Next Steps

Once the lab is built and verified:
- Read `README.md` for the lab topology, credential tables, and intentional vulnerability reference
- Take snapshots before exercises: `vagrant snapshot save dc01 clean`
- Begin the Attacking Active Directory course
