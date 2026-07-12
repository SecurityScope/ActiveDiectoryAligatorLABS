# Debian ISO Build — Issues & Approaches

## Objective

Build LIN01 from a **Debian 12.15.0 net-install ISO** via Packer (locally-built box `secscope/debian-bookworm`), replacing the Vagrant Cloud box `debian/bookworm64`. This mirrors the Windows VM build pattern (ISO → Packer → `.box`).

**ISO:** `debian-12.15.0-amd64-netinst.iso` (677 MB)
**SHA256:** `cd4462c06aa8892e692c0c4b9c17802f38c8ab8690e85cbfb5ccaa5956e9af17`
**Location:** `iso/debian-12.15.0-amd64-netinst.iso`

---

## Current Situation

**The preseed IS being loaded** (build ran 29 minutes without the language-selection-blocker), but SSH never becomes available — Packer times out waiting for SSH. Root cause not yet identified.

The preseed is delivered via a **custom rebuilt ISO** (`iso/debian-12.15.0-amd64-netinst-preseed.iso`, 850 MB) with `preseed.cfg` baked into the CD root and ISOLINUX configs modified to include `auto=true preseed/file=/cdrom/preseed.cfg priority=critical` in both `txt.cfg` (text install) and `gtk.cfg` (GUI install). Boot command is simply `<enter>`.

```
Packer boot_command: ["<enter>"]   # ISOLINUX default entry has preseed params baked in
ISO: iso/debian-12.15.0-amd64-netinst-preseed.iso   # Custom rebuilt from original
Preseed: /cdrom/preseed.cfg      # Auto-detected by Debian installer on boot CD
```

---

## All Approaches Attempted

### Approach 1: Floppy + Explicit preseed/file=/dev/fd0

**Date:** 2026-07-12 (early attempts)
**Status:** FAILED

**Idea:** Place `preseed.cfg` on a Packer virtual floppy; boot the installer with `preseed/file=/dev/fd0`.

**Config:**
```hcl
floppy_files = ["packer/debian-bookworm/http/preseed.cfg"]
boot_command = ["<esc>", "/install.amd/vmlinuz ... preseed/file=/dev/fd0<enter>"]
```

**Failure reason:** Keyboard corruption at the ISOLINUX `boot:` prompt. Typed characters are mangled by VirtualBox's PS/2 keyboard emulation at this early stage. `preseed/file=/dev/fd0` becomes `preseedd/filee//devs/fdo` — the installer fails to load the preseed and falls through to interactive "Select language".

**Attempted mitigations:**
- `<wait>` pauses between keystrokes — still corrupted
- `<delay50>` pauses — still corrupted
- Typing at `<tab>` prompt instead of `<esc>` — corruption persists
- `<enter>` (boot ISOLINUX default) — boots GUI installer which uses different initrd; does NOT auto-scan floppy for preseed.cfg

---

### Approach 2: Packer HTTP Server (auto url=http://...)

**Date:** 2026-07-12 (early attempts)
**Status:** FAILED

**Idea:** Let Packer's built-in HTTP server serve `preseed.cfg`; pass `auto url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg` to the kernel.

**Config:**
```hcl
http_directory = "packer/debian-bookworm/http"
boot_command = ["<esc>", "/install.amd/vmlinuz ... auto url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ..."]
```

**Failure reason:** Same keyboard corruption — the long URL is garbled during typing at the `boot:` prompt. Also cannot verify Packer's HTTPIP is reachable from inside the VM before boot.

**Attempted mitigations:**
- `preseed/url` kernel param instead of `auto url=` — still requires typing, still corrupted
- `<tab>` approach to modify existing entry — corruption persists at the command-line editor too

---

### Approach 3: Rebuilt ISO with preseed.cfg at CD root

**Date:** 2026-07-12 (current)
**Status:** PARTIAL — preseed LOADS, but SSH never comes up

**Idea:** Rebuild the Debian ISO with `preseed.cfg` at the CD root (`/cdrom/preseed.cfg`). The Debian installer automatically detects and loads `/cdrom/preseed.cfg` on any mounted CD/DVD. Modify ISOLINUX configs (`txt.cfg`, `gtk.cfg`) to include `auto=true preseed/file=/cdrom/preseed.cfg priority=critical` so both text and GUI installers pick it up. No keystrokes needed — just `<enter>` on the default ISOLINUX entry.

