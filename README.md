<h1 align="center">Active Directory Alligator Labs</h1>

<p align="center"><img src="images/logo.png" alt="Logo" width="450"/></p>

> 🌐 **English:** this file · **العربية:** [README_AR.md](README_AR.md) | Arabic install guide: [INSTALL_AR.md](INSTALL_AR.md)

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

Orchestration is driven by **`setup.py`** (Python 3.8+, standard library only).
`./setup.sh` is a thin wrapper that just calls it. Machines are built **one at a
time, in dependency order** — there is no "deploy everything" mega-command.

```bash
# 1. Place ISOs
#    iso/SERVER_EVAL_x64FRE_en-us.iso     (Windows Server 2022)
#    iso/Win10_22H2_English_x64v1.iso     (Windows 10)

# 2. Build Packer boxes (~45-90 min each, sequential)
python3 setup.py build-boxes

# 3. Build the lab machine-by-machine, in dependency order
python3 setup.py build dc01          # forest root (build first)
python3 setup.py build dc02          # requires dc01
python3 setup.py build dc03          # requires dc01 AND dc02
python3 setup.py build srv01 ws01 ws02 lin01   # members (require dc01)

#    ...or build everything at once, still dependency-ordered:
python3 setup.py build all           # add --parallel to overlap members

# 4. (optional, when finished) lock the lab down
python3 setup.py finalize all        # harden + fix NAT-leak DNS + seal (one step)
#   or run the individual steps:
python3 setup.py harden all          # remove vagrant creds (severs Vagrant mgmt)
python3 setup.py seal all            # single-home each VM on 192.168.200.x
```

> **python3 required.** Install from https://www.python.org/downloads/ (Debian/Ubuntu: `sudo apt install python3`). `./setup.sh` forwards to `setup.py`.

> **Windows evaluation period:** Both Windows boxes are built from evaluation ISOs valid for 180 days. After expiration, Windows will shut down every hour. Check remaining time: `slmgr /dli`. Rearm (up to 3 times): `slmgr /rearm`.

## Build Dependencies

Each machine can only be built once the machines it depends on are **running and
fully provisioned**. `setup.py` enforces this: if a dependency is missing, the
build aborts with an explicit message telling you what to build first (it never
auto-builds dependencies for you). Boxes must be registered first (`build-boxes`).

| Machine | Requires (must be built first) | Why |
|---------|--------------------------------|-----|
| **DC01** | *(nothing)* | Forest root DC — build this first. |
| **DC02** | **DC01** | Replica DC joins the existing `secscope.corp` domain on DC01. |
| **DC03** | **DC01 + DC02** | Child domain `it.secscope.corp` needs the forest root **and** a converged replication partner (DC02) before `Install-ADDSDomain`. |
| **SRV01** | **DC01** | Member server joins the domain; its ADCS/MSSQL/ACL config needs DC01's AD objects. |
| **WS01** | **DC01** | Workstation joins the domain. |
| **WS02** | **DC01** | Workstation joins the domain. |
| **LIN01** | **DC01** | Linux member joins via SSSD/realmd against DC01. |

```
          ┌───────┐
          │ DC01  │  (forest root — build first)
          └───┬───┘
     ┌────────┼───────────────┬────────┬────────┬────────┐
     ▼        ▼               ▼        ▼        ▼        ▼
  ┌──────┐  ┌──────┐       ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
  │ DC02 │  │SRV01 │       │ WS01 │ │ WS02 │ │LIN01 │ │ ...  │
  └──┬───┘  └──────┘       └──────┘ └──────┘ └──────┘ └──────┘
     ▼
  ┌──────┐
  │ DC03 │  (also needs DC01)
  └──────┘
```

**Recommended order:** `dc01` → `dc02` → `dc03` → `srv01`, `ws01`, `ws02`, `lin01`
(the members are independent of each other and only need DC01, so they can be
built in any order — or overlapped with `build all --parallel`).

