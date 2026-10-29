#!/usr/bin/env python3
"""
Active Directory Alligator Labs - Unified Setup Orchestrator (Python)

Per-machine build tool with hard dependency enforcement, a one-time build
guard, and a live status table. Replaces the previous monolithic setup.sh /
setup.ps1 "deploy everything" flow.

Design:
  * Build ONE, several, or 'all' machines - always in dependency order.
  * Dependencies are HARD-blocking: building dc03 requires dc01 AND dc02 to be
    already running + provisioned, or the build aborts with an explicit message.
  * One-time build guard: an already-built VM is refused unless --force (or the
    'rebuild' command) is used, to avoid resource damage / duplicate work.
  * Build state is discovered by LIVE PROBING (VBoxManage + WinRM/SSH). No state
    file is kept, so the table can never drift from reality.
  * Hardening and network sealing are SEPARATE explicit commands (they sever
    Vagrant management), run only after the machines you want are built.

All guest provisioning logic still lives in the unchanged scripts/*.ps1 files
and the Vagrantfile provisioner names; this orchestrator only drives the same
`vagrant` / `VBoxManage` commands in the right order.

Requires: Python 3.8+, vagrant, VBoxManage. Standard library only.
"""

import os
import re
import sys
import time
import signal
import select
import hashlib
import argparse
import shutil
import subprocess
import concurrent.futures
import threading
from pathlib import Path

# Serializes every operation that issues a vagrant/WinRM command against DC01.
# Under `build all --parallel`, dc02 and the members run concurrently; without
# this lock, two member builds could run `vagrant provision dc01` (objects) at
# once, or a DC03 replication probe could collide with a member's DC01 provision
# - races on one shared machine. All DC01-touching helpers take this lock.
DC01_LOCK = threading.Lock()

# ─────────────────────────────────────────────────────────────────────────────
# Paths / constants
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).resolve().parent
LAB_CONF = SCRIPT_DIR / "lab.conf"

# Ordered inventory (also defines display order).
ALL_VMS = ["dc01", "dc02", "dc03", "srv01", "ws01", "ws02", "lin01"]
DCS = ["dc01", "dc02", "dc03"]
MEMBERS = ["srv01", "ws01", "ws02", "lin01"]
WINDOWS_VMS = ["dc01", "dc02", "dc03", "srv01", "ws01", "ws02"]

# Hard-blocking provisioning dependency graph. A VM may only be built once every
# VM listed here is running AND provisioned.
DEPENDENCIES = {
    "dc01": [],
    "dc02": ["dc01"],
    "dc03": ["dc01", "dc02"],   # child domain: needs forest root + replication peer
    "srv01": ["dc01"],
    "ws01": ["dc01"],
    "ws02": ["dc01"],
    "lin01": ["dc01"],
}

# VirtualBox VM names as set by the Vagrantfile (v.customize --name).
VBOX_NAME = {vm: f"{vm.upper()}.SECSCOPE.CORP" for vm in ALL_VMS}

DEFAULT_MAX_PARALLEL = 2


def _find_vboxmanage():
    """Resolve the VBoxManage executable. On Windows VirtualBox does NOT add its
    install directory to PATH, so fall back to the standard install locations."""
    exe = shutil.which("VBoxManage")
    if exe:
        return exe
    if os.name == "nt":
        for p in (
            r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",
            r"C:\Program Files (x86)\Oracle\VirtualBox\VBoxManage.exe",
        ):
            if Path(p).exists():
                return p
    return None


VBOXMANAGE = _find_vboxmanage()


def _sha256(path):
    """Compute a file's SHA-256 digest in a memory-safe, cross-platform way."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(16 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


# ─────────────────────────────────────────────────────────────────────────────
# Colours / logging
# ─────────────────────────────────────────────────────────────────────────────

class C:
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    CYAN = "\033[0;36m"
    BOLD = "\033[1m"
    NC = "\033[0m"

    @classmethod
    def disable(cls):
        cls.RED = cls.GREEN = cls.YELLOW = cls.CYAN = cls.BOLD = cls.NC = ""


VERBOSE = False
QUIET = False
DEBUG = False
# Opt-in: add the domain GPO that disables Defender AV + Windows Update
# forest-wide (scripts/dc01_av_update_gpo.ps1). Off by default.
DISABLE_AV_UPDATE = False


def log(msg=""):
    if not QUIET:
        print(msg, flush=True)


def log_ok(msg):
    print(f"    {C.GREEN}[OK]{C.NC} {msg}", flush=True)


def log_skip(msg):
    print(f"    {C.YELLOW}[SKIP]{C.NC} {msg}", flush=True)


def log_warn(msg):
    print(f"    {C.YELLOW}[WARN]{C.NC} {msg}", flush=True)


def log_err(msg):
    print(f"    {C.RED}[ERROR]{C.NC} {msg}", file=sys.stderr, flush=True)


def log_info(msg):
    print(f"    {C.CYAN}[*]{C.NC} {msg}", flush=True)


def log_step(msg):
    print(f"\n{C.CYAN}{msg}{C.NC}", flush=True)


def log_verbose(msg):
    if VERBOSE and not QUIET:
        print(msg, flush=True)


def banner(title):
    line = "═" * 44
    print(f"╔{line}╗")
    print(f"║{title.center(44)}║")
    print(f"╚{line}╝")


class LabError(Exception):
    """Fatal, user-facing error (dependency / guard / build failure)."""


def confirm(action, vms, force):
    """Guard a destructive operation. Returns True to proceed.

    --force bypasses the prompt. Without it we ask interactively; under --quiet
    (non-interactive) we refuse rather than hang waiting on input.
    """
    if force:
        return True
    target = ", ".join(vms)
    if QUIET:
        log_err(f"Refusing to {action} {target} without --force (quiet mode is "
                "non-interactive).")
        return False
    prompt = f"  {C.YELLOW}This will {action}: {target}. Continue? [y/N]{C.NC} "
    try:
        answer = input(prompt).strip().lower()
    except EOFError:
        answer = ""
    if answer in ("y", "yes"):
        return True
    log_info("Aborted.")
    return False



# ─────────────────────────────────────────────────────────────────────────────
# lab.conf (single source of truth, shared with the Vagrantfile)
# ─────────────────────────────────────────────────────────────────────────────

def load_lab_conf():
    if not LAB_CONF.exists():
        raise LabError(f"lab.conf not found at {LAB_CONF}")
    conf = {}
    for raw in LAB_CONF.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        conf[key.strip()] = val.strip()
    return conf


CONF = {}
ADMIN_PASS = "vagrant"
DOMAIN = "secscope.corp"
CHILD_DOMAIN = "it.secscope.corp"
SERVER_BOX = "secscope/windows-server-2022"
WORKSTATION_BOX = "secscope/windows-10"
DEBIAN_BOX = "secscope/debian-bookworm"
IPS = {}

# Which Packer box each VM boots from (for the build-time box preflight).
def _vm_box(vm):
    if vm in ("ws01", "ws02"):
        return WORKSTATION_BOX
    if vm == "lin01":
        return DEBIAN_BOX
    return SERVER_BOX


def _domain_dn(domain):
    """Convert 'secscope.corp' to 'DC=secscope,DC=corp'."""
    return ",".join(f"DC={part}" for part in domain.split("."))


def init_conf():
    global CONF, ADMIN_PASS, DOMAIN, CHILD_DOMAIN, SERVER_BOX, WORKSTATION_BOX, DEBIAN_BOX, IPS
    CONF = load_lab_conf()
    ADMIN_PASS = os.environ.get("ADMIN_PASS") or CONF.get("ADMIN_PASS", "vagrant")
    DOMAIN = CONF.get("DOMAIN", "secscope.corp")
    CHILD_DOMAIN = CONF.get("CHILD_DOMAIN", "it.secscope.corp")
    SERVER_BOX = CONF.get("SERVER_BOX", "secscope/windows-server-2022")
    WORKSTATION_BOX = CONF.get("WORKSTATION_BOX", "secscope/windows-10")
    DEBIAN_BOX = CONF.get("DEBIAN_BOX", "secscope/debian-bookworm")
    IPS = {
        "dc01": CONF.get("DC01_IP", "192.168.200.10"),
        "dc02": CONF.get("DC02_IP", "192.168.200.11"),
        "dc03": CONF.get("DC03_IP", "192.168.200.12"),
        "srv01": CONF.get("SRV01_IP", "192.168.200.20"),
        "ws01": CONF.get("WS01_IP", "192.168.200.30"),
        "ws02": CONF.get("WS02_IP", "192.168.200.31"),
        "lin01": CONF.get("LIN01_IP", "192.168.200.40"),
    }


# ─────────────────────────────────────────────────────────────────────────────
# Command execution
# ─────────────────────────────────────────────────────────────────────────────

WINRM_NOISE = re.compile(
    r"WinRMAuthorizationError|WinRMHTTPTransportError|raise_if_auth_error|"
    r"response_handler\.rb|transport\.rb|power_shell\.rb|elevated\.rb|"
    r"communicator\.rb|provisioner\.rb|from /home|AuthenticationFailed|wsman|"
    r"^\s+from "
)


def _kill_process_tree(proc):
    """Kill `proc` and its children. On Windows `vagrant`/`packer` launch a
    ruby child that inherits the stdout pipe; killing only the launcher leaves
    the child holding the pipe and the caller blocked past its timeout."""
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/F", "/T", "/PID", str(proc.pid)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    else:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass


def run(cmd, env=None, capture=False, check=False, timeout=None, filter_winrm=False):
    """Run a command. Returns (rc, stdout_text). Streams live unless capture."""
    full_env = os.environ.copy()
    if env:
        full_env.update(env)

    if capture:
        try:
            proc = subprocess.Popen(
                cmd, env=full_env, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True,
                start_new_session=(os.name != "nt"),
            )
        except FileNotFoundError:
            raise LabError(f"Executable not found: {cmd[0]}")
        try:
            stdout, _ = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_process_tree(proc)
            try:
                stdout, _ = proc.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    proc.kill()
                except Exception:
                    pass
                stdout = ""
            return 124, stdout or ""
        if check and proc.returncode != 0:
            raise LabError(f"Command failed ({proc.returncode}): {' '.join(cmd)}")
        return proc.returncode, stdout or ""

    # Streaming mode (optionally filtering WinRM noise line-by-line).
    show_all = VERBOSE or DEBUG
    try:
        proc = subprocess.Popen(
            cmd, env=full_env, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
            start_new_session=(os.name != "nt"),
        )
    except FileNotFoundError:
        raise LabError(f"Executable not found: {cmd[0]}")
    assert proc.stdout is not None

    def _emit(line):
        line = line.rstrip("\n")
        if filter_winrm and not show_all and WINRM_NOISE.search(line):
            return
        if not QUIET:
            print(line, flush=True)

    # Streaming mode used to apply `timeout` only to proc.wait() AFTER the read
    # loop, so a hung child (vagrant halt via WinRM, for example) could block
    # indefinitely. Enforce the deadline with a watchdog that kills the tree.
    timed_out = False
    timer = None
    if timeout is not None:
        def _on_timeout():
            nonlocal timed_out
            if proc.poll() is None:
                timed_out = True
                _kill_process_tree(proc)

        timer = threading.Timer(timeout, _on_timeout)
        timer.daemon = True
        timer.start()

    try:
        if os.name == "posix":
            # Drain with process-exit awareness. Tools like packer spawn
            # VirtualBox, which starts the long-lived VBoxSVC daemon; VBoxSVC
            # can INHERIT this stdout pipe, so a plain `for line in proc.stdout`
            # never sees EOF after packer exits and the build hangs forever
            # between "box built" and the next step. Here, once the process has
            # exited and the pipe is idle, we stop even if a grandchild still
            # holds the write end open.
            fd = proc.stdout.fileno()
            while True:
                rlist, _, _ = select.select([fd], [], [], 0.5)
                if rlist:
                    line = proc.stdout.readline()
                    if line:
                        _emit(line)
                        continue
                    break  # empty read on a readable fd == genuine EOF
                if proc.poll() is not None:
                    # Exited with nothing pending this tick; short grace drain.
                    rlist, _, _ = select.select([fd], [], [], 0.2)
                    if not rlist:
                        break
        else:
            for line in proc.stdout:
                _emit(line)
    finally:
        if timer is not None:
            timer.cancel()
        try:
            proc.stdout.close()
        except Exception:
            pass
    try:
        proc.wait(timeout=10 if timed_out else None)
    except subprocess.TimeoutExpired:
        _kill_process_tree(proc)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
    if timed_out:
        if check:
            raise LabError(f"Command timed out after {timeout}s: {' '.join(cmd)}")
        return 124, ""
    if check and proc.returncode != 0:
        raise LabError(f"Command failed ({proc.returncode}): {' '.join(cmd)}")
    return proc.returncode, ""


def vagrant(args, password=None, filter_winrm=True, capture=False, timeout=None,
            check=False, extra_env=None):
    env = {}
    if password is not None:
        env["DC_WINRM_PASSWORD"] = password
    if extra_env:
        env.update(extra_env)
    return run(["vagrant"] + args, env=env, capture=capture, check=check,
               timeout=timeout, filter_winrm=filter_winrm)


def vagrant_winrm(vm, ps, password=None, timeout=120):
    """Run a PowerShell one-liner via WinRM; return (rc, output)."""
    return vagrant(["winrm", vm, "-c", ps], password=password, capture=True,
                   timeout=timeout, filter_winrm=True)


def vbox(args, capture=True):
    if VBOXMANAGE is None:
        raise LabError("VBoxManage not found. Install VirtualBox first.")
    rc, out = run([VBOXMANAGE] + args, capture=capture)
    return rc, out


# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────────────────

def preflight():
    missing = []
    if shutil.which("vagrant") is None:
        missing.append("vagrant")
    if VBOXMANAGE is None:
        missing.append("VBoxManage")
    if missing:
        raise LabError(
            f"Required tool(s) not found in PATH: {', '.join(missing)}. "
            "Install Vagrant and VirtualBox first."
        )


def preflight_boxes(vms):
    """Fail early with a clear message if a required Packer box isn't registered
    with Vagrant yet. Without this, `build dc01` aborts deep inside `vagrant up`
    with a cryptic 'box not found'."""
    needed = {b for b in (_vm_box(vm) for vm in vms) if b}
    if not needed:
        return
    rc, out = run(["vagrant", "box", "list"], capture=True)
    installed = out if rc == 0 else ""
    absent = sorted(b for b in needed if b not in installed)
    if absent:
        hint = "python3 setup.py build-boxes"
        if DEBIAN_BOX in absent:
            # Debian is opt-in in build-boxes, so point at the right flag.
            hint = ("python3 setup.py build-boxes --with-debian"
                    if absent == [DEBIAN_BOX]
                    else "python3 setup.py build-boxes  (and add --with-debian for the Debian box)")
        raise LabError(
            "Required Vagrant box(es) not installed: "
            f"{', '.join(absent)}.\n"
            f"       Build the base boxes first:  {hint}"
        )


# ─────────────────────────────────────────────────────────────────────────────
# Live-probing: existence / power / provisioned / role
# ─────────────────────────────────────────────────────────────────────────────

def vbox_vm_names():
    rc, out = vbox(["list", "vms"])
    return out


def vbox_running_names():
    rc, out = vbox(["list", "runningvms"])
    return out


def vm_exists(vm):
    return f'"{VBOX_NAME[vm]}"' in vbox_vm_names()


def vm_running(vm):
    return f'"{VBOX_NAME[vm]}"' in vbox_running_names()


_cached_machine_folder = None


def _vm_dir(name):
    """VirtualBox per-VM directory, queried from VBoxManage systemproperties."""
    global _cached_machine_folder
    if _cached_machine_folder is None:
        try:
            rc, out = vbox(["list", "systemproperties"], capture=True)
            for line in (out or "").splitlines():
                if "Default machine folder" in line:
                    _cached_machine_folder = line.split(":", 1)[1].strip()
                    break
        except LabError:
            pass
        if _cached_machine_folder is None:
            _cached_machine_folder = str(Path.home() / "VirtualBox VMs")
    return Path(_cached_machine_folder) / name


def _vbox_inventory():
    """Return ({name: uuid}, {running names}) parsed from VBoxManage."""
    reg = {}
    for line in vbox_vm_names().splitlines():
        m = re.match(r'^"([^"]+)"\s+\{([0-9A-Fa-f-]+)\}', line.strip())
        if m:
            reg[m.group(1)] = m.group(2)
    running = set()
    for line in vbox_running_names().splitlines():
        m = re.match(r'^"([^"]+)"', line.strip())
        if m:
            running.add(m.group(1))
    return reg, running


def _forget_vagrant_machine(vm, uuid):
    """Drop Vagrant's recorded VM id for `vm` if it points at `uuid` (a stale,
    half-created VM we just removed), so the next `up` starts from scratch."""
    mdir = SCRIPT_DIR / ".vagrant" / "machines" / vm
    idfile = mdir / "virtualbox" / "id"
    try:
        if idfile.exists() and idfile.read_text().strip().lower() == uuid.lower():
            shutil.rmtree(mdir, ignore_errors=True)
    except OSError:
        pass


def purge_stale_vbox(vm):
    """Remove VirtualBox leftovers that make the next `vagrant up` fail.

    Two known failure modes (both hit on Windows after destroy/rebuild):
      * `vagrant destroy` sometimes unregisters a VM but leaves its
        '<...>\\VirtualBox VMs\\<NAME>' directory on disk (e.g. a saved-state
        .sav). The Vagrantfile renames the new VM to <NAME>, so the rename
        collides with VERR_ALREADY_EXISTS.
      * A failed `up` can leave a half-created, temp-named VM
        ('<project>_<vm>_<digits>_<digits>') registered in VirtualBox.

    Only touches VMs/dirs that are NOT the live, registered target, so a
    normal power-on of an existing VM is unaffected.
    """
    real = VBOX_NAME[vm]
    reg, running = _vbox_inventory()

    # 1) Stale directory for the real VM name (the VM itself is gone).
    if real not in reg and real not in running:
        d = _vm_dir(real)
        if d.exists():
            log_info(f"Removing stale VirtualBox directory: {d}")
            shutil.rmtree(d, ignore_errors=True)

    # 2) Orphaned temp-named VMs left by a previous failed `up`.
    pat = re.compile(
        rf"^{re.escape(SCRIPT_DIR.name)}_{re.escape(vm)}(?:_default)?_\d+_\d+$",
        re.IGNORECASE)
    for name, uuid in list(reg.items()):
        if not pat.match(name) or name in running:
            continue
        log_info(f"Removing orphaned failed-build VM: {name}")
        vbox(["unregistervm", name, "--delete"])
        d = _vm_dir(name)
        if d.exists():
            shutil.rmtree(d, ignore_errors=True)
        _forget_vagrant_machine(vm, uuid)


def _forget_vagrant_state(vm):
    """Remove Vagrant's per-machine state dir (stale id / half-destroyed VM)."""
    mdir = SCRIPT_DIR / ".vagrant" / "machines" / vm
    if mdir.exists():
        log_info(f"Removing stale Vagrant state: {mdir}")
        shutil.rmtree(mdir, ignore_errors=True)


