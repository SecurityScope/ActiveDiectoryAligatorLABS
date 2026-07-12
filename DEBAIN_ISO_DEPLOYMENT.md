# Debian ISO Deployment Report — LIN01 from Bookworm Net-Install ISO

## Overview

LIN01 was migrated from `debian/bookworm64` (Vagrant Cloud, auto-downloaded) to a locally-built Vagrant box (`secscope/debian-bookworm`) created from the Debian 12.15.0 net-install ISO via Packer. This mirrors the pattern used for all Windows VMs (built from ISO → Packer → `.box` → `vagrant box add`), eliminating the last external Vagrant Cloud dependency.

**Date:** 2026-07-12  
**Branch:** `main`  
**Build time (approx):** 10–20 minutes (Debian net-install + Guest Additions)

---

## Architecture

```
iso/debian-12.15.0-amd64-netinst.iso     # User-downloaded (677 MB)
       │
       ▼
packer/debian-bookworm/
  ├── debian-bookworm.pkr.hcl              # Packer HCL template
  ├── vagrantfile-template.rb              # Box metadata (ssh, boot order)
  └── http/
      └── preseed.cfg                      # Unattended Debian install
       │
       ▼
packer/scripts/install_vboxga_linux.sh     # Post-install: VB Guest Additions
       │
       ▼
packer/boxes/debian-bookworm.box          # Output: Vagrant box
       │
       ▼
./setup.sh build-boxes --debian-only      # Build + vagrant box add
       │
       ▼
Vagrantfile → LIN01 uses secscope/debian-bookworm
       │
       ▼
scripts/lin01_setup.sh                     # Same provisioning (unchanged)
```

---

## Files Created

### `packer/debian-bookworm/http/preseed.cfg`

Debian unattended installation configuration. Key decisions:

| Section | Choice | Reason |
|---------|--------|--------|
| Locale | `en_US.UTF-8` | Consistent with US keyboard labs |
| Keyboard | `us` | Standard |
| Mirror | `deb.debian.org` | Global CDN, fast for all regions |
| Components | `main` only (no contrib/non-free) | Minimal, no firmware blobs needed in VM |
| Partitioning | Single ext4 partition, entire disk, no LVM | Simplest, 20 GB virtual disk |
| Swap | None | Not needed; VM has constrained disk |
| Tasksel | Empty (no desktop) | No GUI — headless server only |
| Packages | `openssh-server`, `sudo` | Bare minimum for SSH + Vagrant management |
| User | `vagrant` / `vagrant` | Matches Vagrant convention |
| Root password | `vagrant` | Same as user for simplicity |
| Sudoers | `vagrant ALL=(ALL) NOPASSWD: ALL` | Passwordless sudo (Vagrant convention) |
| GRUB | Install to MBR, no other OS | Single-boot VM |
| Reboot | Automatic after install | Let Packer detect SSH ready |

### `packer/debian-bookworm/debian-bookworm.pkr.hcl`

Packer template following the Windows pattern:

- **Source:** `virtualbox-iso` builder, `Debian_64` guest type
- **ISO:** `iso/debian-12.15.0-amd64-netinst.iso`
- **Resources:** 20 GB disk, 1024 MB RAM, 2 CPUs, headless
- **Communicator:** SSH on port 22, `vagrant`/`vagrant`, 30 minute timeout
- **HTTP directory:** Serves `preseed.cfg` via Packer's built-in HTTP server
- **Boot command:** `<esc>` → ISOLINUX `boot:` prompt → kernel params with `auto url=http://...` 
- **Guest Additions:** `attach` mode (Packer mounts the GA ISO)
- **Provisioner:** Shell script installs VBox Guest Additions (build deps → mount → run → cleanup)
- **Post-processor:** Vagrant box → `packer/boxes/debian-bookworm.box`

### `packer/debian-bookworm/vagrantfile-template.rb`

Box metadata (embedded in the `.box`):
- SSH communicator (`vagrant`/`vagrant`)
- `--boot1 disk --boot2 none` — fixes the DVD-first boot order baked in by the Packer build (same issue as Windows boxes)

### `packer/scripts/install_vboxga_linux.sh`