```bash
# Dependency-ordered examples
python3 setup.py build dc01                 # no deps
python3 setup.py build dc02                 # needs dc01 ready
python3 setup.py build dc03                 # needs dc01 AND dc02 ready
python3 setup.py build srv01 ws01 ws02      # each only needs dc01
python3 setup.py build all                  # everything, auto-ordered
python3 setup.py build all --parallel       # overlap independent members (deps stay serialized)
```

> Members (`srv01`/`ws01`/`ws02`/`lin01`) require only **DC01**, but for a full
> forest you normally build the DCs first (`dc01` → `dc02` → `dc03`) so the
> cross-domain objects and trust exist before members and their ACLs are applied.

## Setup Script Options

`setup.py` builds **one machine at a time** with hard dependency enforcement and
a one-time build guard (an already-built VM is refused unless you use `rebuild`
or `--force`, to avoid resource damage). Run `python3 setup.py help` for the full
reference.

```bash
# Build boxes
python3 setup.py build-boxes                 # Build all 3 boxes (Win2022 + Win10 + Debian)
python3 setup.py build-boxes --server-only   # Server 2022 only
python3 setup.py build-boxes --workstation-only  # Windows 10 only
python3 setup.py build-boxes --debian-only   # Debian box only (lin01 needs it)
python3 setup.py build-boxes --skip-debian   # both Windows boxes, skip Debian

# Build machines (dependency-ordered, one-at-a-time)
python3 setup.py build dc01                  # single machine
python3 setup.py build srv01 ws01 ws02       # several (sequential)
python3 setup.py build all                   # everything in order
python3 setup.py build all --parallel        # overlap independent VMs
python3 setup.py build all --max-parallel 2  # cap concurrency (default 2)
python3 setup.py rebuild ws01                # destroy + rebuild one VM
python3 setup.py build dc01 --force          # override the one-time guard

# Dependency map (hard-blocking):
#   dc01  <- (none)          dc02 <- dc01        dc03 <- dc01, dc02
#   srv01 <- dc01            ws01 <- dc01        ws02 <- dc01   lin01 <- dc01

# Output control (any command)
python3 setup.py build dc01 --verbose        # show all provisioning output
python3 setup.py build dc01 --quiet          # minimal output
python3 setup.py build dc01 --debug          # show suppressed WinRM errors

# Management
python3 setup.py status                      # live table of all VM states
python3 setup.py finalize <vm>|all           # harden + fix NAT-leak DNS + seal
python3 setup.py harden <vm>|all             # remove vagrant creds (post-build)
python3 setup.py seal <vm>|all               # remove NAT nic1 (single-homed)
python3 setup.py unseal <vm>|all             # restore NAT nic1 (re-enable mgmt)
python3 setup.py destroy <vm>|all            # destroy machine(s)
python3 setup.py help                        # full help + dependency map
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

Once the `harden` command runs (`python3 setup.py harden <vm>|all`, or as part of
`finalize`):
- The `vagrant` account is disabled/removed on the targeted Windows VMs
- WinRM basic auth is disabled
- `vagrant reload`, `vagrant provision`, and `vagrant winrm` commands will NO LONGER WORK

`finalize` (`python3 setup.py finalize <vm>|all`) does this and then `seal`s the
VMs, in the right order, and also purges the stale `10.0.2.*` (NAT-leak) DNS
records on DC01 so names resolve on `192.168.200.x` only. `unseal` can restore
the NAT adapter afterwards, but it does NOT restore the deleted `vagrant`
account (reach VMs via `Administrator`/`ADMIN_PASS` or the VirtualBox console).

Only harden a machine when it is fully built and ready. To rebuild from scratch:
```bash
python3 setup.py destroy all
python3 setup.py build all
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

**Box not found:** The base boxes must be built with `python3 setup.py build-boxes` before building any machine (`setup.py build` now preflight-checks this and tells you). `build-boxes` builds all three by default — Windows Server 2022, Windows 10, and `secscope/debian-bookworm` (which `lin01` boots from, built locally from the Debian netinst ISO).

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