def _clean_vbox_artifacts(vm):
    """Purge stale VirtualBox leftovers + Vagrant state for one VM."""
    purge_stale_vbox(vm)
    _forget_vagrant_state(vm)


def vagrant_up(vm, **kwargs):
    """Purge stale VirtualBox artifacts, then `vagrant up <vm>`."""
    purge_stale_vbox(vm)
    kwargs.setdefault("filter_winrm", True)
    kwargs.setdefault("check", True)
    return vagrant(["up", vm], **kwargs)


def _ad_cleanup_script(vm, is_dc, dry_run):
    """PowerShell run on DC01 to remove stale AD/DNS metadata for `vm`.

    Targets:
      * DC server object in CN=Sites (and NTDS Settings/connections via -Recursive)
      * domain computer object (any OU)
      * A/other records named <vm> in every forward DNS zone
      * SRV records whose target is <vm>.<domain>
      * PTR records pointing at <vm>.<domain>
    """
    script = r'''
$ErrorActionPreference = 'Continue'
$vmName   = '__VM_NAME__'
$domainDN = '__DOMAIN_DN__'
$isDc     = __IS_DC__
$dry      = __DRY__
$site = 'Default-First-Site-Name'
try { $site = (Get-ADDomainController -Identity 'DC01').Site } catch {}

function Remove-LabObject([string]$dn, [string]$label) {
    try {
        $null = Get-ADObject -Identity $dn -ErrorAction Stop
        if ($dry) { Write-Output "WOULD REMOVE $label $dn"; return }
        try { Set-ADObject -Identity $dn -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue } catch {}
        Remove-ADObject -Identity $dn -Recursive -Confirm:$false -ErrorAction Stop
        Write-Output "REMOVED $label $dn"
    } catch {
        Write-Output "ABSENT $label $dn"
    }
}

if ($isDc) {
    Remove-LabObject "CN=$vmName,CN=Servers,CN=$site,CN=Sites,CN=Configuration,$domainDN" 'server'
}

try {
    $comp = Get-ADComputer -Identity $vmName -ErrorAction Stop
    Remove-LabObject $comp.DistinguishedName 'computer'
} catch {
    Write-Output "ABSENT computer CN=$vmName"
}

Import-Module DnsServer -ErrorAction SilentlyContinue
foreach ($z in (Get-DnsServerZone -ErrorAction SilentlyContinue)) {
    $zn = $z.ZoneName
    if ($z.IsReverseLookupZone) {
        Get-DnsServerResourceRecord -ZoneName $zn -RRType Ptr -ErrorAction SilentlyContinue | Where-Object {
            $_.RecordData.PtrDomainName.ToString() -like "$vmName.*"
        } | ForEach-Object {
            if ($dry) { Write-Output "WOULD REMOVE PTR $zn $($_.HostName)" }
            else {
                Remove-DnsServerResourceRecord -ZoneName $zn -InputObject $_ -Force -ErrorAction SilentlyContinue
                Write-Output "REMOVED PTR $zn $($_.HostName)"
            }
        }
    } else {
        Get-DnsServerResourceRecord -ZoneName $zn -Name $vmName -ErrorAction SilentlyContinue | ForEach-Object {
            if ($dry) { Write-Output "WOULD REMOVE record $zn $($_.HostName)" }
            else {
                Remove-DnsServerResourceRecord -ZoneName $zn -InputObject $_ -Force -ErrorAction SilentlyContinue
                Write-Output "REMOVED record $zn $($_.HostName)"
            }
        }
        Get-DnsServerResourceRecord -ZoneName $zn -RRType Srv -ErrorAction SilentlyContinue | Where-Object {
            $_.RecordData.DomainName.ToString() -like "$vmName.*"
        } | ForEach-Object {
            if ($dry) { Write-Output "WOULD REMOVE SRV $zn $($_.HostName)" }
            else {
                Remove-DnsServerResourceRecord -ZoneName $zn -InputObject $_ -Force -ErrorAction SilentlyContinue
                Write-Output "REMOVED SRV $zn $($_.HostName)"
            }
        }
    }
}
Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
'''
    return (script.replace('__VM_NAME__', vm.upper())
                  .replace('__DOMAIN_DN__', _domain_dn(DOMAIN))
                  .replace('__IS_DC__', '$true' if is_dc else '$false')
                  .replace('__DRY__', '$true' if dry_run else '$false'))


def _clean_ad_metadata(vm, dry_run=False):
    """Remove stale AD computer/server objects + DNS records for `vm` on DC01.

    Only valid once the VM is destroyed/absent. dc01 is the forest root and is
    never cleaned here (that would destroy the forest). Returns True if the
    cleanup ran (or was intentionally skipped for dc01), False if it could not
    run (dc01 down/not a DC, or the target is still running).
    """
    if vm == "dc01":
        log_skip("dc01 is the forest root - AD metadata cleanup skipped")
        return True
    if not vm_running("dc01"):
        log_warn("dc01 is not running - cannot clean AD/DNS metadata")
        return False
    if vm_running(vm):
        log_warn(f"{vm} is still running - refusing to remove live AD metadata "
                 "(destroy it first)")
        return False

    # Pick the credential that is valid RIGHT NOW on dc01.
    pw = ADMIN_PASS
    rc, out = vagrant_winrm("dc01", "(Get-ADDomain).DNSRoot", password=pw, timeout=60)
    if DOMAIN not in out:
        pw = "vagrant"
        rc, out = vagrant_winrm("dc01", "(Get-ADDomain).DNSRoot", password=pw, timeout=60)
        if DOMAIN not in out:
            log_warn("dc01 is not a reachable domain controller - skipping AD cleanup")
            return False

    log_info(f"Cleaning AD/DNS metadata for {vm} on dc01...")
    ps = _ad_cleanup_script(vm, vm in DCS, dry_run)
    with DC01_LOCK:
        rc, out = vagrant_winrm("dc01", ps, password=pw, timeout=240)
    for line in (out or "").splitlines():
        line = line.strip()
        if line:
            log_info(f"  [ad] {line}")

    if vm == "dc03" and not dry_run:
        # The parent computer object is gone now, so the helper proceeds to
        # remove the child-domain crossRef + NS delegation/forwarder.
        clean_stale_child_domain(password=pw)
    return True


