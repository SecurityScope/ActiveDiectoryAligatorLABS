#!/bin/bash

START_TIME=$(date +%s)
EXECUTED_STEPS=()
SKIPPED_STEPS=()

# ── Check functions ────────────────────────────────────

check_dc01_base() {
    vagrant status dc01 2>/dev/null | grep -q "running"
}

check_dc01_postboot() {
    vagrant winrm dc01 -c "Get-ADDomain" 2>/dev/null | grep -q "secscope"
}

check_dc01_dns() {
    vagrant winrm dc01 -c "Get-DnsServerZone secscope.corp" 2>/dev/null | grep -q "secscope"
}

check_dc01_objects_base() {
    vagrant winrm dc01 -c "Get-ADUser anakin" 2>/dev/null | grep -q "anakin"
}

check_dc01_objects() {
    vagrant winrm dc01 -c \
        "Get-ADComputer WS01 -Properties msDS-AllowedToActOnBehalfOfOtherIdentity" \
        2>/dev/null | grep -q "WS01"
}

check_dc02_base() {
    vagrant status dc02 2>/dev/null | grep -q "running"
}

check_dc02_join() {
    vagrant winrm dc02 -c "Get-ADDomainController" 2>/dev/null | grep -q "DC02"
}

check_dc03_base() {
    vagrant status dc03 2>/dev/null | grep -q "running"
}

check_dc03_join() {
    vagrant winrm dc03 -c "Get-ADDomain" 2>/dev/null | grep -q "it"
}

check_srv01_base() {
    vagrant status srv01 2>/dev/null | grep -q "running"
}

check_ws01_base() {
    vagrant status ws01 2>/dev/null | grep -q "running"
}

check_ws02_base() {
    vagrant status ws02 2>/dev/null | grep -q "running"
}

check_lin01_base() {
    vagrant status lin01 2>/dev/null | grep -q "running"
}

check_srv01_services() {
    vagrant winrm srv01 -c "Get-WindowsFeature Web-Server" 2>/dev/null | grep -q "Installed"
}

check_ws01_misconfig() {
    vagrant winrm ws01 -c "Get-LocalUser localadmin" 2>/dev/null | grep -q "localadmin"
}

check_ws02_misconfig() {
    vagrant winrm ws02 -c "Get-LocalUser localadmin" 2>/dev/null | grep -q "localadmin"
}

check_hardened() {
    local vm=$1
    vagrant winrm "$vm" -c "Get-LocalUser vagrant | Select-Object Enabled" \
        2>/dev/null | grep -q "False"
}

# ── Help / Status functions ────────────────────────────

show_help() {
    echo "╔══════════════════════════════════════════╗"
    echo "║  Active Directory Alligator Labs — Setup ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo "USAGE:"
    echo "  ./setup.sh [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help        Show this help message"
    echo "  --build           Run full lab build (resumes if interrupted)"
    echo "  --destroy         Destroy all VMs and exit (does NOT rebuild)"
    echo "  --dc01-only       Build DC01 only"
    echo "  --no-misconfig    Skip misconfigurations step"
    echo "  --status          Show current state of all VMs"
    echo ""
    echo "EXAMPLES:"
    echo "  ./setup.sh                      Full build (resumes if interrupted)"
    echo "  ./setup.sh --build              Same as above"
    echo "  ./setup.sh --destroy            Destroy all VMs and exit"
    echo "  ./setup.sh --destroy && ./setup.sh --build  Destroy then rebuild"
    echo "  ./setup.sh --status             Check VM states"
    echo "  ./setup.sh --dc01-only          Build DC01 only"
    echo ""
    echo "VM INVENTORY:"
    echo "  DC01   192.168.200.10   Primary Domain Controller"
    echo "  DC02   192.168.200.11   Secondary Domain Controller"
    echo "  DC03   192.168.200.12   Subdomain Controller (it.secscope.corp)"
    echo "  SRV01  192.168.200.20   MSSQL + IIS + ADCS"
    echo "  WS01   192.168.200.30   Workstation 1"
    echo "  WS02   192.168.200.31   Workstation 2"
    echo "  LIN01  192.168.200.40   Linux Domain Member"
    echo ""
    echo "CREDENTIALS:"
    echo "  Domain Admin:  SECSCOPE\\Administrator / SecScope2024!"
    echo "  Vagrant:       vagrant / vagrant (all VMs)"
    echo ""
    echo "TOTAL BUILD TIME: approximately 90-120 minutes"
}