**Steps performed:**
```bash
# 1. Extract original ISO
7z x -o/tmp/debian-iso-custom iso/debian-12.15.0-amd64-netinst.iso

# 2. Copy preseed.cfg to CD root
cp packer/debian-bookworm/http/preseed.cfg /tmp/debian-iso-custom/preseed.cfg

# 3. Modify isolinux/txt.cfg (text install)
#    Append: auto=true preseed/file=/cdrom/preseed.cfg priority=critical --- quiet

# 4. Modify isolinux/gtk.cfg (GUI install)
#    Append: auto=true preseed/file=/cdrom/preseed.cfg priority=critical --- quiet

# 5. Rebuild ISO with genisoimage
genisoimage -o iso/debian-12.15.0-amd64-netinst-preseed.iso \
    -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -J -R -l -V "Debian 12.15.0 amd64" \
    /tmp/debian-iso-custom/
```

**Tool used:** `genisoimage` (≈ `mkisofs`) — not `xorriso`. `xorriso` is the recommended tool for Debian ISO rebuilds but was not available (Arch Linux host, `pacman` needs sudo).

**Custom ISO details:**
- `iso/debian-12.15.0-amd64-netinst-preseed.iso`, 850 MB (vs. 677 MB original)
- SHA256: `2be1702b974186364199197b56468cdf12531965df7ea8accb2ea56dc0e75314`
- `-l` flag used for full 31-char filenames (critical for Debian ISO compatibility)
- BIOS-only boot (ISOLINUX), no UEFI support

**Current Packer config:**
```hcl
iso_path          = "iso/debian-12.15.0-amd64-netinst-preseed.iso"
boot_wait         = "5s"
boot_command      = ["<enter>"]
ssh_timeout       = "2h"
vboxmanage:       --boot1 disk --boot2 dvd --vram 128
```

**Current result:**
- Build ran for **29 minutes** before external termination (bash tool timeout)
- **No "Select language" error** — preseed WAS loaded successfully
- Packer was stuck at `Waiting for SSH to become available...`
- Possible causes:
  1. Package downloads from `deb.debian.org` are slow (netinst ISO downloads packages)
  2. The installer completed and rebooted but SSH didn't start
  3. After reboot, the system booted into the DVD again instead of disk (`--boot1 disk` should handle this, but the `genisoimage`-rebuilt ISO might hang on boot if something is wrong with it)
  4. `preseed/late_command` in `preseed.cfg` failed (e.g., `sed` on `/etc/apt/sources.list`)
  5. Network interface not coming up after install (NAT vs. bridged adapter)

---

## ISOLINUX Analysis

Extracted from the original Debian ISO (`/tmp/debian-iso-extract/isolinux/`):

### `isolinux.cfg`
```isolinux
default vesamenu.c32
prompt 0
timeout 0
```

### `menu.cfg`
```isolinux
menu hshift 13
menu width 49
menu margin 8
menu title Debian GNU/Linux installer menu (BIOS mode)
include stdmenu.cfg
include gtk.cfg      # GUI install loaded FIRST
include txt.cfg      # Text install loaded SECOND
menu begin advanced
  menu label ^Advanced options
  menu title Advanced options
  include stdmenu.cfg
  include adgtk.cfg
  include adtxt.cfg
menu end
menu default
include spkgtk.cfg   # Speech synthesis (GUI)
include spk.cfg      # Speech synthesis (text)
include dark.cfg     # Dark theme
```

### `gtk.cfg` — GUI Install (DEFAULT entry)
```isolinux
default installgui        # ← This makes GUI mode the default!
label installgui
  menu label ^Graphical install
  kernel /install.amd/vmlinuz
  append vga=788 initrd=/install.amd/gtk/initrd.gz --- quiet
```

### `txt.cfg` — Text Install (accessed with down-arrow)
```isolinux
label install
  menu label ^Install
  kernel /install.amd/vmlinuz
  append vga=788 initrd=/install.amd/initrd.gz --- quiet
```

### Key finding:
The default ISOLINUX entry is **Graphical install** (GUI mode, `installgui` label), which uses `/install.amd/gtk/initrd.gz`. The text-based installer uses `/install.amd/initrd.gz`. Both initrds should auto-detect `/cdrom/preseed.cfg`. With Approach 3, both `gtk.cfg` and `txt.cfg` were modified to include `auto=true preseed/file=/cdrom/preseed.cfg priority=critical`, so `<enter>` boots the correct entry with preseed params regardless.

---

## Preseed Configuration

```cfg
d-i debconf/priority select critical   # Minimal prompts
```

Key sections:

| Section | Setting | Note |
|---------|---------|------|
| Mirror | `deb.debian.org` | Global CDN mirror |
| apt-cdrom | **Disabled entirely** (`enable=false`, `no_mount=true`, `set-first/failed/next=false`) | Prevents CDROM apt errors |
| Partitioning | Single ext4 `/`, no LVM, no swap | `partman-basicfilesystems/no_swap boolean true` |
| Users | `vagrant/vagrant`, `root` password `vagrant` | Vagrant convention |
| Packages | `openssh-server`, `sudo` | Bare minimum |
| Tasksel | `standard` only | No desktop |
| Sudoers | `vagrant ALL=(ALL) NOPASSWD: ALL` | Via `late_command` |
| SSH | PasswordAuthentication yes, PermitRootLogin yes | Via `late_command` |
| Reboot | Automatic after install | `finish-install/reboot_in_progress note` |

`late_command`:
```sh
in-target sed -i '/cdrom/d' /etc/apt/sources.list
in-target apt-get update -qq
in-target sh -c 'echo "vagrant ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/vagrant && chmod 440 /etc/sudoers.d/vagrant'
in-target sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
in-target sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
```

---

## Attempted Fixes & Mitigations (in chronological order)

| # | Fix Attempted | Reason | Result |
|---|---------------|--------|--------|
| 1 | Floppy + `<esc>` typing params | Initial approach | Keyboard corruption at ISOLINUX `boot:` prompt |
| 2 | `<wait>` between keystrokes | Slow typing to avoid corruption | Still corrupted |
| 3 | `<tab>` instead of `<esc>` | Edit existing entry instead of typing full command | Corruption persists in tab editor too |
| 4 | `<down><enter>` | Boot text installer (floppy auto-scan) | Floppy auto-scan not working |
| 5 | `<enter>` only (no floppy, no preseed) | Test if installer boots at all | Boots GUI installer, stuck at language selection |
| 6 | HTTP preseed via Packer's built-in server | Eliminate floppy dependency | URL garbled by keyboard corruption |
| 7 | Custom ISO rebuild with genisoimage | Bake preseed into CD root | **Preseed LOADS** — first success |
| 8 | `--vram 128` | Fix GUI rendering issues | Addressed, no more "screen not found" errors |
| 9 | `--boot1 disk --boot2 dvd` | Ensure post-install boot from disk | In config, but SSH still never comes up |

---

## Related Files

| File | Purpose | Status |
|------|---------|--------|
| `packer/debian-bookworm/debian-bookworm.pkr.hcl` | Packer template | Active (uses custom ISO, `<enter>` boot) |
| `packer/debian-bookworm/http/preseed.cfg` | Unattended install preseed | Stable |
| `packer/debian-bookworm/vagrantfile-template.rb` | Box metadata | Stable |
| `packer/scripts/install_vboxga_linux.sh` | VBox Guest Additions script | Not yet reached (runs post-SSH) |
| `iso/debian-12.15.0-amd64-netinst.iso` | Original ISO (677 MB) | Only for reference |
| `iso/debian-12.15.0-amd64-netinst-preseed.iso` | Custom rebuilt ISO (850 MB) | **Used for build** |
| `Vagrantfile` | LIN01 box reference | Uses `secscope/debian-bookworm` |
| `setup.sh` | Build orchestration | Uses custom ISO path |
| `setup.ps1` | Windows build orchestration | Uses custom ISO path |
| `INSTALL.md` | Installation docs | Updated |
| `README.md` | Project readme | Updated |
| `DEBAIN_ISO_DEPLOYMENT.md` | Deployment report | Created (now superseded by this doc for troubleshooting) |

---

## Next Steps / Open Items

### Immediate (to get the build working)

1. **Let the build run longer** — the 29-minute run was terminated externally (bash timeout), not by Packer's `ssh_timeout`. The build might complete given enough time. Increase timeout and/or run Packer detached.

2. **Check if SSH works after install** — manually boot the VM after the build (if the VDI is preserved) and check `systemctl status ssh`. The `preseed/late_command` enables SSH — verify it ran.

3. **Try `xorriso` for ISO rebuild** instead of `genisoimage`. `xorriso` is the official Debian ISO rebuild tool and produces smaller, more reliable ISOs (including working UEFI boot). Requires sudo on Arch to install or a chroot/Debian environment.

### Investigation

4. **Log the console output** — Packer's built-in console logging would show the installer output, installer errors, GRUB menu, and boot messages. Check if Packer logs are preserved.

5. **Test with a pre-built netinst preseed ISO** — Debian provides `debian-*-preseed.iso` variants that have preseed auto-detection built in. Could compare against the project's custom setup.

6. **Verify network connectivity** — the netinst ISO needs internet to download packages. If the NAT network in VirtualBox isn't working, the installer will hang at package download. This could explain the long runtime without SSH.

### Long-term

7. Once the box builds, verify `./setup.sh deploy --vms lin01` runs successfully (SSSD, realmd, domain join).

8. Once the custom ISO rebuild approach is stable, document the `xorriso` rebuild steps so other users can reproduce the build.
