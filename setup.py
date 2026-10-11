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
import select
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
IPS = {}

# Which Packer box each VM boots from (for the build-time box preflight).
# lin01 uses the public debian/bookworm64 box, which Vagrant fetches on demand,
# so it needs no local box preflight.
def _vm_box(vm):
    if vm in ("ws01", "ws02"):
        return WORKSTATION_BOX
    if vm == "lin01":
        return None
    return SERVER_BOX


def init_conf():
    global CONF, ADMIN_PASS, DOMAIN, CHILD_DOMAIN, SERVER_BOX, WORKSTATION_BOX, IPS
    CONF = load_lab_conf()
    ADMIN_PASS = os.environ.get("ADMIN_PASS") or CONF.get("ADMIN_PASS", "vagrant")
    DOMAIN = CONF.get("DOMAIN", "secscope.corp")
    CHILD_DOMAIN = CONF.get("CHILD_DOMAIN", "it.secscope.corp")
    SERVER_BOX = CONF.get("SERVER_BOX", "secscope/windows-server-2022")
    WORKSTATION_BOX = CONF.get("WORKSTATION_BOX", "secscope/windows-10")
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


def run(cmd, env=None, capture=False, check=False, timeout=None, filter_winrm=False):
    """Run a command. Returns (rc, stdout_text). Streams live unless capture."""
    full_env = os.environ.copy()
    if env:
        full_env.update(env)

    if capture:
        try:
            proc = subprocess.run(
                cmd, env=full_env, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            return 124, ""
        if check and proc.returncode != 0:
            raise LabError(f"Command failed ({proc.returncode}): {' '.join(cmd)}")
        return proc.returncode, proc.stdout or ""

    # Streaming mode (optionally filtering WinRM noise line-by-line).
    show_all = VERBOSE or DEBUG
    try:
        proc = subprocess.Popen(
            cmd, env=full_env, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
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

    if os.name == "posix":
        # Drain with process-exit awareness. Tools like packer spawn VirtualBox,
        # which starts the long-lived VBoxSVC daemon; VBoxSVC can INHERIT this
        # stdout pipe, so a plain `for line in proc.stdout` never sees EOF after
        # packer exits and the build hangs forever between "box built" and the
        # next step. Here, once the process has exited and the pipe is idle, we
        # stop even if a grandchild still holds the write end open.
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
                # Exited with nothing pending this tick; one short grace drain.
                rlist, _, _ = select.select([fd], [], [], 0.2)
                if not rlist:
                    break
    else:
        for line in proc.stdout:
            _emit(line)
    try:
        proc.stdout.close()
    except Exception:
        pass
    proc.wait(timeout=timeout)
    if check and proc.returncode != 0:
        raise LabError(f"Command failed ({proc.returncode}): {' '.join(cmd)}")
    return proc.returncode, ""


def vagrant(args, password=None, filter_winrm=True, capture=False, timeout=None,
            check=False):
    env = {}
    if password is not None:
        env["DC_WINRM_PASSWORD"] = password
    return run(["vagrant"] + args, env=env, capture=capture, check=check,
               timeout=timeout, filter_winrm=filter_winrm)


def vagrant_winrm(vm, ps, password=None, timeout=120):
    """Run a PowerShell one-liner via WinRM; return (rc, output)."""
    return vagrant(["winrm", vm, "-c", ps], password=password, capture=True,
                   timeout=timeout, filter_winrm=True)


def vbox(args, capture=True):
    rc, out = run(["VBoxManage"] + args, capture=capture)
    return rc, out


# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────────────────

def preflight():
    missing = [t for t in ("vagrant", "VBoxManage") if shutil.which(t) is None]
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
        raise LabError(
            "Required Vagrant box(es) not installed: "
            f"{', '.join(absent)}.\n"
            "       Build the base boxes first:  python3 setup.py build-boxes"
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


def vm_nic1(vm):
    """Return nic1 type ('nat'/'none'/...) or None if the VM is missing."""
    rc, out = vbox(["showvminfo", VBOX_NAME[vm], "--machinereadable"])
    if rc != 0:
        return None
    m = re.search(r'^nic1="?([^"\n]+)"?', out, re.MULTILINE)
    return m.group(1) if m else None


def vm_sealed(vm):
    return vm_nic1(vm) == "none"


def _winrm_role(vm):
    """DomainRole int via WinRM, trying vagrant then ADMIN_PASS. None if unreachable."""
    for pw in ("vagrant", ADMIN_PASS):
        rc, out = vagrant_winrm(
            vm, "(Get-CimInstance Win32_ComputerSystem).DomainRole",
            password=pw, timeout=60)
        m = re.search(r"\b([0-5])\b", out)
        if m:
            return int(m.group(1))
    return None


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
        return DOMAIN in out
    if vm in ("dc02", "dc03"):
        role = _winrm_role(vm)
        return role is not None and role >= 4
    # member servers/workstations: role 1 (workstation) or 3 (member server)
    role = _winrm_role(vm)
    return role in (1, 3)


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


def clean_stale_child_domain():
    log_info("Cleaning stale child-domain metadata on DC01 (for DC03 rebuild)...")
    ps = r'''
$childDN = "DC=it,DC=secscope,DC=corp"
$partitionsDN = "CN=Partitions,CN=Configuration,DC=secscope,DC=corp"
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
    Get-DnsServerResourceRecord -ZoneName "secscope.corp" -Name "it" -RRType NS -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-DnsServerResourceRecord -ZoneName "secscope.corp" -InputObject $_ -Force -ErrorAction SilentlyContinue
    }
    $fwd = Get-DnsServerZone -Name "it.secscope.corp" -ErrorAction SilentlyContinue
    if ($fwd -and $fwd.ZoneType -eq "Forwarder") { Remove-DnsServerZone -Name "it.secscope.corp" -Force -ErrorAction SilentlyContinue }
    Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
}
'''
    with DC01_LOCK:
        vagrant_winrm("dc01", ps, password=ADMIN_PASS, timeout=180)


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


def provision(vm, name, password=None, timeout=None):
    rc, _ = vagrant(["provision", vm, "--provision-with", name],
                    password=password, filter_winrm=True, timeout=timeout)
    return rc


def wait_for_role(vm, wanted_roles, attempts=48, delay=5, password=None):
    for i in range(1, attempts + 1):
        time.sleep(delay)
        role = _winrm_role(vm)
        if role in wanted_roles:
            log_ok(f"{vm} ready (role {role}) after {i*delay}s")
            return True
        log_verbose(f"    {vm} attempt {i}/{attempts} (role={role})")
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
    log_info(f"Sysprep (new SID) on {vm}...")
    provision(vm, "sysprep")
    # /generalize reboots into OOBE and drops WinRM. Wait for it to go down...
    for _ in range(18):
        rc, _ = vagrant(["winrm", vm, "-c", "exit 0"], capture=True, timeout=30)
        if rc != 0:
            break
        time.sleep(5)
    # ...then wait for it to come back.
    online = False
    for i in range(1, 31):
        time.sleep(10)
        rc, _ = vagrant(["winrm", vm, "-c", "exit 0"], capture=True, timeout=30)
        if rc == 0:
            log_ok(f"{vm} back online after sysprep ({i*10}s)")
            online = True
            break
        log_verbose(f"    {vm} sysprep wait {i}/30...")
    if not online:
        raise LabError(f"{vm} did not come back after sysprep")
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


def build_dc01():
    log_step("[dc01] Base boot + AD DS forest promotion")
    if not vm_running("dc01"):
        vagrant(["up", "dc01"], filter_winrm=True, check=True)

    # Idempotent resume: skip promotion if DC01 is already a domain controller
    # (e.g. an earlier run was interrupted after promotion but before DNS).
    if _dc01_is_promoted():
        log_skip("DC01 already promoted; resuming at post-promotion steps")
    else:
        log_info("Promoting DC01 to forest root (WinRM errors during promotion are expected)...")
        provision("dc01", "postboot")
        log_info("Rebooting DC01 to finalize promotion...")
        reload_vm("dc01")

        log_info("Polling for AD to initialize (up to 240s)...")
        ready = False
        for i in range(1, 49):
            time.sleep(5)
            rc, out = vagrant_winrm("dc01", "Get-ADDomain", password="vagrant", timeout=60)
            if "secscope" in out:
                log_ok(f"AD ready after {i*5}s")
                ready = True
                break
            log_verbose(f"    ... attempt {i}/48")
        if not ready:
            raise LabError("DC01 AD did not initialize within 240s")

    # The Administrator password is still 'vagrant' until the 'dns' provisioner
    # runs. If DNS already ran (resumed build), it is ADMIN_PASS. Pick whichever
    # is valid now so ensure_adws / NLA don't hit a WinRM auth-retry storm.
    current_pw = ADMIN_PASS if _dc01_dns_done() else "vagrant"
    vagrant_winrm("dc01", "Restart-Service NlaSvc -Force; Start-Sleep 5",
                  password=current_pw)
    ensure_adws("dc01", password=current_pw)

    log_step("[dc01] DNS configuration")
    provision("dc01", "dns", password=current_pw)  # resets Administrator -> ADMIN_PASS
    log_info("Cleaning stale NAT DNS records...")
    clean_nat_leak()

    log_step("[dc01] AD objects - base (users, groups, OUs)")
    provision("dc01", "objects-base", password=ADMIN_PASS)

    if DISABLE_AV_UPDATE:
        log_step("[dc01] AV/Update disable GPO (--disable-av-update)")
        provision("dc01", "avupdate-gpo", password=ADMIN_PASS)
    log_ok("DC01 build complete")


def _dc_secondary(vm):
    """dc02 / dc03 shared pipeline."""
    log_step(f"[{vm}] Boot")
    if not vm_running(vm):
        vagrant(["up", vm], filter_winrm=True, check=True)

    # Idempotent resume: if the VM is already a domain controller (role >= 4),
    # an earlier run got past promotion - skip sysprep/base/join and go straight
    # to the post-promotion configuration. _winrm_role() already tries both the
    # 'vagrant' and ADMIN_PASS credentials, so a promoted dc03 (whose child-
    # domain Administrator may still be 'vagrant') is detected too.
    role = _winrm_role(vm)
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

        if vm == "dc03":
            clean_stale_child_domain()
            # The child domain's uniqueness check reads the forest config/GC via
            # DC01; if DC01<->DC02 haven't converged yet the create aborts. Gate
            # on replication health (not just the serialized build order).
            wait_forest_replication()

        log_step(f"[{vm}] Domain-controller promotion")
        provision(vm, "join")
        # dc03 promotes a NEW child domain whose Administrator is still 'vagrant'
        # until dc03_postboot resets it; dc02 joins the existing domain (ADMIN_PASS).
        reload_pw = "vagrant" if vm == "dc03" else ADMIN_PASS
        reload_vm(vm, password=reload_pw)

        if not wait_for_role(vm, (4, 5), password=reload_pw):
            raise LabError(f"{vm} did not become a domain controller within 240s")
        vagrant_winrm(vm, "Restart-Service NlaSvc -Force; Start-Sleep 5", password=reload_pw)
        ensure_adws(vm, password=reload_pw)

    log_step(f"[{vm}] Post-promotion configuration")
    if vm == "dc03":
        rc = provision(vm, "postboot", password="vagrant")
        if rc != 0:
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
        vagrant(["up", vm], filter_winrm=True, check=True)
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
        if role in (1, 3):
            ok = True
            break
        log_warn(f"{vm} not domain-joined after reload {attempt}/3 (role={role}); retrying...")
        time.sleep(10)
    if not ok:
        raise LabError(f"{vm} did not reach a domain-joined role")
    log_ok(f"{vm} joined {DOMAIN}")


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
        vagrant(["up", "lin01"], filter_winrm=True, check=True)
    else:
        provision("lin01", "setup")
    log_ok("LIN01 build complete")


def _apply_member_acls(vm):
    """Re-run DC01 objects-final so the per-member delegation ACLs
    (ws01 HelpDesk GenericWrite, ws02 unconstrained, srv01 constrained) are
    applied now that the computer object exists. Idempotent."""
    log_info(f"Applying delegation/ACLs for {vm} on DC01...")
    with DC01_LOCK:
        provision("dc01", "objects", password=ADMIN_PASS)


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
              rebuild=False):
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
        provision(vm, "harden")
        log_ok(f"{vm} hardened")
    return 0


def cmd_seal(targets, force=False):
    preflight()
    vms = resolve_targets(targets)
    if not confirm("seal (remove NAT nic1, sever management of)", vms, force):
        return 1
    banner("Seal network - remove NAT nic1 (single-homed)")
    log_warn("This removes Vagrant/WinRM/RDP access. Reach VMs via the VirtualBox")
    log_warn("console or an in-network host (Kali .99) afterwards.")
    sealed, failures = 0, 0
    for vm in vms:
        name = VBOX_NAME[vm]
        if not vm_exists(vm):
            log_skip(f"{vm} not created")
            continue
        if vm_sealed(vm):
            log_skip(f"{vm} already sealed")
            continue
        if vm != "lin01":
            rc, out = vagrant_winrm(
                vm,
                "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.200.*' }).IPAddress",
                password=ADMIN_PASS)
            if "192.168.200." in out:
                log_ok(f"{vm} internal IP present")
            else:
                log_warn(f"{vm} internal 192.168.200.x IP not confirmed - sealing anyway")
        # Graceful halt (bounded), then hard poweroff so modifyvm can proceed.
        log_info(f"Halting {vm}...")
        vagrant(["halt", vm], filter_winrm=True, timeout=60)
        if vm_running(vm):
            log_info(f"{vm} still running - forcing poweroff...")
            vbox(["controlvm", name, "poweroff"])
        for _ in range(15):
            if not vm_running(vm):
                break
            time.sleep(2)
        log_info(f"Removing nic1 (NAT) from {name}...")
        rc, _ = vbox(["modifyvm", name, "--nic1", "none"])
        if rc != 0:
            log_warn(f"Could not modify {name}")
            failures += 1
            continue
        log_ok(f"{vm} single-homed on SECSCOPE.CORP")
        vbox(["startvm", name, "--type", "headless"])
        sealed += 1
    log("")
    log_ok(f"Seal complete - {sealed} VM(s) sealed, {failures} issue(s)")
    return 0 if failures == 0 else 1


def cmd_unseal(targets):
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
        if vm_running(vm):
            vbox(["controlvm", name, "poweroff"])
            time.sleep(5)
        vbox(["modifyvm", name, "--nic1", "nat"])
        log_ok(f"{vm} NAT nic1 restored")
        vbox(["startvm", name, "--type", "headless"])
    return 0


def cmd_destroy(targets, force=False):
    preflight()
    is_all = bool(targets) and len(targets) == 1 and targets[0].lower() == "all"
    vms = list(ALL_VMS) if is_all else resolve_targets(targets)
    if not confirm("destroy", vms, force):
        return 1
    if is_all:
        log_info("Destroying all VMs...")
        vagrant(["destroy", "-f"], filter_winrm=True)
        log_ok("All VMs destroyed")
        return 0
    for vm in vms:
        log_info(f"Destroying {vm}...")
        vagrant(["destroy", "-f", vm], filter_winrm=True)
    log_ok("Destroy complete")
    return 0


def cmd_build_boxes(opts):
    preflight()
    if shutil.which("packer") is None and (SCRIPT_DIR / "bin" / "packer").exists():
        os.environ["PATH"] = f"{SCRIPT_DIR / 'bin'}:{os.environ['PATH']}"
    for tool in ("packer", "vagrant", "VBoxManage", "sha256sum"):
        if shutil.which(tool) is None:
            raise LabError(f"{tool} not found in PATH")
    banner("AD Alligator Labs - Build Packer Boxes")

    build_server = not opts.get("workstation_only") and not opts.get("debian_only")
    build_win10 = not opts.get("server_only") and not opts.get("debian_only")
    # The Debian Packer box is NOT built by default: the preseed build is known
    # to hang (the installer runs but SSH never comes up -> ~2h Packer timeout)
    # and the resulting box is orphaned anyway - lin01 boots from the public
    # 'debian/bookworm64' box (see Vagrantfile), not 'secscope/debian-bookworm'.
    # Build it only on explicit request (--debian-only / --with-debian).
    build_debian = bool(opts.get("debian_only") or opts.get("with_debian"))
    if opts.get("debian_only"):
        build_server = build_win10 = False
        build_debian = True

    def build_one(name, box_name, iso, pkr_dir):
        if not Path(iso).exists():
            raise LabError(f"ISO not found: {iso}")
        log_info(f"Building {name} (ISO {iso})...")
        rc, checksum = run(["sha256sum", iso], capture=True)
        checksum = checksum.split()[0]
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
        build_one("debian-bookworm", "secscope/debian-bookworm",
                  opts.get("debian_iso") or str(iso_dir / "debian-12.15.0-amd64-netinst-preseed.iso"),
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
  setup.py rebuild ws01 --force        Destroy + rebuild only ws01
  setup.py status                      Show the state table
  setup.py harden all --force          Strip vagrant creds (after builds)
  setup.py seal all --force            Single-home every VM (final step)

vm inventory:
  DC01  192.168.200.10   DC02 192.168.200.11   DC03 192.168.200.12
  SRV01 192.168.200.20   WS01 192.168.200.30   WS02 192.168.200.31
  LIN01 192.168.200.40   (Kali 192.168.200.99)

notes:
  * Each VM can be built only ONCE; rebuilding requires 'rebuild' or --force.
  * You destroy machines yourself; 'destroy' exists but is not part of build.
  * 'harden' and 'seal' cut off Vagrant/WinRM management - run them last, and
    they require --force (or an interactive confirmation).
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
    p_seal.set_defaults(func=_run_seal)

    # ── unseal ──
    p_unseal = sub.add_parser(
        "unseal", parents=[globals_parent],
        help="Re-add NAT nic1 -> restore Vagrant/WinRM/RDP.",
        description="Re-add the NAT nic1 to restore management access.")
    _add_vms_argument(p_unseal)
    p_unseal.set_defaults(func=_run_unseal)

    # ── destroy ──
    p_destroy = sub.add_parser(
        "destroy", parents=[globals_parent],
        help="Destroy machine(s). Requires --force/confirm.",
        description="Destroy the given machine(s) or 'all'.")
    _add_vms_argument(p_destroy)
    p_destroy.add_argument("--force", action="store_true",
                           help="Skip the interactive confirmation.")
    p_destroy.set_defaults(func=_run_destroy)

    # ── build-boxes ──
    p_boxes = sub.add_parser(
        "build-boxes", parents=[globals_parent],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        help="Build Packer base boxes.",
        description="Build the Packer base boxes (Windows Server 2022 and "
                    "Windows 10 by default). The Debian box is NOT built by "
                    "default (broken/orphaned - lin01 uses debian/bookworm64); "
                    "pass --with-debian to build it anyway.")
    only = p_boxes.add_mutually_exclusive_group()
    only.add_argument("--server-only", action="store_true",
                      help="Build only the Windows Server 2022 box.")
    only.add_argument("--workstation-only", action="store_true",
                      help="Build only the Windows 10 box.")
    only.add_argument("--debian-only", action="store_true",
                      help="Build only the Debian box.")
    p_boxes.add_argument("--skip-debian", action="store_true",
                         help="Deprecated no-op: Debian is already skipped by default.")
    p_boxes.add_argument("--with-debian", action="store_true",
                         help="Also build the (experimental, orphaned) Debian box. "
                              "lin01 uses the public debian/bookworm64 box instead.")
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
                     max_parallel=args.max_parallel)


def _run_rebuild(args):
    global DISABLE_AV_UPDATE
    DISABLE_AV_UPDATE = getattr(args, "disable_av_update", False)
    return cmd_build(args.vms, force=True, parallel=args.parallel,
                     max_parallel=args.max_parallel, rebuild=True)


def _run_status(args):
    return cmd_status(args.vms or None)


def _run_harden(args):
    return cmd_harden(args.vms, force=args.force)


def _run_seal(args):
    return cmd_seal(args.vms, force=args.force)


def _run_unseal(args):
    return cmd_unseal(args.vms)


def _run_destroy(args):
    return cmd_destroy(args.vms, force=args.force)


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