show_status() {
    echo "╔══════════════════════════════════════════╗"
    echo "║       AD Alligator Labs VM Status        ║"
    echo "╚══════════════════════════════════════════╝"
    for vm in dc01 dc02 dc03 srv01 ws01 ws02 lin01; do
        status=$(vagrant status "$vm" 2>/dev/null | grep "$vm" | awk '{print $2}')
        printf "  %-8s %s\n" "$vm" "$status"
    done
}

# ── Argument parsing ───────────────────────────────────

DESTROY=false
DC01_ONLY=false
NO_MISCONFIG=false
STATUS_ONLY=false
BUILD=false

for arg in "$@"; do
    case $arg in
        -h|--help)
            show_help
            exit 0
            ;;
        --destroy)
            DESTROY=true
            ;;
        --build)
            BUILD=true
            ;;
        --dc01-only)
            DC01_ONLY=true
            ;;
        --no-misconfig)
            NO_MISCONFIG=true
            ;;
        --status)
            STATUS_ONLY=true
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run './setup.sh --help' for usage"
            exit 1
            ;;
    esac
done

if [ "$STATUS_ONLY" = true ]; then
    show_status
    exit 0
fi

if [ "$DESTROY" = true ]; then
    echo "[!] Destroying all VMs..."
    vagrant destroy -f
    echo "[✓] All VMs destroyed."
    exit 0
fi

# ── Banner ─────────────────────────────────────────────

echo "╔══════════════════════════════════════════╗"
echo "║  Active Directory Alligator Labs — Setup ║"
echo "╚══════════════════════════════════════════╝"

# ── Pre-flight checks ─────────────────────────────────

echo ""
echo "[0] Checking requirements..."
if ! command -v vagrant &>/dev/null; then
    echo "ERROR: vagrant not found. Install Vagrant first."
    exit 1
fi
if ! command -v VBoxManage &>/dev/null; then
    echo "ERROR: VBoxManage not found. Install VirtualBox first."
    exit 1
fi
echo "    vagrant and VBoxManage found"

# ── Step 1 — DC01 base ─────────────────────────────────

echo ""
echo "[1/16] DC01 base setup..."
if check_dc01_base; then
    echo "    [✓] DC01 already running — skipping"
    SKIPPED_STEPS+=("DC01 base")
else
    vagrant up dc01 || { echo "ERROR: vagrant up dc01 failed"; exit 1; }
    EXECUTED_STEPS+=("DC01 base")
fi

# ── Step 2 — DC01 postboot ─────────────────────────────

echo ""
echo "[2/16] DC01 AD promotion..."
if check_dc01_postboot; then
    echo "    [✓] DC01 already a DC — skipping postboot and reload"
    SKIPPED_STEPS+=("DC01 postboot")
else
    vagrant provision dc01 --provision-with postboot 2>&1 | \
        grep -v "WinRMAuthorizationError" | \
        grep -v "WinRMHTTPTransportError" | \
        grep -v "raise_if_auth_error" | \
        grep -v "response_handler.rb" | \
        grep -v "transport.rb" | \
        grep -v "power_shell.rb" | \
        grep -v "elevated.rb" | \
        grep -v "communicator.rb" | \
        grep -v "provisioner.rb" | \
        grep -v "from /home" | \
        grep -v "AuthenticationFailed" | \
        grep -v "wsman" || true
    echo "    Waiting 120s for AD to initialize..."
    sleep 120
    vagrant reload dc01 --force
    EXECUTED_STEPS+=("DC01 postboot")
fi

# ── Step 3 — DC01 DNS ──────────────────────────────────

echo ""
echo "[3/16] DC01 DNS configuration..."
if check_dc01_dns; then
    echo "    [✓] DNS already configured — skipping"
    SKIPPED_STEPS+=("DC01 DNS")
else
    vagrant provision dc01 --provision-with dns || { echo "ERROR: dns provision failed"; exit 1; }
    EXECUTED_STEPS+=("DC01 DNS")
fi

# ── Step 4 — DC01 objects (first pass) ─────────────────