def vm_nic1(vm):
    """Return nic1 type ('nat'/'none'/...) or None if the VM is missing."""
    rc, out = vbox(["showvminfo", VBOX_NAME[vm], "--machinereadable"])
    if rc != 0:
        return None
    m = re.search(r'^nic1="?([^"\n]+)"?', out, re.MULTILINE)
    return m.group(1) if m else None


def vm_sealed(vm):
    return vm_nic1(vm) == "none"


def _winrm_role(vm, password=None, timeout=60):
    """DomainRole int via WinRM. None if unreachable.

    If `password` is supplied, try ONLY that credential. Callers that know which
    account is valid (dc02 after its join resets Administrator to ADMIN_PASS;
    dc03 after its postboot does the same) must pass it: probing with the stale
    password triggers Vagrant's full WinRM auth-retry loop (~60s each and can
    lock the account), which is what made dc02 look stuck at
    "Waiting for dc02 promotion".

    `timeout` bounds each credential probe. A short timeout (20s) is used for
    the initial "is this already a DC?" check after an interrupted build, where
    one of the two passwords is known to be stale.
    """
    passwords = (password,) if password else ("vagrant", ADMIN_PASS)
    for pw in passwords:
        rc, out = vagrant_winrm(
            vm, "(Get-CimInstance Win32_ComputerSystem).DomainRole",
            password=pw, timeout=timeout)
        m = re.search(r"\b([0-5])\b", out)
        if m:
            return int(m.group(1))
    return None


def _member_name_ok(vm):
    """True if the guest's computer name matches the intended name (e.g. SRV01).
    Guards against a join that succeeded but left the box as VAGRANT-BUILD because
    the rename failed - which domain role alone cannot detect."""
    want = vm.upper()
    for pw in ("vagrant", ADMIN_PASS):
        rc, out = vagrant_winrm(
            vm, "(Get-CimInstance Win32_ComputerSystem).Name", password=pw, timeout=60)
        if out and out.strip():
            return want in out.upper()
    return False


def is_provisioned(vm):
    """Live check: has this VM completed its build pipeline?"""
    if not vm_running(vm):
        return False
    if vm == "lin01":
        rc, out = vagrant(["ssh", "lin01", "-c", "realm list 2>/dev/null || true"],
                          capture=True, timeout=60, filter_winrm=True)
        return DOMAIN in out
    if vm == "dc01":
        # "Provisioned" means the full DC01 pipeline finished, not merely that
        # promotion happened. The 'dns' provisioner resets the Administrator
        # password to ADMIN_PASS, so a successful ADMIN_PASS Get-ADDomain proves
        # DNS+ ran. (A promoted-but-DNS-pending DC01 only answers to 'vagrant'
        # and must NOT be treated as fully built, or the one-time guard would
        # skip the remaining DNS/objects steps.)
        rc, out = vagrant_winrm("dc01", "(Get-ADDomain).DNSRoot", password=ADMIN_PASS)
        if DOMAIN not in out:
            return False
        # DNS resetting the password is not enough: the objects-base pipeline
        # creates 'anakin' and the lab OUs. Without this check a build that
        # stopped after DNS would be reported as "already built" and skipped.
        # Use native `net user` rather than Get-ADUser: the AD-module cmdlet
        # intermittently hung the WinRM shell (~60s timeout -> false negative),
        # which made `status` and the dc02 dependency check treat this fully
        # built DC01 as "not provisioned".
        rc, out = vagrant_winrm("dc01", "net user anakin /domain 2>&1",
                                password=ADMIN_PASS, timeout=60)
        low = out.lower()
        return "anakin" in low and "command completed successfully" in low
    if vm in ("dc02", "dc03"):
        # dc02_join.ps1 resets Administrator to ADMIN_PASS before returning;
        # dc03 keeps 'vagrant' until dc03_postboot resets it. Try the expected
        # credential first and only then the other, so a promoted dc02 is not
        # probed with the stale 'vagrant' password (slow auth-retry storm).
        preferred = ADMIN_PASS if vm == "dc02" else "vagrant"
        role = _winrm_role(vm, password=preferred)
        if role is None:
            other = "vagrant" if preferred == ADMIN_PASS else ADMIN_PASS
            role = _winrm_role(vm, password=other)
        return role is not None and role >= 4
    # member servers/workstations: must be domain-joined (role 1 workstation / 3
    # member server) AND carry the correct name - a box joined as VAGRANT-BUILD
    # (rename failed) is NOT a finished build and must not satisfy the guard.
    role = _winrm_role(vm)
    return role in (1, 3) and _member_name_ok(vm)


def probe_status(vm):
    """Return a dict describing the live state of one VM (best-effort)."""
    st = {"vm": vm, "ip": IPS.get(vm, "?"), "vbox": "not-created",
          "provisioned": "NO", "notes": ""}
    if not vm_exists(vm):
        deps = ", ".join(DEPENDENCIES[vm]) or "none"
        st["notes"] = f"not built (deps: {deps})"
        return st
    if vm_running(vm):
        st["vbox"] = "running"
    else:
        st["vbox"] = "poweroff"
    sealed = vm_sealed(vm)
    if sealed and vm_running(vm):
        # Management NIC removed -> cannot WinRM/SSH probe. It exists & runs.
        st["provisioned"] = "YES?"
        st["notes"] = "built (sealed - mgmt severed)"
        return st
    if vm_running(vm) and is_provisioned(vm):
        st["provisioned"] = "YES"
        st["notes"] = _role_note(vm)
    else:
        st["notes"] = "created, not fully provisioned"
    return st


def _role_note(vm):
    return {
        "dc01": "Forest root DC",
        "dc02": "Replica DC",
        "dc03": "Child-domain DC (it.secscope.corp)",
        "srv01": "Member server (SQL/IIS/ADCS)",
        "ws01": "Workstation",
        "ws02": "Workstation",
        "lin01": "Linux domain member",
    }.get(vm, "")


# ─────────────────────────────────────────────────────────────────────────────
# Shared helpers (ported from setup.sh)
# ─────────────────────────────────────────────────────────────────────────────

def ensure_adws(vm, password=None):
    # Caller must pass the password that is valid RIGHT NOW. On DC01 before the
    # 'dns' provisioner runs, the Administrator password is still 'vagrant' (dns
    # resets it to ADMIN_PASS); using the wrong one here triggers a ~30-min
    # silent WinRM auth-retry storm. Default to ADMIN_PASS for the dc02/dc03
    # callers, which run after their password is already ADMIN_PASS.
    if password is None:
        password = ADMIN_PASS
    for i in range(1, 7):
        time.sleep(3)
        rc, out = vagrant_winrm(vm, "Get-Service ADWS | Select -Expand Status",
                                password=password)
        status = out.strip()
        if "Running" in status:
            log_ok(f"ADWS running on {vm}")
            return True
        if "Stopped" in status:
            log_info(f"Enabling ADWS on {vm}...")
            vagrant_winrm(vm, "Set-Service ADWS -StartupType Automatic; Start-Service ADWS",
                          password=password)
            time.sleep(3)
        log_verbose(f"    ADWS on {vm}: attempt {i}/6 ({status})")
    log_warn(f"ADWS not running on {vm} after retries")
    return False


def clean_nat_leak():
    """Strip stale 10.0.2.x A/AAAA records from DC01's zone (idempotent)."""
    ps = r'''
$zone = "secscope.corp"
Get-DnsServerResourceRecord -ZoneName $zone -RRType A -ErrorAction SilentlyContinue | ForEach-Object {
    $ip = $_.RecordData.IPv4Address.IPAddressToString
    if ($ip -like "10.0.2.*") { dnscmd localhost /RecordDelete $zone $($_.HostName) A $ip /f 2>&1 | Out-Null }
}
Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
'''
    with DC01_LOCK:
        vagrant_winrm("dc01", ps, password=ADMIN_PASS, timeout=180)


def _clean_stale_dc_parent(vm):
    """Remove a previous incarnation's parent-domain DC server/computer/DNS
    objects before `vm` is promoted again.

    Safe only while `vm` is NOT a DC (after sysprep it is a standalone box).
    This closes the gap left by dc02_join/dc03_join: they remove the computer
    object but not the parent server object under CN=Sites, which can block
    Install-ADDSDomainController / Install-ADDSDomain on a rebuild.
    """
    if vm not in ("dc02", "dc03"):
        return
    role = _winrm_role(vm, password="vagrant")
    if role is None:
        log_warn(f"{vm}: WinRM unreachable - skipping pre-promotion AD cleanup")
        return
    if role >= 4:
        log_skip(f"{vm} is already a DC (role {role}) - skipping pre-promotion cleanup")
        return
    if not vm_running("dc01"):
        log_warn("dc01 is not running - skipping pre-promotion AD cleanup")
        return

    # Pick the credential that is valid RIGHT NOW on dc01.
    pw = ADMIN_PASS
    rc, out = vagrant_winrm("dc01", "(Get-ADDomain).DNSRoot", password=pw, timeout=60)
    if DOMAIN not in out:
        pw = "vagrant"
        rc, out = vagrant_winrm("dc01", "(Get-ADDomain).DNSRoot", password=pw, timeout=60)
        if DOMAIN not in out:
            log_warn("dc01 is not a reachable domain controller - "
                     "skipping pre-promotion AD cleanup")
            return

    log_info(f"Removing stale parent-domain AD objects for {vm} before promotion...")
    ps = _ad_cleanup_script(vm, True, False)
    with DC01_LOCK:
        rc, out = vagrant_winrm("dc01", ps, password=pw, timeout=240)
    for line in (out or "").splitlines():
        line = line.strip()
        if line.startswith("REMOVED"):
            log_info(f"  [ad] {line}")
        elif line.startswith("ABSENT"):
            log_verbose(f"    [ad] {line}")


def clean_stale_child_domain(password=None):
    log_info("Cleaning stale child-domain metadata on DC01 (for DC03 rebuild)...")
    password = password or ADMIN_PASS
    child_label = CHILD_DOMAIN.split(".")[0]
    ps = (r'''
$childDN = "__CHILD_DN__"
$partitionsDN = "CN=Partitions,CN=Configuration,__DOMAIN_DN__"
Import-Module ActiveDirectory -ErrorAction SilentlyContinue
$dc03Present = $false
try { if (Get-ADComputer -Identity "DC03" -ErrorAction Stop) { $dc03Present = $true } } catch {}
if ($dc03Present) {
    Write-Host "DC03 computer object present - leaving child domain intact"
} else {
    try {
        $crossRefs = Get-ADObject -SearchBase $partitionsDN -SearchScope OneLevel -LDAPFilter "(objectClass=crossRef)" -Properties nCName -ErrorAction Stop | Where-Object { $_.nCName -eq $childDN }
        foreach ($cr in $crossRefs) { Remove-ADObject -Identity $cr.DistinguishedName -Recursive -Confirm:$false -ErrorAction Stop }
    } catch {}
    Import-Module DnsServer -ErrorAction SilentlyContinue
    Get-DnsServerResourceRecord -ZoneName "__DOMAIN__" -Name "__CHILD_LABEL__" -RRType NS -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-DnsServerResourceRecord -ZoneName "__DOMAIN__" -InputObject $_ -Force -ErrorAction SilentlyContinue
    }
    $fwd = Get-DnsServerZone -Name "__CHILD_DOMAIN__" -ErrorAction SilentlyContinue
    if ($fwd -and $fwd.ZoneType -eq "Forwarder") { Remove-DnsServerZone -Name "__CHILD_DOMAIN__" -Force -ErrorAction SilentlyContinue }
    Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
}
'''   .replace("__CHILD_DN__", _domain_dn(CHILD_DOMAIN))
      .replace("__DOMAIN_DN__", _domain_dn(DOMAIN))
      .replace("__DOMAIN__", DOMAIN)
      .replace("__CHILD_LABEL__", child_label)
      .replace("__CHILD_DOMAIN__", CHILD_DOMAIN))
    with DC01_LOCK:
        vagrant_winrm("dc01", ps, password=password, timeout=180)


