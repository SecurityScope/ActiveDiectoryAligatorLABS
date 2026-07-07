<h1 align="center">Active Directory Alligator Labs</h1>

<p align="center"><img src="images/logo.png" alt="Logo" width="450"/></p>

A self-contained Active Directory lab environment with intentional misconfigurations for penetration testing practice.

## Overview

This Vagrant project deploys a realistic Active Directory lab covering:

- AD foundations (domains, forests, trusts)
- Authentication protocols (NTLM, Kerberos)
- Network poisoning and relay attacks
- Credential access and dumping
- Privilege escalation via ACL abuse
- Lateral movement techniques
- Post-exploitation (ADCS, LAPS, MSSQL)

## Requirements

| Component | Minimum Version |
|-----------|----------------|
| Vagrant   | >= 2.3.0       |
| VirtualBox | >= 7.0         |
| RAM       | 16 GB          |
| Disk      | 150 GB free    |
| Host OS   | Windows 10/11, macOS, or Linux |

## Quick Start

Place Windows ISOs in the `iso/` directory, then build and deploy:

```bash
# 1. Place ISOs
#    iso/SERVER_EVAL_x64FRE_en-us.iso     (Windows Server 2022)
#    iso/Win10_22H2_English_x64v1.iso     (Windows 10)

# 2. Build Packer boxes (~45-90 min each, sequential)
./setup.sh build-boxes

# 3. Deploy the lab (~75-90 minutes)
./setup.sh
```

**Windows PowerShell:**
```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1 build-boxes
powershell -ExecutionPolicy Bypass -File setup.ps1
```

> **Windows evaluation period:** Both Windows boxes are built from evaluation ISOs valid for 180 days. After expiration, Windows will shut down every hour. Check remaining time: `slmgr /dli`. Rearm (up to 3 times): `slmgr /rearm`.

## Setup Script Options

The `setup.sh` / `setup.ps1` scripts support multiple subcommands and options:

```bash
# Build boxes
./setup.sh build-boxes              # Build both boxes
./setup.sh build-boxes --server-only   # Server 2022 only
./setup.sh build-boxes --workstation-only  # Windows 10 only

# Deploy (default)
./setup.sh                          # Full deploy, all VMs
./setup.sh deploy --dc01-only       # Build only DC01
./setup.sh deploy --vms dc01,ws01   # Deploy specific VMs only
./setup.sh deploy --skip-misconfig  # Skip WS01/WS02 misconfigurations
./setup.sh deploy --skip-hardening  # Skip vagrant account hardening
./setup.sh deploy --skip-linux      # Skip LIN01

# Output control
./setup.sh deploy --verbose         # Show all provisioning output
./setup.sh deploy --quiet           # Minimal output
./setup.sh deploy --debug           # Show suppressed WinRM errors

# Management
./setup.sh status                   # Show VM states
./setup.sh destroy                  # Destroy all VMs
./setup.sh help                     # Show full help
```

## VM Inventory

| VM   | Hostname | IP             | OS                    | RAM    | CPUs | Role                                  |
|------|----------|----------------|-----------------------|--------|------|---------------------------------------|
| dc01 | DC01     | 192.168.200.10  | Windows Server 2022   | 2048 MB | 2   | Primary Domain Controller, DNS        |
| dc02 | DC02     | 192.168.200.11  | Windows Server 2022   | 2048 MB | 2   | Secondary DC, replication target      |
| dc03 | DC03     | 192.168.200.12  | Windows Server 2022   | 2048 MB | 2   | Subdomain DC (it.secscope.corp)       |
| srv01| SRV01    | 192.168.200.20  | Windows Server 2022   | 3072 MB | 2   | MSSQL + IIS + ADCS CA                 |
| ws01 | WS01     | 192.168.200.30  | Windows 10 Pro        | 2048 MB | 2   | Domain workstation, primary pivot     |
| ws02 | WS02     | 192.168.200.31  | Windows 10 Pro        | 2048 MB | 2   | Domain workstation, unconstrained del.|
| lin01| lin01    | 192.168.200.40  | Debian 12             | 1024 MB | 1   | Linux domain member, SSH target       |