echo ""
echo "[4/16] DC01 AD objects — base (users, groups, OUs)..."
if check_dc01_objects_base; then
    echo "    [✓] Base objects already exist — skipping"
    SKIPPED_STEPS+=("DC01 objects (base)")
else
    vagrant provision dc01 --provision-with objects-base || { echo "ERROR: objects-base provision failed"; exit 1; }
    EXECUTED_STEPS+=("DC01 objects (base)")
fi

if [ "$DC01_ONLY" = true ]; then
    echo ""
    echo "[!] --dc01-only flag set — stopping after DC01 build"
    SKIPPED_STEPS+=("DC02 base" "DC02 join" "DC03 base" "DC03 join" "SRV01 base" "WS01 base" "WS02 base" "LIN01 base" "SRV01 services" "WS01 misconfig" "WS02 misconfig" "DC01 objects (final)" "Harden")
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    MINUTES=$((ELAPSED / 60))
    SECONDS=$((ELAPSED % 60))
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║          DC01 Build Complete             ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    printf "  Total time: %dm %ds\n" "$MINUTES" "$SECONDS"
    exit 0
fi

# ── Step 5 — DC02 base ─────────────────────────────────

echo ""
echo "[5/16] DC02 base setup..."
if check_dc02_base; then
    echo "    [✓] DC02 already running — skipping"
    SKIPPED_STEPS+=("DC02 base")
else
    vagrant up dc02 || { echo "ERROR: vagrant up dc02 failed"; exit 1; }
    EXECUTED_STEPS+=("DC02 base")
fi

# ── Step 6 — DC02 join ─────────────────────────────────

echo ""
echo "[6/16] DC02 domain join..."
if check_dc02_join; then
    echo "    [✓] DC02 already a DC — skipping join"
    SKIPPED_STEPS+=("DC02 join")
else
    vagrant provision dc02 --provision-with join || true
    sleep 90
    EXECUTED_STEPS+=("DC02 join")
fi

# ── Step 7 — DC03 base ─────────────────────────────────

echo ""
echo "[7/16] DC03 base setup..."
if check_dc03_base; then
    echo "    [✓] DC03 already running — skipping"
    SKIPPED_STEPS+=("DC03 base")
else
    vagrant up dc03 || { echo "ERROR: vagrant up dc03 failed"; exit 1; }
    EXECUTED_STEPS+=("DC03 base")
fi

# ── Step 8 — DC03 join ─────────────────────────────────

echo ""
echo "[8/16] DC03 domain join..."
if check_dc03_join; then
    echo "    [✓] DC03 already a DC — skipping join"
    SKIPPED_STEPS+=("DC03 join")
else
    vagrant provision dc03 --provision-with join || true
    sleep 90
    EXECUTED_STEPS+=("DC03 join")
fi

# ── Step 9 — SRV01 base ────────────────────────────────

echo ""
echo "[9/16] SRV01 base setup..."
if check_srv01_base; then
    echo "    [✓] SRV01 already running — skipping"
    SKIPPED_STEPS+=("SRV01 base")
else
    vagrant up srv01 || { echo "ERROR: vagrant up srv01 failed"; exit 1; }
    EXECUTED_STEPS+=("SRV01 base")
fi

# ── Step 10 — WS01 base ────────────────────────────────

echo ""
echo "[10/16] WS01 base setup..."
if check_ws01_base; then
    echo "    [✓] WS01 already running — skipping"
    SKIPPED_STEPS+=("WS01 base")
else
    vagrant up ws01 || { echo "ERROR: vagrant up ws01 failed"; exit 1; }
    EXECUTED_STEPS+=("WS01 base")
fi

# ── Step 11 — WS02 base ────────────────────────────────

echo ""
echo "[11/16] WS02 base setup..."
if check_ws02_base; then
    echo "    [✓] WS02 already running — skipping"
    SKIPPED_STEPS+=("WS02 base")
else
    vagrant up ws02 || { echo "ERROR: vagrant up ws02 failed"; exit 1; }
    EXECUTED_STEPS+=("WS02 base")
fi

# ── Step 12 — LIN01 base ───────────────────────────────

echo ""
echo "[12/16] LIN01 base setup..."
if check_lin01_base; then
    echo "    [✓] LIN01 already running — skipping"
    SKIPPED_STEPS+=("LIN01 base")