def wait_forest_replication(timeout=300):
    """Force and then wait for DC01<->DC02 replication to converge before the
    DC03 child-domain is created. A not-yet-converged forest makes
    Install-ADDSDomain fail its uniqueness check ('could not determine if the
    domain name ... is unique ... replication partner shows replication
    errors'). Best-effort: logs a warning and continues if it can't confirm."""
    log_info("Forcing + waiting for forest replication to converge (DC01<->DC02)...")
    # Push a full sync first so we are not merely waiting on the default schedule.
    with DC01_LOCK:
        vagrant_winrm("dc01", "repadmin /syncall /AdeP 2>&1 | Out-Null; 'done'",
                      password=ADMIN_PASS, timeout=180)
    deadline = time.time() + timeout
    while time.time() < deadline:
        with DC01_LOCK:
            rc, out = vagrant_winrm(
                "dc01",
                # repadmin /replsummary prints a 'fails/total' column per DSA. Any
                # line whose fails count is non-zero (e.g. '2 / 5') means replication
                # is not healthy yet; '0 / N' on every line means converged.
                "$s = repadmin /replsummary 2>&1 | Out-String; "
                "if ($s -match '[1-9]\\d*\\s*/\\s*\\d+') { 'PENDING' } else { 'CONVERGED' }",
                password=ADMIN_PASS, timeout=120)
        if "CONVERGED" in out:
            log_ok("Forest replication converged")
            return True
        log_verbose("    replication not converged yet; re-syncing...")
        with DC01_LOCK:
            vagrant_winrm("dc01", "repadmin /syncall /AdeP 2>&1 | Out-Null; 'done'",
                          password=ADMIN_PASS, timeout=180)
        time.sleep(15)
    log_warn("Could not confirm replication convergence within "
             f"{timeout}s; continuing (DC03 promotion has its own retry loop)")
    return False


def reload_vm(vm, password=None):
    vagrant(["reload", vm, "--force"], password=password, filter_winrm=True)


def provision(vm, name, password=None, timeout=None, extra_env=None):
    rc, _ = vagrant(["provision", vm, "--provision-with", name],
                    password=password, filter_winrm=True, timeout=timeout,
                    extra_env=extra_env)
    return rc


def wait_for_role(vm, wanted_roles, attempts=48, delay=5, password=None):
    for i in range(1, attempts + 1):
        time.sleep(delay)
        # Pass the caller's known-good credential straight through. Without this
        # a promoted dc02 (password already ADMIN_PASS) was probed with stale
        # 'vagrant' first, burning the full WinRM auth-retry timeout every loop.
        role = _winrm_role(vm, password=password)
        if role in wanted_roles:
            log_ok(f"{vm} ready (role {role}) after {i*delay}s")
            return True
        log_verbose(f"    {vm} attempt {i}/{attempts} (role={role})")
    return False


def wait_winrm_stable(vm, password=None, timeout=180, delay=5):
    """Wait until WinRM answers two consecutive short commands.

    AD DS promotion/finalization briefly restarts services; the first few WinRM
    calls after AD answers can still hang (this is what made the first dc01
    'dns' run sit for 30 minutes). Requiring two successes means the next long
    provisioner starts against a settled WinRM stack.
    """
    deadline = time.time() + timeout
    streak = 0
    while time.time() < deadline:
        rc, out = vagrant_winrm(vm, "hostname", password=password, timeout=30)
        if rc == 0 and out.strip():
            streak += 1
            if streak >= 2:
                log_verbose(f"    {vm} WinRM stable")
                return True
        else:
            streak = 0
        time.sleep(delay)
    return False


def sysprep_vm(vm):
    """Generate a unique machine SID (sysprep /generalize), unless already a
    DC or already domain-joined."""
    role = _winrm_role(vm)
    if role is None:
        log_warn(f"{vm} role undetermined (WinRM unreachable) - skipping sysprep")
        return
    if role >= 4:
        log_skip(f"{vm} already a DC (role {role}); skipping sysprep")
        return
    if vm in MEMBERS and role in (1, 3):
        log_skip(f"{vm} already domain-joined (role {role}); skipping sysprep")
        return
    # sysprep_sid.ps1's FirstLogonCommands writes this marker after OOBE
    # completes. If it exists, generalize already ran - re-running sysprep would
    # fail ("Sysprep was not able to validate...") or waste another OOBE cycle.
    rc, marker = vagrant_winrm(
        vm, "Test-Path C:\\Windows\\Temp\\lab_sysprep.done",
        password="vagrant", timeout=30)
    already_sysprepped = "True" in marker
    if already_sysprepped:
        log_skip(f"{vm} already sysprepped (lab_sysprep.done present) - "
                 "skipping sysprep, re-applying base config")

    if not already_sysprepped:
        log_info(f"Sysprep (new SID) on {vm}...")
        provision(vm, "sysprep")
        # sysprep /generalize /oobe /reboot runs ASYNCHRONOUSLY and reboots the VM
        # on its own schedule, OUTSIDE Vagrant's control. The generalize +
        # specialize + OOBE cycle never completes in under ~90s. Give sysprep a
        # mandatory settle window, THEN wait for the post-OOBE FirstLogonCommands
        # to bring WinRM back, requiring two consecutive successes so we never
        # latch onto a half-up pre-reboot session.
        SETTLE = 90
        log_info(f"Waiting {SETTLE}s for {vm} to generalize + reboot into OOBE...")
        time.sleep(SETTLE)
        online = False
        streak = 0
        for i in range(1, 41):  # ~ up to SETTLE + several minutes
            rc, _ = vagrant(["winrm", vm, "-c", "exit 0"], capture=True, timeout=30)
            if rc == 0:
                streak += 1
                if streak >= 2:
                    log_ok(f"{vm} back online after sysprep (~{SETTLE + i*10}s)")
                    online = True
                    break
            else:
                streak = 0
            time.sleep(10)
            log_verbose(f"    {vm} post-sysprep wait {i}/40 (streak={streak})...")
        if not online:
            # OOBE can sit forever on a black screen after a host sleep/pause
            # (observed on dc02, 2026-10-27). One reset resumed it in ~60s.
            log_warn(f"{vm} did not come back after sysprep; resetting once and retrying...")
            vbox(["controlvm", VBOX_NAME[vm], "reset"])
            streak = 0
            for i in range(1, 21):
                rc, _ = vagrant(["winrm", vm, "-c", "exit 0"], capture=True, timeout=30)
                if rc == 0:
                    streak += 1
                    if streak >= 2:
                        log_ok(f"{vm} back online after reset (~{i*10}s)")
                        online = True
                        break
                else:
                    streak = 0
                time.sleep(10)
        if not online:
            raise LabError(f"{vm} did not come back after sysprep/reset")
    log_info(f"Reloading {vm} to stabilize...")
    reload_vm(vm)
    if vm not in MEMBERS:
        # DCs must have their static IP re-applied after sysprep. dc_base.ps1
        # also renames the machine to e.g. DC02 (the sysprep unattend restores
        # the base-box name 'vagrant-build'), which leaves a PENDING rename that
        # must be applied by a reboot BEFORE the caller runs 'join' - otherwise
        # Install-ADDSDomainController fails with "Name change pending. A reboot
        # is required." Re-apply base, then reload to commit the rename, then
        # nudge NLA so the internal NIC lands on the Private (DomainAuthenticated)
        # profile rather than staying Public (which can block WinRM/AD traffic).
        log_info(f"Re-applying base config (IP) on {vm}...")
        provision(vm, "base")
        log_info(f"Rebooting {vm} to apply the computer rename before promotion...")
        reload_vm(vm)
        # Nudge NLA so the internal NIC lands on Private, not Public. The account
        # is still the local 'vagrant' here (promotion/password reset happen next).
        vagrant_winrm(vm, "Restart-Service NlaSvc -Force; Start-Sleep 5",
                      password="vagrant")


# ─────────────────────────────────────────────────────────────────────────────
# Per-VM build pipelines
# ─────────────────────────────────────────────────────────────────────────────

def _dc01_is_promoted():
    """True if DC01 is already a forest DC (regardless of which password the
    Administrator account currently has - promotion happens before the 'dns'
    provisioner resets it to ADMIN_PASS)."""
    for pw in ("vagrant", ADMIN_PASS):
        rc, out = vagrant_winrm("dc01", "(Get-ADDomain).DNSRoot", password=pw, timeout=60)
        if "secscope" in out:
            return True
    return False


def _dc01_dns_done():
    """True once the 'dns' provisioner has run: it resets the Administrator
    password to ADMIN_PASS and creates the reverse-lookup zone."""
    rc, out = vagrant_winrm("dc01", "(Get-ADDomain).DNSRoot", password=ADMIN_PASS,
                            timeout=60)
    return "secscope" in out


def _dc01_promotion_diagnostics():
    """Best-effort tail of the detached promotion logs when the AD poll fails."""
    ps = ("Get-Content C:\\Windows\\Temp\\dc01_addsforest.err.log,"
          "C:\\Windows\\Temp\\dc01_addsforest.out.log -Tail 25 "
          "-ErrorAction SilentlyContinue")
    for pw in ("vagrant", ADMIN_PASS):
        rc, out = vagrant_winrm("dc01", ps, password=pw, timeout=60)
        if out and out.strip():
            log_warn("Promotion log tail:")
            for line in out.strip().splitlines()[-30:]:
                log_warn(f"  {line}")
            return
    log_warn("No promotion logs found "
             "(C:\\Windows\\Temp\\dc01_addsforest.{out,err}.log)")


def build_dc01():
    log_step("[dc01] Base boot + AD DS forest promotion")
    if not vm_running("dc01"):
        vagrant_up("dc01")

    # Idempotent resume: skip promotion if DC01 is already a domain controller
    # (e.g. an earlier run was interrupted after promotion but before DNS).
    if _dc01_is_promoted():
        log_skip("DC01 already promoted; resuming at post-promotion steps")
    else:
        log_info("Promoting DC01 to forest root (detached task; WinRM drops while the local SAM is replaced)...")
        rc = provision("dc01", "postboot")
        if rc != 0:
            log_warn(f"postboot returned {rc} - the promotion task may not have "
                     "started (see the postboot output above); waiting for AD anyway")

        # The promotion runs as a SYSTEM scheduled task and reboots the guest
        # itself. Do NOT reload here: a reload while Install-ADDSForest is still
        # running leaves a half-promoted DC that never boots cleanly. Wait for
        # the automatic reboot and for AD to answer.
        log_info("Waiting for DC01 promotion + automatic reboot (up to 20 minutes)...")
        ready = False
        deadline = time.time() + 1200
        attempt = 0
        while time.time() < deadline:
            attempt += 1
            rc, out = vagrant_winrm("dc01", "(Get-ADDomain).DNSRoot",
                                    password="vagrant", timeout=60)
            if "secscope" in out:
                log_ok(f"AD ready after ~{attempt * 10}s")
                ready = True
                break
            if attempt % 6 == 0:
                # A hard task failure is recorded in the .done marker; stop
                # early instead of burning the full 20-minute deadline.
                mrc, marker = vagrant_winrm(
                    "dc01",
                    "Get-Content C:\\Windows\\Temp\\dc01_addsforest.done "
                    "-ErrorAction SilentlyContinue",
                    password="vagrant", timeout=30)
                if "failed" in marker:
                    _dc01_promotion_diagnostics()
                    raise LabError("DC01 promotion task failed (see log above)")
                log_verbose(f"    ... waiting for AD ({attempt}) rc={rc}")
            time.sleep(10)
        if not ready:
            _dc01_promotion_diagnostics()
            raise LabError("DC01 AD did not initialize within 20 minutes")

    # The Administrator password is still 'vagrant' until the 'dns' provisioner
    # runs. If DNS already ran (resumed build), it is ADMIN_PASS. Pick whichever
    # is valid now so ensure_adws / NLA don't hit a WinRM auth-retry storm.
    current_pw = ADMIN_PASS if _dc01_dns_done() else "vagrant"
    if not wait_winrm_stable("dc01", password=current_pw):
        log_warn("DC01 WinRM still unstable after promotion; continuing anyway")
    vagrant_winrm("dc01", "Restart-Service NlaSvc -Force; Start-Sleep 5",
                  password=current_pw)
    ensure_adws("dc01", password=current_pw)

    log_step("[dc01] DNS configuration")
    for attempt in (1, 2, 3):
        pw = ADMIN_PASS if _dc01_dns_done() else "vagrant"
        rc = provision("dc01", "dns", password=pw)  # resets Administrator -> ADMIN_PASS
        if rc == 0:
            break
        log_warn(f"dns provisioner failed (rc={rc}); retrying ({attempt}/3) "
                 "after WinRM settles...")
        wait_winrm_stable("dc01", password=pw, timeout=240)
    else:
        raise LabError("dc01 dns provisioner failed after 3 attempts")
    log_info("Cleaning stale NAT DNS records...")
    clean_nat_leak()

    log_step("[dc01] AD objects - base (users, groups, OUs)")
    for attempt in (1, 2, 3):
        rc = provision("dc01", "objects-base", password=ADMIN_PASS)
        if rc == 0:
            break
        log_warn(f"objects-base provisioner failed (rc={rc}); retrying ({attempt}/3)...")
        wait_winrm_stable("dc01", password=ADMIN_PASS)
    else:
        raise LabError("dc01 objects-base provisioner failed after 3 attempts")

    if DISABLE_AV_UPDATE:
        log_step("[dc01] AV/Update disable GPO (--disable-av-update)")
        provision("dc01", "avupdate-gpo", password=ADMIN_PASS)
    log_ok("DC01 build complete")