Linux equivalent of `install_vboxga.ps1`:
1. Updates apt cache
2. Installs build dependencies (`build-essential`, `dkms`, `linux-headers-$(uname -r)`)
3. Mounts `/dev/sr0` (VirtualBox Guest Additions ISO, attached by Packer)
4. Runs `VBoxLinuxAdditions.run`
5. Unmounts and cleans up build deps

---

## Files Modified

### `Vagrantfile`

| Line(s) | Change |
|---------|--------|
| LIN01 box | `debian/bookworm64` → `secscope/debian-bookworm` |
| LIN01 provider | Added `config.ssh.username = "vagrant"`, `config.ssh.password = "vagrant"` |
| LIN01 provider | Added `--boot1 disk --boot2 none` boot order fix |
| LIN01 provider | Added SSH forwarded port (`guest: 22 → host: 22240`, `auto_correct: true`) |
| NIC2 config | Migrated to explicit `v.customize` calls (was fine before, just standardized) |

### `setup.sh`

| Section | Change |
|---------|--------|
| Defaults (L13) | Added `DEBIAN_ISO="${DEBIAN_ISO:-${SCRIPT_DIR}/iso/debian-12.15.0-amd64-netinst.iso}"` |
| Flags (L112) | Added `BUILD_DEBIAN=true` |
| Argument parsing | Added `--debian-only` (sets `BUILD_SERVER=false; BUILD_WIN10=false; BUILD_DEBIAN=true`) |
| Argument parsing | Added `--skip-debian` (sets `BUILD_DEBIAN=false`) |
| Argument parsing | Added `--debian-iso <path>` (custom ISO path) |
| `cmd_build_boxes` | Added cleanup: `VBoxManage unregistervm packer-debian-bookworm` |
| `cmd_build_boxes` | Added Debian build block (`[3] Building Debian Bookworm box...`) |
| `cmd_build_boxes` | Added `vagrant box add secscope/debian-bookworm` |
| Help text | Added `--debian-only`, `--skip-debian`, `--debian-iso` to BUILD-BOXES OPTIONS |
| Help examples | Added `./setup.sh build-boxes --debian-only` |

### `setup.ps1`

| Section | Change |
|---------|--------|
| Defaults (L42) | Added `$DefaultDebianISO = Join-Path $ScriptDir "iso\debian-12.15.0-amd64-netinst.iso"` |
| Params | Added `[switch]$DebianOnly`, `[switch]$SkipDebian`, `[string]$DebianISO = ""` |
| `Invoke-BuildBoxes` | Added `$BuildDebian` logic |
| `Invoke-BuildBoxes` | Added cleanup: `VBoxManage unregistervm packer-debian-bookworm` |
| `Invoke-BuildBoxes` | Added Debian build block (`[3] Building Debian Bookworm box...`) |
| `Invoke-BuildBoxes` | Added `vagrant box add secscope/debian-bookworm` |
| Help text | Added Debian flags |

### `INSTALL.md`

| Section | Change |
|---------|--------|
| ISO table | Added Debian 12.15.0 net-install row (URL, filename, SHA256) |
| Build commands | Added `./setup.sh build-boxes --debian-only` |
| Box listing | Added `secscope/debian-bookworm (virtualbox, x.x.x)` |
| Vagrant Cloud note | Removed (line 207: "Debian...is auto-downloaded from Vagrant Cloud") |
| Uninstall section | Updated to use `secscope/debian-bookworm` instead of `debian/bookworm64` |

### `README.md`

| Section | Change |
|---------|--------|
| Troubleshooting | Updated "Box not found" to mention Debian box is also built from ISO |

---

## ISO Details

| Property | Value |
|----------|-------|
| **Filename** | `debian-12.15.0-amd64-netinst.iso` |
| **Size** | 677 MB |
| **SHA256** | `cd4462c06aa8892e692c0c4b9c17802f38c8ab8690e85cbfb5ccaa5956e9af17` |
| **Download** | https://laotzu.ftp.acc.umu.se/cdimage/archive/12.15.0/amd64/iso-cd/debian-12.15.0-amd64-netinst.iso |
| **Location** | `iso/debian-12.15.0-amd64-netinst.iso` |

