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

4. **Python 3.8+** (runs the `setup.py` orchestrator)
   - Download: https://www.python.org/downloads/
   - During install, tick **"Add python.exe to PATH"**.

5. Verify from **PowerShell (Admin)**:
   ```powershell
   vagrant --version          # must be >= 2.3.0
   VBoxManage --version       # must be >= 7.0
   python --version           # must be >= 3.8
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

4. **Python 3.8+** (runs the `setup.py` orchestrator; usually preinstalled):
   ```bash
   sudo apt-get install -y python3
   ```

5. Verify:
   ```bash
   vagrant --version
   vboxmanage --version
   python3 --version
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

| ISO / Image | Where to get it | Expected Filename | SHA256 |
|-----|----------|-------------------|--------|
| Windows Server 2022 (eval) | [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022) — choose the **64-bit ISO** | `SERVER_EVAL_x64FRE_en-us.iso` | `3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325` |
| Windows 10 22H2 | [Microsoft software-download](https://www.microsoft.com/en-us/software-download/windows10ISO) (from Linux the page serves a direct ISO link), **or** build a specific build with [UUP dump](https://uupdump.net/) → *Windows 10 22H2* → *x64* → *English* → Download method "Download and convert to ISO" | `Win10_22H2_English_x64v1.iso` | `a6f470ca6d331eb353b815c043e327a347f594f37ff525f17764738fe812852e` |
| Debian 12.15.0 netinst | [Direct (archive mirror)](https://laotzu.ftp.acc.umu.se/cdimage/archive/12.15.0/amd64/iso-cd/debian-12.15.0-amd64-netinst.iso) · [canonical archive index](https://cdimage.debian.org/cdimage/archive/12.15.0/amd64/iso-cd/) | `debian-12.15.0-amd64-netinst.iso` | `cd4462c06aa8892e692c0c4b9c17802f38c8ab8690e85cbfb5ccaa5956e9af17` |
| Kali Linux (attacker) | [Prebuilt VirtualBox VM](https://www.kali.org/get-kali/#kali-virtual-machines) (recommended — import, no install) · [Installer ISO](https://www.kali.org/get-kali/#kali-installer-images) | *(imported VM, not placed in `iso/`)* | *(verify on kali.org)* |

The Windows and Debian ISOs go in the `iso/` directory (rename to match the
expected filename). **Kali is not built by Packer** — it is a separate attacker
box imported straight into VirtualBox (see §7); it does not go in `iso/`.

> **Windows 10 / UUP dump:** UUP dump produces a multi-edition ISO. The
> `Autounattend.xml` selects **`Windows 10 Pro`**, which a UUP dump "Pro" or
> "consumer editions" ISO contains — so either works.

After downloading, verify the checksums match:

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

> **Edition must match the Autounattend image name.** The unattended installs
> select a specific Windows image by name:
> `packer/autounattend/windows-server-2022/Autounattend.xml` expects
> **`Windows Server 2022 SERVERSTANDARD`** and
> `packer/autounattend/windows-10/Autounattend.xml` expects **`Windows 10 Pro`**.
> If you supply a different edition ISO (e.g. a Datacenter-only or Home/Education
> image), Windows Setup fails with *"no image"* / *"Windows cannot find a
> product key"*. Use the exact ISOs above, or edit the `/IMAGE/NAME` value in the
> matching `Autounattend.xml` to an image the ISO actually contains
> (`dism /Get-WimInfo /WimFile:<mounted>\sources\install.wim` lists them).
>
> **Debian box:** `lin01` boots from the locally-built `secscope/debian-bookworm`
> box, which Packer builds from `iso/debian-12.15.0-amd64-netinst.iso`. It is
> built **by default** by `build-boxes` (alongside the two Windows boxes). If the
> Debian ISO isn't present it is skipped with a warning (Windows-only users aren't
> blocked); pass `--skip-debian` to always skip it.

### Build Boxes

Build all three base boxes at once (the default — Windows Server 2022, Windows 10,
and the Debian box for `lin01`):
```bash
python3 setup.py build-boxes
```
If the Debian ISO isn't in `iso/`, the Debian box is skipped with a warning and
the two Windows boxes still build.

Or build just one box at a time:
```bash
python3 setup.py build-boxes --server-only       # Windows Server 2022 (~45-90 min)
python3 setup.py build-boxes --workstation-only   # Windows 10 (~45-90 min)
python3 setup.py build-boxes --debian-only        # Debian (for lin01)
python3 setup.py build-boxes --skip-debian        # both Windows boxes, no Debian
```

Verify boxes:
```bash
vagrant box list | grep secscope
```

Should show:
```
secscope/debian-bookworm           (virtualbox, x.x.x)
secscope/windows-10                (virtualbox, x.x.x)
secscope/windows-server-2022       (virtualbox, x.x.x)
```
(`secscope/debian-bookworm` appears only if the Debian ISO was present / you
didn't pass `--skip-debian`. `lin01` requires it.)

If a build fails with "box not found", run `python3 setup.py build-boxes` first.

---

## 5. Build the Lab

### Per-machine build (dependency-ordered)

Orchestration lives in **`setup.py`** (Python 3.8+; `./setup.sh` is a thin
wrapper). Machines are built **one at a time** in dependency order — there is no
single "deploy everything" step. Each machine can be built only once (a second
attempt is refused unless you use `rebuild` or `--force`).

**Build order (hard-enforced):**
```
dc01  ->  dc02  ->  dc03            (dc03 needs BOTH dc01 and dc02)
dc01  ->  {srv01, ws01, ws02, lin01}
```

```bash
python3 setup.py build dc01          # forest root — build first
python3 setup.py build dc02          # requires dc01 running + provisioned
python3 setup.py build dc03          # requires dc01 AND dc02
python3 setup.py build srv01         # requires dc01
python3 setup.py build ws01 ws02 lin01
```

Build several or all at once (still dependency-ordered):
```bash
python3 setup.py build all                 # sequential, in order
python3 setup.py build all --parallel       # overlap independent VMs
python3 setup.py build all --max-parallel 2 # cap concurrency (default 2)
```

If a dependency is missing, the build aborts immediately with a message telling
you exactly what to build first. Check state any time with:
```bash
python3 setup.py status
```

**Dependency reference** (a machine builds only once its dependencies are running
and fully provisioned):

| Machine | Requires first | Notes |
|---------|----------------|-------|
| DC01 | — | Forest root; build first. |
| DC02 | DC01 | Replica DC in `secscope.corp`. |
| DC03 | DC01 **and** DC02 | Child domain `it.secscope.corp` (needs a converged replication partner). |
| SRV01 | DC01 | Member: MSSQL + IIS + ADCS. |
| WS01 | DC01 | Workstation. |
| WS02 | DC01 | Workstation. |
| LIN01 | DC01 | Linux (SSSD) member. |

Recommended order: **dc01 → dc02 → dc03 → srv01, ws01, ws02, lin01**. The members
only depend on DC01 and are independent of each other. See the **Build
Dependencies** section in `README.md` for the full dependency diagram.

### Build Options

```bash
python3 setup.py build dc01 --force     # override the one-time build guard
python3 setup.py rebuild ws01           # destroy + rebuild a single machine
python3 setup.py build dc01 --verbose   # full provisioning output
python3 setup.py build dc01 --quiet     # minimal output
```

### Locking down (optional, after building)

`harden` and `seal` cut off Vagrant management, so run them only when the
machines are finished. Easiest is the one-step `finalize`, which runs the whole
sequence in the correct order (verify internal IPs -> fix NAT-leak DNS ->
harden -> seal):
```bash
python3 setup.py finalize all        # harden + fix DNS + seal, in one step
python3 setup.py finalize all --no-dns-clean   # ...but skip the DNS purge
```
`finalize` also purges the stale `10.0.2.*` (NAT-leak) DNS records from DC01 so
names resolve on `192.168.200.x` only. The individual steps remain available if
you want finer control:
```bash
python3 setup.py harden all          # remove vagrant credentials
python3 setup.py seal all            # single-home each VM on 192.168.200.x
python3 setup.py unseal <vm>         # (restore the NAT nic1 to regain mgmt;
                                     #  the deleted vagrant account is NOT restored)
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
| Build Debian Bookworm box | 10-20 min |
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
vagrant box remove secscope/debian-bookworm
```

### Full rebuild from scratch
```bash
./setup.sh destroy
./setup.sh
```