def _dc_secondary(vm):
    """dc02 / dc03 shared pipeline."""
    log_step(f"[{vm}] Boot")
    if not vm_running(vm):
        vagrant_up(vm)

    # Idempotent resume: if the VM is already a domain controller (role >= 4),
    # an earlier run got past promotion - skip sysprep/base/join and go straight
    # to the post-promotion configuration. _winrm_role() already tries both the
    # 'vagrant' and ADMIN_PASS credentials, so a promoted dc03 (whose child-
    # domain Administrator may still be 'vagrant') is detected too.
    # Short probes: on a resumed dc02/dc03 the Administrator password may already
    # be ADMIN_PASS while the stale 'vagrant' credential is tried first. A 20s
    # bound keeps that from looking like a hang.
    role = _winrm_role(vm, timeout=20)
    already_dc = role is not None and role >= 4
    if already_dc:
        log_skip(f"{vm} already promoted; resuming at post-promotion steps")
    else:
        log_step(f"[{vm}] Sysprep")
        # sysprep_vm re-applies the 'base' provisioner (static IP) after its
        # reload for non-member VMs, so DCs need NO separate base step here -
        # a second base+reload re-bounces the already-configured NIC mid-command
        # and severs WinRM (KeepAliveDisconnected -> boot timeout).
        sysprep_vm(vm)

        # Remove the previous incarnation's parent DC server/computer/DNS
        # objects before promoting. dc02_join/dc03_join only remove the computer
        # object; the orphaned CN=<VM>,CN=Servers object can make
        # Install-ADDSDomainController / Install-ADDSDomain fail on a rebuild.
        _clean_stale_dc_parent(vm)

        if vm == "dc03":
            # Now that the parent DC03 computer object is gone, this also cleans
            # the child-domain crossRef + NS delegation/forwarder.
            clean_stale_child_domain()
            # The child domain's uniqueness check reads the forest config/GC via
            # DC01; if DC01<->DC02 haven't converged yet the create aborts. Gate
            # on replication health (not just the serialized build order).
            wait_forest_replication()

        log_step(f"[{vm}] Domain-controller promotion")
        rc = provision(vm, "join")
        if rc != 0:
            log_warn(f"{vm} join wrapper returned {rc}; the detached task may "
                     "not have started (see the join output above)")
        # dc03 promotes a NEW child domain whose Administrator is still 'vagrant'
        # until dc03_postboot resets it; dc02 joins the existing domain (ADMIN_PASS).
        reload_pw = "vagrant" if vm == "dc03" else ADMIN_PASS
        # The join script runs as a SYSTEM scheduled task and reboots the guest
        # after promotion (WinRM auth is lost when the local SAM is replaced).
        # Reloading here would kill the promotion mid-flight.
        log_info(f"Waiting for {vm} promotion + automatic reboot (up to 25 minutes)...")
        if not wait_for_role(vm, (4, 5), attempts=120, delay=10, password=reload_pw):
            raise LabError(f"{vm} did not become a domain controller within ~25 minutes")
        wait_winrm_stable(vm, password=reload_pw)
        vagrant_winrm(vm, "Restart-Service NlaSvc -Force; Start-Sleep 5", password=reload_pw)
        ensure_adws(vm, password=reload_pw)

    log_step(f"[{vm}] Post-promotion configuration")
    if vm == "dc03":
        # Fresh dc03: Administrator is still 'vagrant' until dc03_postboot
        # resets it. Resumed dc03 (postboot already ran): ADMIN_PASS. Probe
        # quickly so we don't launch a long wrong-password WinRM retry storm.
        postboot_pw = "vagrant"
        rc, out = vagrant_winrm(vm, "hostname", password=postboot_pw, timeout=20)
        if not (out or "").strip():
            postboot_pw = ADMIN_PASS
        rc = provision(vm, "postboot", password=postboot_pw)
        if rc != 0 and postboot_pw != ADMIN_PASS:
            provision(vm, "postboot", password=ADMIN_PASS)
    else:
        provision(vm, "postboot", password=ADMIN_PASS)


def build_dc02():
    _dc_secondary("dc02")
    log_ok("DC02 build complete")


def build_dc03():
    _dc_secondary("dc03")
    # Parent-side child DNS + replication settle (GOAD parent_child_dns equivalent).
    log_step("[dc03] DC01 parent-side child DNS + replication settle")
    with DC01_LOCK:
        provision("dc01", "child-dns", password=ADMIN_PASS)
    log_info(f"Waiting for child domain {CHILD_DOMAIN} to replicate (up to 5m)...")
    for i in range(1, 31):
        with DC01_LOCK:
            rc, out = vagrant_winrm(
                "dc01",
                f"try {{ Get-ADDomain -Identity '{CHILD_DOMAIN}' -ErrorAction Stop | Out-Null; 'READY' }} catch {{ 'PENDING' }}",
                password=ADMIN_PASS)
        if "READY" in out:
            log_ok(f"Child domain {CHILD_DOMAIN} visible on DC01")
            break
        log_verbose(f"    child domain not replicated yet ({i}/30)...")
        time.sleep(10)
    else:
        log_warn("Child domain not confirmed after 5m; continuing")
    log_ok("DC03 build complete")


def _member_join(vm):
    log_step(f"[{vm}] Boot")
    if not vm_running(vm):
        vagrant_up(vm)
    log_step(f"[{vm}] Sysprep")
    sysprep_vm(vm)
    log_info("Pre-join NAT DNS cleanup on DC01...")
    clean_nat_leak()
    log_step(f"[{vm}] Domain join")
    provision(vm, "join")
    ok = False
    for attempt in (1, 2, 3):
        reload_vm(vm)
        role = _winrm_role(vm)
        name_ok = _member_name_ok(vm)
        if role in (1, 3) and name_ok:
            ok = True
            break
        # Joined but MIS-NAMED (e.g. still VAGRANT-BUILD because the rename hit
        # 'The directory service is busy'), or not joined yet. Re-run the
        # idempotent join provisioner - it detects the existing membership and
        # resumes at the rename - then reload again.
        log_warn(f"{vm} not fully joined after reload {attempt}/3 "
                 f"(role={role}, name_ok={name_ok}); re-running join...")
        provision(vm, "join")
        time.sleep(10)
    if not ok:
        raise LabError(f"{vm} did not reach a domain-joined role with the correct name "
                       f"(expected {vm.upper()})")
    log_ok(f"{vm} joined {DOMAIN} as {vm.upper()}")


def build_srv01():
    _member_join("srv01")
    log_step("[srv01] Services (IIS, SQL Express, ADCS)")
    provision("srv01", "services")
    _apply_member_acls("srv01")
    log_ok("SRV01 build complete")


def build_ws01():
    _member_join("ws01")
    log_step("[ws01] Misconfigurations")
    provision("ws01", "misconfig")
    _apply_member_acls("ws01")
    log_ok("WS01 build complete")


def build_ws02():
    _member_join("ws02")
    log_step("[ws02] Misconfigurations")
    provision("ws02", "misconfig")
    _apply_member_acls("ws02")
    log_ok("WS02 build complete")


def build_lin01():
    log_step("[lin01] Boot + SSSD domain join")
    if not vm_running("lin01"):
        vagrant_up("lin01")
    else:
        provision("lin01", "setup")
    log_ok("LIN01 build complete")


def _apply_member_acls(vm):
    """Re-run DC01 objects-final so the per-member delegation ACLs
    (ws01 HelpDesk GenericWrite, ws02 unconstrained, srv01 constrained) are
    applied now that the computer object exists. Idempotent."""
    log_info(f"Applying delegation/ACLs for {vm} on DC01...")
    with DC01_LOCK:
        # Scope to just this member so the ACL pass doesn't wait on the other,
        # not-yet-built members' computer objects.
        provision("dc01", "objects", password=ADMIN_PASS,
                  extra_env={"MEMBER_SCOPE": vm})


BUILDERS = {
    "dc01": build_dc01,
    "dc02": build_dc02,
    "dc03": build_dc03,
    "srv01": build_srv01,
    "ws01": build_ws01,
    "ws02": build_ws02,
    "lin01": build_lin01,
}


# ─────────────────────────────────────────────────────────────────────────────
# Dependency + guard enforcement
# ─────────────────────────────────────────────────────────────────────────────

def check_dependencies(vm):
    """Hard-block: every dependency must be running + provisioned."""
    missing = []
    for dep in DEPENDENCIES[vm]:
        if not (vm_running(dep) and is_provisioned(dep)):
            missing.append(dep)
    if missing:
        order = " -> ".join(_build_order([vm]))
        first = missing[0]
        raise LabError(
            f"Cannot build {vm} - required dependency "
            f"'{', '.join(missing)}' is not ready (must be running + provisioned).\n"
            f"       Required build order: {order}\n"
            f"       Fix: python3 setup.py build {first}"
        )


def _build_order(targets):
    """Topologically order the transitive closure of targets."""
    seen = []

    def visit(v):
        for d in DEPENDENCIES[v]:
            visit(d)
        if v not in seen:
            seen.append(v)

    for t in targets:
        visit(t)
    # Preserve inventory order among same-level items.
    return sorted(seen, key=lambda v: ALL_VMS.index(v))


# ─────────────────────────────────────────────────────────────────────────────
# Commands
# ─────────────────────────────────────────────────────────────────────────────

def resolve_targets(targets):
    if not targets:
        raise LabError("No machine specified. Try: python3 setup.py build dc01")
    if len(targets) == 1 and targets[0].lower() == "all":
        return list(ALL_VMS)
    resolved = []
    for t in targets:
        t = t.lower()
        if t not in ALL_VMS:
            raise LabError(f"Unknown machine '{t}'. Valid: {', '.join(ALL_VMS)}")
        resolved.append(t)
    return resolved