else
    vagrant up lin01 || { echo "ERROR: vagrant up lin01 failed"; exit 1; }
    EXECUTED_STEPS+=("LIN01 base")
fi

# ── Step 13 — SRV01 services ───────────────────────────

if [ "$NO_MISCONFIG" = true ]; then
    echo ""
    echo "[13/16] SRV01 services..."
    echo "    [✓] --no-misconfig set — skipping"
    SKIPPED_STEPS+=("SRV01 services")
else
    echo ""
    echo "[13/16] SRV01 services..."
    if check_srv01_services; then
        echo "    [✓] SRV01 services already configured — skipping"
        SKIPPED_STEPS+=("SRV01 services")
    else
        vagrant provision srv01 --provision-with services || { echo "ERROR: srv01 services failed"; exit 1; }
        EXECUTED_STEPS+=("SRV01 services")
    fi
fi

# ── Step 14 — WS01 misconfig ───────────────────────────

if [ "$NO_MISCONFIG" = true ]; then
    echo ""
    echo "[14/16] WS01 misconfigurations..."
    echo "    [✓] --no-misconfig set — skipping"
    SKIPPED_STEPS+=("WS01 misconfig")
else
    echo ""
    echo "[14/16] WS01 misconfigurations..."
    if check_ws01_misconfig; then
        echo "    [✓] WS01 already misconfigured — skipping"
        SKIPPED_STEPS+=("WS01 misconfig")
    else
        vagrant provision ws01 --provision-with misconfig || { echo "ERROR: ws01 misconfig failed"; exit 1; }
        EXECUTED_STEPS+=("WS01 misconfig")
    fi
fi

# ── Step 15 — WS02 misconfig ───────────────────────────

if [ "$NO_MISCONFIG" = true ]; then
    echo ""
    echo "[15/16] WS02 misconfigurations..."
    echo "    [✓] --no-misconfig set — skipping"
    SKIPPED_STEPS+=("WS02 misconfig")
else
    echo ""
    echo "[15/16] WS02 misconfigurations..."
    if check_ws02_misconfig; then
        echo "    [✓] WS02 already misconfigured — skipping"
        SKIPPED_STEPS+=("WS02 misconfig")
    else
        vagrant provision ws02 --provision-with misconfig || { echo "ERROR: ws02 misconfig failed"; exit 1; }
        EXECUTED_STEPS+=("WS02 misconfig")
    fi
fi

# ── Step 16 — DC01 objects (final pass) ────────────────

echo ""
echo "[16/16] DC01 AD objects (final pass)..."
if check_dc01_objects; then
    echo "    [✓] AD objects final pass already done — skipping"
    SKIPPED_STEPS+=("DC01 objects (final)")
else
    vagrant provision dc01 --provision-with objects || { echo "ERROR: final objects provision failed"; exit 1; }
    EXECUTED_STEPS+=("DC01 objects (final)")
fi

# ── Step 17 — Hardening ────────────────────────────────

echo ""
echo "[17/17] Hardening — removing default vagrant credentials..."
if check_hardened dc01; then
    echo "    [✓] Already hardened — skipping"
    SKIPPED_STEPS+=("Harden")
else
    for vm in dc01 dc02 dc03 srv01 ws01 ws02; do
        echo "    Hardening $vm..."
        vagrant provision "$vm" --provision-with harden
    done
    echo "    [✓] Hardening complete"
    EXECUTED_STEPS+=("Harden")
fi

# ── Summary ────────────────────────────────────────────

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║              Setup Summary               ║"
echo "╚══════════════════════════════════════════╝"
echo ""
printf "  Total time: %dm %ds\n" "$MINUTES" "$SECONDS"
echo ""
echo "  Steps executed:"
if [ ${#EXECUTED_STEPS[@]} -eq 0 ]; then
    echo "    (none)"
else
    for step in "${EXECUTED_STEPS[@]}"; do
        echo "    • $step"
    done
fi
echo ""
echo "  Steps skipped (already done):"
if [ ${#SKIPPED_STEPS[@]} -eq 0 ]; then
    echo "    (none)"
else
    for step in "${SKIPPED_STEPS[@]}"; do
        echo "    • $step"
    done
fi
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        Lab fully built and ready!        ║"
echo "╚══════════════════════════════════════════╝"