**Domain:** `secscope.corp` | **NetBIOS:** `SECSCOPE` | **Subdomain:** `it.secscope.corp`

## Managing VMs

VMs can be halted individually to free resources:

```bash
vagrant halt ws01 ws02             # free ~4 GB
vagrant halt dc03 srv01            # free ~5 GB
vagrant halt lin01                 # free ~1 GB
vagrant status                     # check what's running
```

> **Note:** DC01 is required for all operations (it hosts the domain, DNS, and KDC). Keep it running as long as the lab is active.

## Kali Setup

Kali Linux is **not** managed by Vagrant. Install Kali manually in VirtualBox:

1. Download Kali Linux from [kali.org](https://www.kali.org/get-kali/#kali-virtual-machines)
2. Import the OVA into VirtualBox
3. In VirtualBox VM Settings > Network > Adapter 1: Attach to **NAT Network** named `SECSCOPE.CORP`
4. Boot Kali and set a static IP:
   ```bash
   sudo ip addr add 192.168.200.99/24 dev eth0
   ```
5. Add lab entries to `/etc/hosts`:
   ```
   192.168.200.10  dc01.secscope.corp dc01
   192.168.200.11  dc02.secscope.corp dc02
   192.168.200.12  dc03.secscope.corp dc03 it.secscope.corp
   192.168.200.20  srv01.secscope.corp srv01
   192.168.200.30  ws01.secscope.corp ws01
   192.168.200.31  ws02.secscope.corp ws02
   192.168.200.40  lin01.secscope.corp lin01
   ```
6. Install required tools:
   ```bash
   sudo apt-get update -qq
   sudo apt-get install -y -qq impacket-scripts responder bloodhound neo4j crackmapexec evil-winrm smbclient ldap-utils krb5-user hashcat john seclists wordlists nmap netcat-openbsd python3-pip golang
   pip3 install bloodhound --quiet
   ```

## Domain Credentials

| Username       | Password         | Type           | Notes                          |
|----------------|------------------|----------------|--------------------------------|
| Administrator  | SecScope2024!    | Domain Admin   | Primary domain admin           |
| anakin         | Vader2024!       | Domain Admin   | IT admin user                  |
| han            | Solo2024!        | Domain User    | IT user, HelpDesk, AcctOps     |
| leia           | Princess2024!    | Domain User    | HR Manager                     |
| luke           | password         | Domain User    | Weak password - crack target   |
| svc_sql        | SqlService123    | Service Account| Kerberoastable                 |
| svc_web        | WebService123    | Service Account| Kerberoastable                 |
| svc_backup     | Backup123        | Service Account| Backup Operators member        |
| taskuser       | Task1234!        | Service Account| In LSA Secrets                 |
| nopreauth      | NoPreAuth123     | Domain User    | ASREPRoastable                 |
| localadmin     | LocalAdmin2024!  | Local Admin    | WS01 local account             |
| labuser        | LabUser2024!     | Linux Local    | lin01 local user               |
| exch_admin     | Exchange2024!    | Domain User    | Organization Management member |
| vagrant        | vagrant          | Local (all VMs)| Vagrant default (disabled after harden) |

## Lab Topology

```
                         ┌─────────────────────────────────────┐
                         │       VirtualBox NAT Network        │
                         │   SECSCOPE.CORP (192.168.200.0/24)  │
                         └─────────────────────────────────────┘
                                         │
             ┌────────────┬───────────────┬───────────────┬───────────────┬────────────┬────────────┬
             │            │               │               │               │            │            │
          ┌──┴──┐      ┌──┴──┐         ┌──┴──┐         ┌──┴──┐         ┌──┴──┐      ┌──┴──┐      ┌──┴──┐
          │DC01 │      │DC02 │         │DC03 │         │SRV01│         │WS01 │      │WS02 │      │lin01│
          │ .10 │      │ .11 │         │ .12 │         │ .20 │         │ .30 │      │ .31 │      │ .40 │
          │  DC │      │  DC │         │ IT  │         │IIS+ │         │Win10│      │Win10│      │Deb12│
          │KDC  │      │     │         │  DC │         │MSSQL│         │     │      │     │      │     │
          │DNS  │      │     │         │     │         │ADCS │         │     │      │     │      │     │
          └─────┘      └─────┘         └─────┘         └─────┘         └─────┘      └─────┘      └─────┘

                                       ┌─────────────────────┐
                                       │       Kali Linux    │
                                       │    192.168.200.99   │
                                       │  (Manual install)   │
                                       └─────────────────────┘
```

## Provisioning Steps

Each VM has named provisioners you can run individually:

```bash
# DC01 (common + base run automatically on vagrant up; postboot/dns/objects must be run manually)
vagrant up dc01                                    # Runs common + base + reboot automatically
vagrant provision dc01 --provision-with postboot     # AD DS forest promote (NO reboot)
vagrant reload dc01 --force                          # Reboot (mandatory - WinRM dead after promotion)
vagrant provision dc01 --provision-with dns          # DNS, reverse zone, A records, LAPS
vagrant provision dc01 --provision-with objects      # AD users, groups, ACLs, GPP

# DC02 (common + base run automatically on vagrant up)
vagrant up dc02                                    # Runs common + base + reboot automatically
vagrant provision dc02 --provision-with join      # AD DS install + promote
vagrant reload dc02 --force                        # Reboot after promotion

# DC03 (subdomain)
vagrant up dc03                                    # Runs common + base + reboot automatically
vagrant provision dc03 --provision-with join      # AD DS install + subdomain promote
vagrant reload dc03 --force                        # Reboot after promotion

# SRV01 (common runs automatically on vagrant up)
vagrant up srv01                                   # Runs common + join + reboot automatically
vagrant provision srv01 --provision-with services    # IIS, SQL, ADCS

# WS01 (common runs automatically on vagrant up)
vagrant up ws01                                    # Runs common + join + reboot automatically
vagrant provision ws01 --provision-with misconfig    # Vulnerabilities

# WS02 (common runs automatically on vagrant up)
vagrant up ws02                                    # Runs common + join + reboot automatically
vagrant provision ws02 --provision-with misconfig    # Vulnerabilities

# LIN01
vagrant provision lin01 --provision-with setup
```

## Intentional Vulnerabilities

| Vulnerability                     | Target              | Attack                             |
|-----------------------------------|---------------------|------------------------------------|
| Pre-auth disabled                 | nopreauth           | ASREPRoast                         |
| SPN on user accounts              | svc_sql, svc_web    | Kerberoasting                      |
| Unconstrained delegation          | WS02$               | TGT capture via PrinterBug         |
| Constrained delegation (no PT)    | SRV01$              | S4U2Proxy abuse                    |
| SMB signing disabled              | WS01, WS02          | NTLM Relay                         |
| NTLMv1 enabled (LMCompatLvl=0)    | WS01                | NTLMv1 hash capture & cracking     |
| LLMNR / mDNS / NetBIOS enabled    | WS01                | Poisoning -> hash capture          |
| WPAD DNS record                   | DNS (dc01)          | WPAD poisoning                     |
| WDigest enabled                   | WS01, WS02          | Plaintext creds from LSASS         |
| LSA protection disabled           | WS01                | LSASS dump                         |
| Scheduled task creds              | WS01                | LSA Secrets                        |
| Service account creds in registry | WS01                | LSA Secrets                        |
| GPP cpassword                     | SYSVOL              | Get-GPPPassword                    |
| WriteDACL on domain               | han user            | Grant DCSync -> dump creds         |
| GenericWrite on WS01              | HelpDesk group      | RBCD -> machine takeover           |
| WriteProperty on Domain Admins    | HelpDesk group      | Self-add to Domain Admins          |
| AdminSDHolder GenericWrite        | han user            | SDProp persistence                 |
| han in Account Operators          | han user            | Protected group persistence        |
| xp_cmdshell enabled               | SRV01 MSSQL         | OS command execution               |
| ADCS ESC1 template                | SRV01 CA            | Certificate -> TGT                 |
| PowerShell history                | WS01                | Credential in history              |
| SSH key planted                   | lin01               | Key reuse / discovery              |
| Bash history creds                | lin01 (labuser)     | Credential discovery               |
| Kerberos keytab                   | lin01               | Keytab extraction                  |
| LAPS (optional)                   | DC01 / WS01         | LAPS password read by han          |
| Subdomain trust                   | dc03                | Inter-realm TGT, SID History       |
| Exchange Windows Permissions      | DC01 AD             | WriteDACL on domain -> DCSync      |
| Organization Management -> EWP    | DC01 AD             | Self-add to Exchange Windows Perm  |
| ESC1 certificate template         | SRV01 CA            | Enrollee supplies subject -> TGT   |

## After Running Hardening

Once the `harden` provisioner runs:
- The `vagrant` account is disabled on all Windows VMs
- WinRM basic auth is disabled
- `vagrant reload`, `vagrant provision`, and `vagrant winrm` commands will NO LONGER WORK

Only run hardening when the lab is fully built and ready. To rebuild:
```bash
./setup.sh destroy
./setup.sh
```

## Snapshots

Take snapshots before exercises to easily revert:

```bash
vagrant snapshot save dc01 clean
vagrant snapshot save dc02 clean
vagrant snapshot save ws01 clean
```

Restore with:
```bash
vagrant snapshot restore dc01 clean
```

## Network Details

All VMs connect via a VirtualBox NAT Network named `SECSCOPE.CORP` (subnet `192.168.200.0/24`). The Vagrantfile creates this network automatically. NIC1 is the default Vagrant NAT adapter (management). NIC2 is the `SECSCOPE.CORP` NAT Network adapter with static IPs set by provisioning scripts.

## Troubleshooting

**WinRM auth error after DC promotion:** After `vagrant provision dc01 --provision-with postboot` (or `dc02`/`dc03` join), a red `WinRM::WinRMAuthorizationError` appears. This is expected - AD DS promotion invalidates the WinRM session. Always use `vagrant reload <vm> --force` after promotion; a plain `vagrant reload` will hang for 30 minutes trying WinRM before falling back.

**WinRM timeout:** Windows VMs are slow on first boot. The Vagrantfile sets `boot_timeout = 300` and `winrm.timeout = 180`. If you still get timeouts, increase these values in the Vagrantfile.

**Box not found:** Windows boxes must be built with `./setup.sh build-boxes` before running `vagrant up`. Debian (`debian/bookworm64`) is the only box downloaded automatically.

**"WS01 not found" during objects provisioning:** Computers must be domain-joined before `dc01_objects.ps1` can apply ACLs to them. The setup scripts run a final objects pass after all VMs are up.

**SQL Server download fails:** The script will display a warning and continue. Install SQL Server Express manually on SRV01 if needed.

**LAPS not installed:** The `dc01_dns.ps1` script attempts to download LAPS. If it fails, download `LAPS.x64.msi` from Microsoft and install manually on DC01.

**VM hostnames not resolving from host OS:** By default, Vagrant does not edit your host's `hosts` file. Add entries manually:
```
192.168.200.10  dc01.secscope.corp dc01
192.168.200.11  dc02.secscope.corp dc02
192.168.200.12  dc03.secscope.corp dc03 it.secscope.corp
192.168.200.20  srv01.secscope.corp srv01
192.168.200.30  ws01.secscope.corp ws01
192.168.200.31  ws02.secscope.corp ws02
```

**PowerShell Execution Policy (Windows):** Windows 11 defaults to `Restricted` which blocks `.ps1` files. Run this once:
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```
Or always use the `-ExecutionPolicy Bypass` flag with `powershell`.

**Hyper-V / WSL2 / Docker conflict (Windows):** Only one hypervisor can use VT-x at a time. If Vagrant VMs fail to start with `VT-x is not available`:
```powershell
dism.exe /Online /Disable-Feature:Microsoft-Hyper-V
bcdedit /set hypervisorlaunchtype off
```
Reboot. See [INSTALL.md](INSTALL.md) for details.