def cmd_build(targets, force=False, parallel=False, max_parallel=DEFAULT_MAX_PARALLEL,
              rebuild=False, clean=False):
    preflight()
    requested = resolve_targets(targets)
    order = _build_order(requested)  # includes dependencies for ordering
    preflight_boxes(requested)

    banner("AD Alligator Labs - Build")
    log(f"  Requested : {', '.join(requested)}")
    log(f"  Order     : {' -> '.join(order)}")
    log(f"  Mode      : {'parallel (max %d)' % max_parallel if parallel else 'sequential'}")

    start = time.time()
    built, skipped, failed = [], [], []

    def do_one(vm):
        # One-time guard.
        already = vm_exists(vm) and is_provisioned(vm)
        if already and not (force or rebuild):
            log_skip(f"{vm} already built (use 'rebuild {vm}' or --force to redo)")
            return ("skip", vm)
        if rebuild or (already and force):
            log_info(f"Rebuilding {vm}: destroying first...")
            vagrant(["destroy", "-f", vm], filter_winrm=True)
            _clean_vbox_artifacts(vm)
            if clean:
                # Must run after destroy: it refuses to touch a live VM's AD
                # metadata. dc01 is skipped internally (forest root).
                _clean_ad_metadata(vm)
        # Dependencies must be satisfied at build time.
        check_dependencies(vm)
        BUILDERS[vm]()
        return ("built", vm)

    # Only act on the VMs the user actually requested; dependencies that are
    # merely ordering context are NOT auto-built (hard-block instead).
    to_process = [vm for vm in order if vm in requested]

    if parallel:
        # Group into dependency levels; run each level concurrently.
        done = set(vm for vm in ALL_VMS if vm_running(vm) and is_provisioned(vm))
        remaining = list(to_process)
        while remaining:
            ready = [vm for vm in remaining
                     if all(d in done or d not in requested for d in DEPENDENCIES[vm])]
            if not ready:
                # Deadlock: deps not built and not requested -> let check_dependencies raise.
                ready = [remaining[0]]
            with concurrent.futures.ThreadPoolExecutor(max_workers=max_parallel) as ex:
                futs = {ex.submit(do_one, vm): vm for vm in ready}
                for fut in concurrent.futures.as_completed(futs):
                    vm = futs[fut]
                    try:
                        status, _ = fut.result()
                        (built if status == "built" else skipped).append(vm)
                        done.add(vm)
                    except LabError as e:
                        failed.append(vm)
                        log_err(str(e))
            for vm in ready:
                remaining.remove(vm)
    else:
        for vm in to_process:
            try:
                status, _ = do_one(vm)
                (built if status == "built" else skipped).append(vm)
            except LabError as e:
                failed.append(vm)
                log_err(str(e))
                break  # sequential: stop on first failure

    elapsed = int(time.time() - start)
    log("")
    banner("Build Summary")
    log(f"  Time    : {elapsed // 60}m {elapsed % 60}s")
    log(f"  Built   : {', '.join(built) or '(none)'}")
    log(f"  Skipped : {', '.join(skipped) or '(none)'}")
    if failed:
        log(f"  {C.RED}Failed  : {', '.join(failed)}{C.NC}")
        return 1
    log("")
    log_ok("Done. Next: 'status', then 'harden <vm>|all' and 'seal <vm>|all' when ready.")
    return 0


def cmd_status(targets=None):
    preflight()
    vms = resolve_targets(targets) if targets else list(ALL_VMS)
    banner("AD Alligator Labs - Status")
    headers = ("VM", "IP", "VBox", "Prov", "Role / Notes")
    widths = (7, 16, 12, 6, 40)
    line = "  " + "".join(h.ljust(w) for h, w in zip(headers, widths))
    print(f"{C.BOLD}{line}{C.NC}")
    print("  " + "-" * (sum(widths)))
    for vm in vms:
        st = probe_status(vm)
        prov = st["provisioned"]
        color = C.GREEN if prov == "YES" else (C.YELLOW if prov.startswith("YES") else C.RED)
        row = (
            st["vm"].ljust(widths[0])
            + st["ip"].ljust(widths[1])
            + st["vbox"].ljust(widths[2])
            + f"{color}{prov}{C.NC}".ljust(widths[3] + len(color) + len(C.NC))
            + st["notes"]
        )
        print("  " + row)
    print("")
    print(f"  Build order: {' -> '.join(DCS[:1])} -> dc02 -> dc03 -> "
          "{srv01, ws01, ws02, lin01}")
    return 0


def cmd_harden(targets, force=False):
    preflight()
    vms = resolve_targets(targets)
    if not confirm("remove vagrant credentials from", vms, force):
        return 1
    banner("Hardening - remove default vagrant credentials")
    log_warn("Hardening severs Vagrant management of each VM (deletes the vagrant account).")
    for vm in vms:
        if not vm_running(vm):
            log_skip(f"{vm} not running")
            continue
        log_info(f"Hardening {vm}...")
        rc = provision(vm, "harden", password=_harden_password(vm), timeout=900)
        if rc == 0:
            log_ok(f"{vm} hardened")
        else:
            log_warn(f"{vm} harden returned {rc} - check WinRM/SSH auth")
    return 0


def _harden_password(vm):
    """WinRM/SSH password the 'harden' provisioner must authenticate with.
    DCs have no local 'vagrant' account - their WinRM user is Administrator, whose
    password was reset to ADMIN_PASS by dc01_dns.ps1 - so harden must use
    ADMIN_PASS there, not the 'vagrant' default. Members (and lin01's SSH) still
    have vagrant/vagrant, so None lets vagrant use its default."""
    return ADMIN_PASS if vm in DCS else None


def _verify_internal_ip(vm):
    """Confirm the VM holds its 192.168.200.x internal IP over WinRM (ADMIN_PASS).
    lin01 is skipped (SSH-managed). Returns True if present/skipped, False if the
    probe ran but didn't find the IP. Must run BEFORE harden disables basic auth."""
    if vm == "lin01":
        return True
    rc, out = vagrant_winrm(
        vm,
        "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.200.*' }).IPAddress",
        password=ADMIN_PASS)
    if "192.168.200." in out:
        log_ok(f"{vm} internal IP present")
        return True
    log_warn(f"{vm} internal 192.168.200.x IP not confirmed - sealing anyway")
    return False


def _shutdown_vm(vm, shutdown_timeout=120, no_graceful=False):
    """Stop a running VM: local ACPI power-button (bounded) then poweroff.

    Do NOT use `vagrant halt` here: it rides WinRM, which harden may already have
    disabled, and Vagrant's own timeout is 1800s. VBoxManage local ACPI is
    bounded and works after harden.
    """
    if not vm_running(vm):
        return True
    name = VBOX_NAME[vm]
    if not no_graceful:
        log_info(f"Requesting graceful shutdown of {vm} "
                 f"(up to {shutdown_timeout}s)...")
        vbox(["controlvm", name, "acpipowerbutton"])
        deadline = time.time() + shutdown_timeout
        while time.time() < deadline:
            if not vm_running(vm):
                return True
            time.sleep(2)
    if vm_running(vm):
        log_info(f"{vm} still running - forcing poweroff...")
        vbox(["controlvm", name, "poweroff"])
        for _ in range(30):
            if not vm_running(vm):
                return True
            time.sleep(2)
    return not vm_running(vm)


def _seal_vm(vm, shutdown_timeout=120, no_graceful=False):
    """Graceful ACPI stop (bounded) -> poweroff fallback -> remove NAT nic1 ->
    restart headless, single-homed on 192.168.200.x. Returns the modifyvm rc.
    Caller verifies the internal IP first (WinRM is gone after harden)."""
    name = VBOX_NAME[vm]
    if not _shutdown_vm(vm, shutdown_timeout=shutdown_timeout,
                        no_graceful=no_graceful):
        log_warn(f"{vm} could not be powered off - cannot modify nic1")
        return 1
    log_info(f"Removing nic1 (NAT) from {name}...")
    rc, _ = vbox(["modifyvm", name, "--nic1", "none"])
    if rc != 0:
        log_warn(f"Could not modify {name}")
        return rc
    log_ok(f"{vm} single-homed on SECSCOPE.CORP")
    vbox(["startvm", name, "--type", "headless"])
    return 0


def cmd_seal(targets, force=False, shutdown_timeout=120, no_graceful=False):
    preflight()
    vms = resolve_targets(targets)
    if not confirm("seal (remove NAT nic1, sever management of)", vms, force):
        return 1
    banner("Seal network - remove NAT nic1 (single-homed)")
    log_warn("This removes Vagrant/WinRM/RDP access. Reach VMs via the VirtualBox")
    log_warn("console or an in-network host (Kali .99) afterwards.")
    log_warn("NOTE: seal does NOT remove the vagrant account - use 'harden' or")
    log_warn("'finalize' for that (always before sealing).")
    sealed, failures = 0, 0
    for vm in vms:
        if not vm_exists(vm):
            log_skip(f"{vm} not created")
            continue
        if vm_sealed(vm):
            log_skip(f"{vm} already sealed")
            continue
        _verify_internal_ip(vm)
        if _seal_vm(vm, shutdown_timeout=shutdown_timeout,
                    no_graceful=no_graceful) != 0:
            failures += 1
            continue
        sealed += 1
    log("")
    log_ok(f"Seal complete - {sealed} VM(s) sealed, {failures} issue(s)")
    return 0 if failures == 0 else 1


def cmd_finalize(targets, force=False, dns_clean=True, shutdown_timeout=120,
                 no_graceful=False):
    """End-of-build lockdown: verify internal IPs -> clean NAT-leak DNS ->
    harden (delete vagrant creds) -> seal (remove NAT nic1). Produces a lab that
    works on 192.168.200.x only. Ordering matters: harden needs WinRM/SSH, which
    seal then removes; the IP verify + DNS clean must precede harden (which
    disables WinRM basic auth)."""
    preflight()
    vms = resolve_targets(targets)
    if not confirm("harden AND seal (delete vagrant creds + remove NAT nic1, "
                   "sever management of)", vms, force):
        return 1
    banner("Finalize - harden + seal (single-homed on 192.168.200.x)")
    log_warn("This deletes the vagrant account AND removes the NAT nic1.")
    log_warn("'unseal' can restore the NAT adapter, but the vagrant account is")
    log_warn("NOT restored - reach VMs via Administrator/ADMIN_PASS, the VirtualBox")
    log_warn("console, or an in-network host (Kali .99) afterwards.")

    # DC01 last: shrink the window in which it could re-register 10.0.2.15 via
    # dynamic DNS between the cleanup and its own seal.
    ordered = [v for v in vms if v != "dc01"] + (["dc01"] if "dc01" in vms else [])

    # 1) Verify internal IPs while WinRM basic auth is still enabled (pre-harden).
    log_info("Verifying internal 192.168.200.x IPs...")
    for vm in ordered:
        if vm_running(vm):
            _verify_internal_ip(vm)
        else:
            log_skip(f"{vm} not running - cannot verify IP")

    # 2) Fix the NAT-leak: purge stale 10.0.2.* records from DC01's DNS so names
    #    resolve to 192.168.200.x (not a now-dead 10.0.2.15) after sealing.
    dns_done = False
    if dns_clean:
        if vm_running("dc01"):
            log_info("Cleaning NAT-leak DNS on DC01 (purging stale 10.0.2.* records)...")
            clean_nat_leak()
            log_ok("Stale 10.0.2.* records purged + DNS cache cleared")
            dns_done = True
        else:
            log_skip("DC01 not running - skipping NAT-leak DNS cleanup")
    else:
        log_skip("DNS cleanup disabled (--no-dns-clean)")

    # 3) Harden each running VM (deletes vagrant creds; disables WinRM basic auth).
    hardened = 0
    harden_warn = 0
    harden_failed = set()
    for vm in ordered:
        if not vm_running(vm):
            log_skip(f"{vm} not running - skipping harden")
            continue
        log_info(f"Hardening {vm}...")
        # DCs authenticate as Administrator/ADMIN_PASS (no local vagrant account);
        # members + lin01 keep vagrant/vagrant. Wrong creds here = a long WinRM
        # auth-retry storm AND a VM left with WinRM basic auth still enabled.
        rc = provision(vm, "harden", password=_harden_password(vm), timeout=900)
        if rc == 0:
            log_ok(f"{vm} hardened")
            hardened += 1
        else:
            log_warn(f"{vm} harden returned {rc} - vagrant creds may NOT be removed")
            harden_warn += 1
            harden_failed.add(vm)

    # 4) Seal each VM (remove NAT nic1). IPs were verified in step 1; WinRM is now
    #    gone, so _seal_vm does not re-probe. Never seal a VM whose harden failed:
    #    that would sever management while leaving the vagrant account behind.
    sealed, failures = 0, 0
    for vm in ordered:
        if not vm_exists(vm):
            log_skip(f"{vm} not created")
            continue
        if vm in harden_failed:
            log_warn(f"{vm} NOT sealed - harden failed (vagrant creds may remain)")
            failures += 1
            continue
        if vm_sealed(vm):
            log_skip(f"{vm} already sealed")
            continue
        if _seal_vm(vm, shutdown_timeout=shutdown_timeout,
                    no_graceful=no_graceful) != 0:
            failures += 1
            continue
        sealed += 1

    log("")
    log_ok(f"Finalize complete - {hardened} hardened, {sealed} sealed, "
           f"DNS cleaned: {'yes' if dns_done else 'no'}, "
           f"{failures + harden_warn} issue(s)")
    return 0 if (failures == 0 and harden_warn == 0) else 1