---

## Usage

### Build the Debian box

```bash
# Build Debian box only (~15 minutes)
./setup.sh build-boxes --debian-only

# Build all boxes (Server 2022 + Windows 10 + Debian)
./setup.sh build-boxes

# Skip Debian if already built
./setup.sh build-boxes --skip-debian

# Custom ISO path
./setup.sh build-boxes --debian-only --debian-iso /path/to/debian.iso
```

```powershell
# Windows PowerShell
.\setup.ps1 build-boxes -DebianOnly
```

### Verify

```bash
vagrant box list | grep secscope
# Expected:
#   secscope/debian-bookworm          (virtualbox, 0.1.0)
#   secscope/windows-10               (virtualbox, ...)
#   secscope/windows-server-2022      (virtualbox, ...)
```

### Deploy LIN01

```bash
./setup.sh deploy --vms lin01
```

---

## What Changed vs. Old Behavior

| Aspect | Before | After |
|--------|--------|-------|
| Box source | Vagrant Cloud (`debian/bookworm64`) | Local Packer build |
| Network dependency | Requires internet on first `vagrant up` | ISO in `iso/` (once downloaded) |
| SSH forwarded port | None | Port 22240 → guest 22 |
| Boot order | No issue (official box) | `--boot1 disk` fix needed (Packer artifact) |
| Consistency | Different workflow from Windows VMs | Same ISO → Packer → Box pattern as Windows |
| Guest Additions | Bundled in Vagrant Cloud box | Installed during Packer build |

---

## Files Not Changed

- `scripts/lin01_setup.sh` — Identical provisioning (SSSD, realmd, Kerberos, labuser, etc.)
- All Windows provisioning scripts
- The deploy pipeline (`step_*` functions)
- VM memory/CPU allocation for LIN01
- Network configuration (192.168.200.40, nic2 on SECSCOPE.CORP NAT network)

---

## Verification Checklist

After building and deploying:

- [ ] `./setup.sh build-boxes --debian-only` completes without errors
- [ ] `vagrant box list` shows `secscope/debian-bookworm`
- [ ] `vagrant up lin01` boots successfully
- [ ] `vagrant ssh lin01` works (SSH on vagrant/vagrant)
- [ ] SSH forwarded port works: `ssh vagrant@localhost -p 22240`
- [ ] `./setup.sh deploy --vms lin01` runs `lin01_setup.sh` and joins domain
- [ ] `ssh labuser@192.168.200.40` works (password `LabUser2024!`)
- [ ] Domain auth works: `id anakin` via SSSD (after deploy + domain join)

---

## Troubleshooting

### Packer SSH timeout during build
Increase `ssh_timeout` in `packer/debian-bookworm/debian-bookworm.pkr.hcl` (line: `ssh_timeout = "30m"` → `"1h"`).

### "Could not read from the boot medium" on `vagrant up lin01`
The `--boot1 disk` fix in the Vagrantfile template is baked into the box. If missing, the fix in the `Vagrantfile` `lin01` definition handles it. Rebuild the box or check both are present.

### ISO checksum mismatch
Debian publishes updated point releases. Use the latest ISO and update the SHA256 in the Packer variables file, or pass `-var "iso_checksum=none"` to skip verification.

### Guest Additions version mismatch
If VirtualBox is updated after building the box, `vagrant-vbguest` plugin will auto-update Guest Additions on next boot (same behavior as Windows boxes).

---

## Session Notes

This migration was implemented in a single session covering:
1. Analysis of existing Packer pipeline (Windows pattern)
2. Design of Debian preseed (unattended, minimal packages)
3. Creation of 4 new files (Packer template, preseed, Vagrantfile-template, VBoxGA script)
4. Modification of 5 existing files (Vagrantfile, setup.sh, setup.ps1, INSTALL.md, README.md)
5. Verification via dry-run and SHA256 validation

To resume in a future session:
- The ISO is already in `iso/debian-12.15.0-amd64-netinst.iso`
- Run `./setup.sh build-boxes --debian-only` to build
- Run `./setup.sh deploy --vms lin01` to deploy
- See `INSTALL.md` for full lab setup instructions