def cmd_unseal(targets, shutdown_timeout=120, no_graceful=False):
    preflight()
    vms = resolve_targets(targets)
    banner("Unseal network - restore NAT nic1")
    for vm in vms:
        name = VBOX_NAME[vm]
        if not vm_exists(vm):
            log_skip(f"{vm} not created")
            continue
        if not vm_sealed(vm):
            log_skip(f"{vm} not sealed")
            continue
        if not _shutdown_vm(vm, shutdown_timeout=shutdown_timeout,
                            no_graceful=no_graceful):
            log_warn(f"{vm} could not be powered off - cannot restore nic1")
            continue
        vbox(["modifyvm", name, "--nic1", "nat"])
        log_ok(f"{vm} NAT nic1 restored")
        vbox(["startvm", name, "--type", "headless"])
    return 0


def cmd_destroy(targets, force=False, clean=False):
    preflight()
    is_all = bool(targets) and len(targets) == 1 and targets[0].lower() == "all"
    vms = list(ALL_VMS) if is_all else resolve_targets(targets)
    if not confirm("destroy", vms, force):
        return 1
    if is_all:
        log_info("Destroying all VMs...")
        vagrant(["destroy", "-f"], filter_winrm=True)
        for vm in ALL_VMS:
            _clean_vbox_artifacts(vm)
        if clean:
            log_warn("All VMs destroyed - AD metadata cleanup skipped (forest gone)")
        log_ok("All VMs destroyed")
        return 0
    # dc01 last: while it is up, the other VMs' stale AD/DNS metadata can be
    # removed; after dc01 is destroyed there is no domain left to clean.
    ordered = [v for v in vms if v != "dc01"] + (["dc01"] if "dc01" in vms else [])
    for vm in ordered:
        log_info(f"Destroying {vm}...")
        vagrant(["destroy", "-f", vm], filter_winrm=True)
        _clean_vbox_artifacts(vm)
        if clean:
            _clean_ad_metadata(vm)
    log_ok("Destroy complete")
    return 0


def cmd_clean(targets, force=False, dry_run=False, vbox_only=False, ad_only=False,
              keep_vm=False):
    """Destroy VM(s) and/or purge everything that blocks a clean rebuild:
    VirtualBox leftovers, Vagrant state, stale AD server/computer objects and
    DNS records."""
    preflight()
    vms = resolve_targets(targets)
    banner("Clean - rebuild artifacts + AD/DNS metadata")
    if not dry_run and not confirm(
            "clean (destroy VM + purge artifacts + remove AD/DNS metadata for)",
            vms, force):
        return 1

    # dc01 last so the other VMs' metadata can be cleaned while the domain is up.
    ordered = [v for v in vms if v != "dc01"] + (["dc01"] if "dc01" in vms else [])
    destroyed, ad_cleaned = [], []
    for vm in ordered:
        log_step(f"[{vm}] Clean")
        running = vm_running(vm)
        exists = vm_exists(vm)

        if not ad_only:
            if exists or running:
                if keep_vm:
                    log_warn(f"{vm} still exists - --keep-vm set, not destroying")
                elif dry_run:
                    log_info(f"(dry-run) would destroy {vm} "
                             f"({'running' if running else 'poweroff'})")
                else:
                    log_info(f"Destroying {vm}...")
                    vagrant(["destroy", "-f", vm], filter_winrm=True)
                    destroyed.append(vm)
            if dry_run:
                log_info(f"(dry-run) would purge VirtualBox/Vagrant artifacts for {vm}")
            else:
                _clean_vbox_artifacts(vm)

        if not vbox_only:
            if dry_run:
                if running and not keep_vm and not ad_only:
                    log_info(f"(dry-run) would remove AD/DNS metadata for {vm} "
                             "after destroying it")
                else:
                    _clean_ad_metadata(vm, dry_run=True)
            elif vm == "dc01":
                _clean_ad_metadata(vm)          # logs the forest-root skip
            elif running:
                log_warn(f"{vm} is still running - skipping AD metadata cleanup "
                         "(destroy it first, or omit --keep-vm)")
            elif _clean_ad_metadata(vm):
                ad_cleaned.append(vm)

    log("")
    log_ok(f"Clean complete - destroyed: {', '.join(destroyed) or 'none'}; "
           f"AD cleaned: {', '.join(ad_cleaned) or 'none'}")
    return 0


def cmd_build_boxes(opts):
    preflight()
    packer_exe = "packer.exe" if os.name == "nt" else "packer"
    if shutil.which("packer") is None and (SCRIPT_DIR / "bin" / packer_exe).exists():
        os.environ["PATH"] = f"{SCRIPT_DIR / 'bin'}{os.pathsep}{os.environ['PATH']}"
    for tool in ("packer", "vagrant"):
        if shutil.which(tool) is None:
            raise LabError(f"{tool} not found in PATH")
    banner("AD Alligator Labs - Build Packer Boxes")

    build_server = not opts.get("workstation_only") and not opts.get("debian_only")
    build_win10 = not opts.get("server_only") and not opts.get("debian_only")
    # lin01 boots from the locally built 'secscope/debian-bookworm' box (see
    # Vagrantfile / DEBIAN_BOX), built from iso/debian-12.15.0-amd64-netinst.iso,
    # so the Debian box is built BY DEFAULT alongside the two Windows boxes.
    # Excluded by the Windows-only flags or by --skip-debian; --debian-only builds
    # only it. If its ISO is absent on a default run it is skipped with a warning
    # (below) rather than hard-failing, so Windows-only users aren't blocked.
    build_debian = (not opts.get("server_only") and not opts.get("workstation_only")
                    and not opts.get("skip_debian"))
    if opts.get("with_debian"):          # explicit: force it on
        build_debian = True
    if opts.get("debian_only"):
        build_server = build_win10 = False
        build_debian = True

    def build_one(name, box_name, iso, pkr_dir):
        if not Path(iso).exists():
            raise LabError(f"ISO not found: {iso}")
        log_info(f"Building {name} (ISO {iso})...")
        checksum = _sha256(iso)
        run(["packer", "init", str(pkr_dir)])
        # -force so a leftover output dir from a previous failed/cancelled build
        # (packer/builds/<name>) is overwritten instead of aborting with
        # "Output directory exists". Also proactively clear any stale .box.
        stale_box = SCRIPT_DIR / "packer" / "boxes" / f"{name}.box"
        if stale_box.exists():
            stale_box.unlink()
        rc, _ = run(["packer", "build", "-force", "-var", f"iso_path={iso}",
                     "-var", f"iso_checksum={checksum}",
                     str(pkr_dir / f"{name}.pkr.hcl")])
        if rc != 0:
            raise LabError(f"Packer build failed for {name}")
        if not opts.get("no_vagrant_add"):
            run(["vagrant", "box", "remove", box_name, "--force"], capture=True)
            run(["vagrant", "box", "add", "--name", box_name,
                 str(SCRIPT_DIR / "packer" / "boxes" / f"{name}.box")], check=True)
            log_ok(f"{box_name} added to Vagrant")

    iso_dir = SCRIPT_DIR / "iso"
    if build_server:
        build_one("windows-server-2022", "secscope/windows-server-2022",
                  opts.get("server_iso") or str(iso_dir / "SERVER_EVAL_x64FRE_en-us.iso"),
                  SCRIPT_DIR / "packer" / "windows-server-2022")
    if build_win10:
        build_one("windows-10", "secscope/windows-10",
                  opts.get("win10_iso") or str(iso_dir / "Win10_22H2_English_x64v1.iso"),
                  SCRIPT_DIR / "packer" / "windows-10")
    if build_debian:
        debian_iso = (opts.get("debian_iso")
                      or str(iso_dir / "debian-12.15.0-amd64-netinst.iso"))
        explicit_debian = bool(opts.get("debian_only") or opts.get("with_debian"))
        if not Path(debian_iso).exists() and not explicit_debian:
            log_warn(f"Debian ISO not found ({debian_iso}) - skipping the Debian box.")
            log_warn("lin01 needs secscope/debian-bookworm; download the ISO (see "
                     "INSTALL.md) then run: python3 setup.py build-boxes --debian-only")
        else:
            build_one("debian-bookworm", "secscope/debian-bookworm", debian_iso,
                      SCRIPT_DIR / "packer" / "debian-bookworm")
    log_ok("Box build complete")
    return 0


# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing (argparse) / dispatch
# ─────────────────────────────────────────────────────────────────────────────

VM_CHOICES = ALL_VMS + ["all"]

# Rich top-level epilog: dependency map, inventory, credentials, notes. Shown by
# `setup.py -h`. Kept ASCII-safe and wrapped so argparse renders it verbatim.
TOP_EPILOG = """\
dependency map (hard-blocking: a dep must be running + provisioned):
  dc01   <- (none)         Forest root DC
  dc02   <- dc01           Replica DC
  dc03   <- dc01, dc02     Child domain it.secscope.corp
  srv01  <- dc01           MSSQL + IIS + ADCS
  ws01   <- dc01           Workstation (HelpDesk GenericWrite)
  ws02   <- dc01           Workstation (unconstrained delegation)
  lin01  <- dc01           Linux (SSSD) domain member

  required build order:  dc01 -> dc02 -> dc03 -> {srv01, ws01, ws02, lin01}

examples:
  setup.py build dc01                  Build the forest root
  setup.py build dc02                  (requires dc01 ready)
  setup.py build dc03                  (requires dc01 AND dc02 ready)
  setup.py build srv01 ws01 ws02       Build several members sequentially
  setup.py build all --parallel        Build everything, deps serialized
  setup.py rebuild ws01 --clean        Destroy + purge + clean metadata, rebuild
  setup.py clean dc02                  Destroy + purge artifacts + clean AD/DNS
  setup.py clean all --dry-run         Preview cleanup for every VM
  setup.py status                      Show the state table
  setup.py harden all --force          Strip vagrant creds (after builds)
  setup.py seal all --force            Single-home every VM (final step)
  setup.py finalize all --force        Harden + fix DNS + seal (one step)

vm inventory:
  DC01  192.168.200.10   DC02 192.168.200.11   DC03 192.168.200.12
  SRV01 192.168.200.20   WS01 192.168.200.30   WS02 192.168.200.31
  LIN01 192.168.200.40   (Kali 192.168.200.99)

notes:
  * Each VM can be built only ONCE; rebuilding requires 'rebuild' or --force.
  * You destroy machines yourself; 'destroy' exists but is not part of build.
  * 'harden', 'seal' and 'finalize' cut off Vagrant/WinRM management - run them
    last, and they require --force (or an interactive confirmation).
  * 'finalize' = harden + seal in the correct order, and also purges the stale
    10.0.2.* (NAT-leak) DNS records so names resolve on 192.168.200.x only.
  * 'clean' removes rebuild blockers: VirtualBox leftovers (stale per-VM dirs,
    orphaned temp-named VMs), .vagrant state, stale AD server+computer objects
    and DNS A/PTR/SRV records. dc01's AD metadata is never removed (forest root).
    It destroys the VM by default; --keep-vm/--ad-only clean metadata only,
    --vbox-only skips AD, and --dry-run previews without changing anything.
"""


def positive_int(value):
    try:
        ivalue = int(value)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError(f"'{value}' is not an integer")
    if ivalue < 1:
        raise argparse.ArgumentTypeError(f"must be >= 1 (got {ivalue})")
    return ivalue


def _add_vms_argument(parser, nargs="+"):
    parser.add_argument(
        "vms", nargs=nargs, type=str.lower, metavar="VM",
        choices=VM_CHOICES,
        help="Target machine(s): " + ", ".join(ALL_VMS) + ", or 'all'.")


def build_parser():
    parser = argparse.ArgumentParser(
        prog="setup.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Active Directory Alligator Labs - per-machine build "
                    "orchestrator.\nBuilds one machine at a time in dependency "
                    "order, with a one-time\nbuild guard and a live status table.",
        epilog=TOP_EPILOG,
    )

    # Global options, shared with every subcommand via a parent parser so they
    # may appear before OR after the subcommand name.
    globals_parent = argparse.ArgumentParser(add_help=False)
    grp = globals_parent.add_argument_group("global options")
    out = grp.add_mutually_exclusive_group()
    out.add_argument("-v", "--verbose", action="store_true",
                     help="Show all provisioning output.")
    out.add_argument("-q", "--quiet", action="store_true",
                     help="Minimal output (non-interactive).")
    grp.add_argument("--debug", action="store_true",
                     help="Show suppressed WinRM errors too.")
    grp.add_argument("--no-color", action="store_true",
                     help="Disable coloured output.")

    # Apply globals to the top-level parser as well (so `setup.py -v build ...`
    # and `setup.py build ... -v` both work).
    for action in globals_parent._actions:
        if action.dest != "help":
            parser._add_action(action)

    sub = parser.add_subparsers(dest="command", metavar="<command>")

    # ── build ──
    p_build = sub.add_parser(
        "build", parents=[globals_parent],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        help="Build machine(s) end-to-end, in dependency order.",
        description="Build one, several, or 'all' machines end-to-end. "
                    "Dependencies are\nhard-blocking and the one-time guard "
                    "refuses an already-built VM\nunless --force is given.")
    _add_vms_argument(p_build)
    p_build.add_argument("--parallel", action="store_true",
                         help="Build independent VMs concurrently (deps stay serialized).")
    p_build.add_argument("--max-parallel", type=positive_int, default=DEFAULT_MAX_PARALLEL,
                         metavar="N",
                         help=f"Cap concurrent builds (default {DEFAULT_MAX_PARALLEL}).")
    p_build.add_argument("--force", action="store_true",
                         help="Allow (re)building a machine that is already built.")
    p_build.add_argument("--clean", action="store_true",
                         help="On --force/rebuild, also remove stale AD/DNS metadata "
                              "for the VM before building it.")
    p_build.add_argument("--disable-av-update", action="store_true",
                         help="Also apply the domain GPO that disables Defender AV "
                              "+ Windows Update forest-wide (dc01 only).")
    p_build.set_defaults(func=_run_build)

    # ── rebuild ──
    p_rebuild = sub.add_parser(
        "rebuild", parents=[globals_parent],
        help="Destroy + rebuild machine(s). Implies --force.",
        description="Destroy the given machine(s) and build them again from "
                    "scratch.")
    _add_vms_argument(p_rebuild)
    p_rebuild.add_argument("--parallel", action="store_true",
                           help="Build independent VMs concurrently (deps serialized).")
    p_rebuild.add_argument("--max-parallel", type=positive_int,
                           default=DEFAULT_MAX_PARALLEL, metavar="N",
                           help=f"Cap concurrent builds (default {DEFAULT_MAX_PARALLEL}).")
    p_rebuild.add_argument("--clean", action="store_true",
                           help="Also remove stale AD/DNS metadata for the VM "
                                "after destroying it (recommended for dc02/dc03).")
    p_rebuild.add_argument("--disable-av-update", action="store_true",
                           help="Also apply the Defender/Windows-Update disable GPO (dc01 only).")
    p_rebuild.set_defaults(func=_run_rebuild)

    # ── status ──
    p_status = sub.add_parser(
        "status", parents=[globals_parent],
        help="Live table: built / running / provisioned / role.",
        description="Probe VirtualBox + WinRM/SSH and print a state table.")
    _add_vms_argument(p_status, nargs="*")
    p_status.set_defaults(func=_run_status)

    # ── harden ──
    p_harden = sub.add_parser(
        "harden", parents=[globals_parent],
        help="Remove vagrant creds (severs mgmt). Requires --force/confirm.",
        description="Remove the default vagrant credentials. Run AFTER builds - "
                    "this\nsevers Vagrant/WinRM management of the machine.")
    _add_vms_argument(p_harden)
    p_harden.add_argument("--force", action="store_true",
                          help="Skip the interactive confirmation.")
    p_harden.set_defaults(func=_run_harden)

    # ── seal ──
    p_seal = sub.add_parser(
        "seal", parents=[globals_parent],
        help="Remove NAT nic1 -> single-homed. Requires --force/confirm.",
        description="Remove the NAT nic1 so each VM is single-homed on "
                    "192.168.200.x.\nThis severs Vagrant/WinRM/RDP management.")
    _add_vms_argument(p_seal)
    p_seal.add_argument("--force", action="store_true",
                        help="Skip the interactive confirmation.")
    p_seal.add_argument("--shutdown-timeout", type=positive_int, default=120,
                        metavar="N",
                        help="Graceful ACPI shutdown wait in seconds (default 120).")
    p_seal.add_argument("--no-graceful", action="store_true",
                        help="Skip ACPI shutdown and power off immediately.")
    p_seal.set_defaults(func=_run_seal)

    # ── finalize ──
    p_finalize = sub.add_parser(
        "finalize", parents=[globals_parent],
        help="Harden + seal in one step. Requires --force/confirm.",
        description="End-of-build lockdown: verify internal IPs, fix the NAT-leak\n"
                    "DNS on DC01, delete the vagrant account, then remove the NAT\n"
                    "nic1 so each VM is single-homed on 192.168.200.x. Severs\n"
                    "Vagrant/WinRM/RDP management.")
    _add_vms_argument(p_finalize)
    p_finalize.add_argument("--force", action="store_true",
                            help="Skip the interactive confirmation.")
    p_finalize.add_argument("--no-dns-clean", action="store_true",
                            help="Skip purging stale 10.0.2.* records from DC01's DNS.")
    p_finalize.add_argument("--shutdown-timeout", type=positive_int, default=120,
                            metavar="N",
                            help="Graceful ACPI shutdown wait in seconds (default 120).")
    p_finalize.add_argument("--no-graceful", action="store_true",
                            help="Skip ACPI shutdown and power off immediately.")
    p_finalize.set_defaults(func=_run_finalize)

    # ── unseal ──
    p_unseal = sub.add_parser(
        "unseal", parents=[globals_parent],
        help="Re-add NAT nic1 -> restore Vagrant/WinRM/RDP.",
        description="Re-add the NAT nic1 to restore management access.")
    _add_vms_argument(p_unseal)
    p_unseal.add_argument("--shutdown-timeout", type=positive_int, default=120,
                          metavar="N",
                          help="Graceful ACPI shutdown wait in seconds (default 120).")
    p_unseal.add_argument("--no-graceful", action="store_true",
                          help="Skip ACPI shutdown and power off immediately.")
    p_unseal.set_defaults(func=_run_unseal)

    # ── clean ──
    p_clean = sub.add_parser(
        "clean", parents=[globals_parent],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        help="Destroy + purge artifacts + clean AD/DNS metadata (rebuild prep).",
        description="Remove everything that blocks a clean rebuild:\n"
                    "  1. destroy the VM if it exists (unless --keep-vm / --ad-only),\n"
                    "  2. purge stale VirtualBox dirs / temp-named VMs / .vagrant state,\n"
                    "  3. remove stale AD server+computer objects and DNS A/PTR/SRV records\n"
                    "     (dc02/dc03 server objects, dc03 child-domain crossRef, etc.).\n"
                    "dc01 is the forest root: its AD metadata is never removed here.\n"
                    "Live VMs are never cleaned without destroying them first.")
    _add_vms_argument(p_clean)
    p_clean.add_argument("--force", action="store_true",
                         help="Skip the interactive confirmation.")
    p_clean.add_argument("--dry-run", action="store_true",
                         help="Report what would be removed; change nothing.")
    modes = p_clean.add_mutually_exclusive_group()
    modes.add_argument("--vbox-only", action="store_true",
                       help="Only purge VirtualBox/Vagrant artifacts (no AD/DNS).")
    modes.add_argument("--ad-only", action="store_true",
                       help="Only clean AD/DNS metadata (do not destroy/purge the VM).")
    p_clean.add_argument("--keep-vm", action="store_true",
                         help="Do not destroy an existing VM; only purge leftovers "
                              "and clean metadata for an already-destroyed VM.")
    p_clean.set_defaults(func=_run_clean)

    # ── destroy ──
    p_destroy = sub.add_parser(
        "destroy", parents=[globals_parent],
        help="Destroy machine(s). Requires --force/confirm.",
        description="Destroy the given machine(s) or 'all'.")
    _add_vms_argument(p_destroy)
    p_destroy.add_argument("--force", action="store_true",
                           help="Skip the interactive confirmation.")
    p_destroy.add_argument("--clean", action="store_true",
                           help="Also purge VirtualBox/Vagrant leftovers and remove "
                                "stale AD/DNS metadata (dc01 excluded).")
    p_destroy.set_defaults(func=_run_destroy)

    # ── build-boxes ──
    p_boxes = sub.add_parser(
        "build-boxes", parents=[globals_parent],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        help="Build Packer base boxes.",
        description="Build the Packer base boxes. By default builds all three: "
                    "Windows Server 2022, Windows 10, and the Debian box "
                    "(secscope/debian-bookworm) that lin01 needs. The Debian box "
                    "is skipped with a warning if its ISO is absent; use "
                    "--skip-debian to always skip it, or --debian-only / "
                    "--server-only / --workstation-only to build just one.")
    only = p_boxes.add_mutually_exclusive_group()
    only.add_argument("--server-only", action="store_true",
                      help="Build only the Windows Server 2022 box.")
    only.add_argument("--workstation-only", action="store_true",
                      help="Build only the Windows 10 box.")
    only.add_argument("--debian-only", action="store_true",
                      help="Build only the Debian box.")
    p_boxes.add_argument("--skip-debian", action="store_true",
                         help="Do NOT build the Debian box (build only the two "
                              "Windows boxes). lin01 will then be unbuildable.")
    p_boxes.add_argument("--with-debian", action="store_true",
                         help="Force-build the Debian box even if its ISO lookup "
                              "would otherwise skip it (redundant: Debian is on by "
                              "default; hard-fails if the ISO is missing).")
    p_boxes.add_argument("--no-vagrant-add", action="store_true",
                         help="Build boxes but do not add them to Vagrant.")
    p_boxes.add_argument("--server-iso", metavar="PATH", help="Custom Server 2022 ISO.")
    p_boxes.add_argument("--win10-iso", metavar="PATH", help="Custom Windows 10 ISO.")
    p_boxes.add_argument("--debian-iso", metavar="PATH", help="Custom Debian ISO.")
    p_boxes.set_defaults(func=_run_build_boxes)

    return parser


# ── Thin adapters: argparse Namespace -> existing cmd_* handlers ─────────────

def _run_build(args):
    global DISABLE_AV_UPDATE
    DISABLE_AV_UPDATE = getattr(args, "disable_av_update", False)
    return cmd_build(args.vms, force=args.force, parallel=args.parallel,
                     max_parallel=args.max_parallel, clean=args.clean)


def _run_rebuild(args):
    global DISABLE_AV_UPDATE
    DISABLE_AV_UPDATE = getattr(args, "disable_av_update", False)
    return cmd_build(args.vms, force=True, parallel=args.parallel,
                     max_parallel=args.max_parallel, rebuild=True,
                     clean=args.clean)


def _run_status(args):
    return cmd_status(args.vms or None)


def _run_harden(args):
    return cmd_harden(args.vms, force=args.force)


def _run_seal(args):
    return cmd_seal(args.vms, force=args.force,
                    shutdown_timeout=args.shutdown_timeout,
                    no_graceful=args.no_graceful)


def _run_finalize(args):
    return cmd_finalize(args.vms, force=args.force,
                        dns_clean=not args.no_dns_clean,
                        shutdown_timeout=args.shutdown_timeout,
                        no_graceful=args.no_graceful)


def _run_unseal(args):
    return cmd_unseal(args.vms, shutdown_timeout=args.shutdown_timeout,
                      no_graceful=args.no_graceful)


def _run_destroy(args):
    return cmd_destroy(args.vms, force=args.force, clean=args.clean)


def _run_clean(args):
    return cmd_clean(args.vms, force=args.force, dry_run=args.dry_run,
                     vbox_only=args.vbox_only, ad_only=args.ad_only,
                     keep_vm=args.keep_vm)


def _run_build_boxes(args):
    opts = {
        "server_only": args.server_only,
        "workstation_only": args.workstation_only,
        "debian_only": args.debian_only,
        "skip_debian": args.skip_debian,
        "with_debian": args.with_debian,
        "no_vagrant_add": args.no_vagrant_add,
        "server_iso": args.server_iso,
        "win10_iso": args.win10_iso,
        "debian_iso": args.debian_iso,
    }
    return cmd_build_boxes(opts)


def apply_global_flags(args):
    global VERBOSE, QUIET, DEBUG
    if getattr(args, "no_color", False):
        C.disable()
    if getattr(args, "verbose", False):
        VERBOSE = True
    if getattr(args, "quiet", False):
        QUIET = True
    if getattr(args, "debug", False):
        DEBUG = True


def main():
    parser = build_parser()
    args = parser.parse_args()
    apply_global_flags(args)

    if not getattr(args, "command", None):
        parser.print_help()
        return 0

    try:
        init_conf()
        return args.func(args)
    except LabError as e:
        log_err(str(e))
        return 1
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
