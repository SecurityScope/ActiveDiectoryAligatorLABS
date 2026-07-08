#!/bin/bash
set -o pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Active Directory Alligator Labs — Unified Setup Orchestrator
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────

ADMIN_PASS="${ADMIN_PASS:-SecScope2024!}"
SERVER_ISO="${SERVER_ISO:-${SCRIPT_DIR}/iso/SERVER_EVAL_x64FRE_en-us.iso}"
WIN10_ISO="${WIN10_ISO:-${SCRIPT_DIR}/iso/Win10_22H2_English_x64v1.iso}"

DOMAIN="secscope.corp"
DC01_IP="192.168.200.10"
DC02_IP="192.168.200.11"
DC03_IP="192.168.200.12"
SRV01_IP="192.168.200.20"
WS01_IP="192.168.200.30"
WS02_IP="192.168.200.31"
LIN01_IP="192.168.200.40"

ALL_WINDOWS_VMS=(dc01 dc02 dc03 srv01 ws01 ws02)
ALL_DCS=(dc01 dc02 dc03)
ALL_MEMBERS=(srv01 ws01 ws02 lin01)
ALL_VMS=(dc01 dc02 dc03 srv01 ws01 ws02 lin01)

START_TIME=$(date +%s)
EXECUTED_STEPS=()
SKIPPED_STEPS=()
export DC_WINRM_PASSWORD="$ADMIN_PASS"

# ── Verbosity ──────────────────────────────────────────────────────────────

VERBOSE=false
QUIET=false
DEBUG=false
LOG_FILE=""
NO_COLOR=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()       { echo -e "$*"; }
log_ok()    { echo -e "    ${GREEN}[OK]${NC} $*"; }
log_skip()  { echo -e "    ${YELLOW}[SKIP]${NC} $*"; }
log_warn()  { echo -e "    ${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "    ${RED}[ERROR]${NC} $*"; }
log_info()  { echo -e "    ${CYAN}[*]${NC} $*"; }

log_verbose() {
    if [ "$QUIET" = false ]; then
        echo -e "$*"
    fi
}

log_step() {
    echo ""
    echo -e "${CYAN}$1${NC}"
}

# Suppress WinRM stack traces unless --debug
filter_winrm() {
    if [ "$DEBUG" = true ] || [ "$VERBOSE" = true ]; then
        cat
    else
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
    fi
}

run_vagrant() {
    if [ "$QUIET" = true ]; then
        "$@" 2>&1 | filter_winrm > /dev/null
        return ${PIPESTATUS[0]}
    elif [ "$VERBOSE" = true ] || [ "$DEBUG" = true ]; then
        "$@" 2>&1 | filter_winrm
        return ${PIPESTATUS[0]}
    else
        "$@" 2>&1 | filter_winrm
        return ${PIPESTATUS[0]}
    fi
}

# ── Config / VM selection ──────────────────────────────────────────────────

SELECTED_VMS=()
SKIP_SERVICES=false
SKIP_MISCONFIG=false
SKIP_HARDENING=false
SKIP_LINUX=false
DC01_ONLY=false
SKIP_VAGRANT_ADD=false
BUILD_SERVER=true
BUILD_WIN10=true

# ── Check functions ────────────────────────────────────────────────────────

check_running() {
    vagrant status "$1" 2>/dev/null | grep -q "running"
}

check_dc01_postboot() {
    vagrant winrm dc01 -c "Get-ADDomain" 2>/dev/null | grep -q "secscope"
}

check_dc01_dns() {
    DC_WINRM_PASSWORD="$ADMIN_PASS" vagrant winrm dc01 -c \
        "Get-DnsServerZone 200.168.192.in-addr.arpa" 2>/dev/null | grep -q "200.168.192"
}

check_dc01_objects_base() {
    vagrant winrm dc01 -c "Get-ADUser anakin" 2>/dev/null | grep -q "anakin"
}

check_dc01_objects() {
    DC_WINRM_PASSWORD="$ADMIN_PASS" vagrant winrm dc01 -c \
        "Get-ADComputer WS01 -Properties msDS-AllowedToActOnBehalfOfOtherIdentity" \
        2>/dev/null | grep -q "WS01"
}

check_dc02_join() {
    DC_WINRM_PASSWORD="$ADMIN_PASS" vagrant winrm dc02 -c "Get-ADDomainController" 2>/dev/null | grep -q "DC02"
}

check_dc03_join() {
    DC_WINRM_PASSWORD="$ADMIN_PASS" vagrant winrm dc03 -c "Get-ADDomain" 2>/dev/null | grep -q "it"
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

ensure_adws() {
    local vm=$1
    for i in $(seq 1 6); do
        sleep 3
        local status
        status=$(vagrant winrm "$vm" -c "Get-Service ADWS | Select -Expand Status" 2>/dev/null | tr -d '\r')
        if [ "$status" = "Running" ]; then
            log_ok "ADWS running on $vm"
            return 0
        fi
        if [ "$status" = "Stopped" ]; then
            log_info "Enabling ADWS on $vm..."
            vagrant winrm "$vm" -c "Set-Service ADWS -StartupType Automatic; Start-Service ADWS" 2>/dev/null
            sleep 3
        fi
        log_verbose "    ADWS on $vm: attempt $i/6 ($status)"
    done
    log_warn "ADWS not running on $vm after 18s"
    return 1
}

# ── Pre-flight ─────────────────────────────────────────────────────────────

preflight() {
    log_step "[0] Checking requirements..."
    if ! command -v vagrant &>/dev/null; then
        echo "ERROR: vagrant not found. Install Vagrant first."
        exit 1
    fi
    if ! command -v VBoxManage &>/dev/null; then
        echo "ERROR: VBoxManage not found. Install VirtualBox first."
        exit 1
    fi
    log_ok "vagrant and VBoxManage found"
}

# ── Subcommand: build-boxes ────────────────────────────────────────────────

cmd_build_boxes() {
    echo "╔══════════════════════════════════════════╗"
    echo "║  AD Alligator Labs — Build Packer Boxes  ║"
    echo "╚══════════════════════════════════════════╝"

    # Pre-flight for packer
    if ! command -v packer &>/dev/null && [ -x "$SCRIPT_DIR/bin/packer" ]; then
        export PATH="$SCRIPT_DIR/bin:$PATH"
        log_info "Using bundled packer: $SCRIPT_DIR/bin/packer"
    fi
    for tool in packer vagrant VBoxManage sha256sum; do
        if ! command -v $tool &>/dev/null; then
            echo "ERROR: $tool not found in PATH"
            exit 1
        fi
        log_ok "$tool found"
    done

    # Clean up leftover VMs
    log_info "Cleaning previous build artifacts..."
    VBoxManage unregistervm packer-windows-server-2022 --delete 2>/dev/null || true
    VBoxManage unregistervm packer-windows-10 --delete 2>/dev/null || true
    rm -rf "$HOME/VirtualBox VMs/packer-windows-server-2022" 2>/dev/null || true
    rm -rf "$HOME/VirtualBox VMs/packer-windows-10" 2>/dev/null || true
    log_ok "Cleanup done"

    mkdir -p "$SCRIPT_DIR/boxes"

    local build_start=$(date +%s)

    # ── Build Windows Server 2022 ──
    if [ "$BUILD_SERVER" = true ]; then
        echo ""
        echo "[1] Building Windows Server 2022 box..."
        if [ ! -f "$SERVER_ISO" ]; then
            echo "ERROR: ISO not found at: $SERVER_ISO"
            echo "  Place your ISO in iso/ or set: export SERVER_ISO=/path/to/your.iso"
            exit 1
        fi
        log_info "ISO: $SERVER_ISO"
        log_info "Calculating checksum..."
        local srv_checksum
        srv_checksum=$(sha256sum "$SERVER_ISO" | cut -d' ' -f1)
        log_info "SHA256: $srv_checksum"
        echo "    Starting Packer build (45-90 minutes)..."

        packer init "$SCRIPT_DIR/packer/windows-server-2022/" 2>/dev/null || true
        packer build \
            -var "iso_path=$SERVER_ISO" \
            -var "iso_checksum=$srv_checksum" \
            "$SCRIPT_DIR/packer/windows-server-2022/windows-server-2022.pkr.hcl"
        if [ $? -ne 0 ]; then
            echo "ERROR: Packer build failed for Windows Server 2022"
            exit 1
        fi

        if [ "$SKIP_VAGRANT_ADD" = false ]; then
            log_info "Adding to Vagrant..."
            vagrant box remove secscope/windows-server-2022 --force 2>/dev/null || true
            vagrant box add --name secscope/windows-server-2022 \
                "$SCRIPT_DIR/packer/boxes/windows-server-2022.box"
            log_ok "Windows Server 2022 box added to Vagrant"
        fi
    fi

    # ── Build Windows 10 ──
    if [ "$BUILD_WIN10" = true ]; then
        echo ""
        echo "[2] Building Windows 10 box..."
        if [ ! -f "$WIN10_ISO" ]; then
            echo "ERROR: ISO not found at: $WIN10_ISO"
            echo "  Place your ISO in iso/ or set: export WIN10_ISO=/path/to/your.iso"
            exit 1
        fi
        log_info "ISO: $WIN10_ISO"
        log_info "Calculating checksum..."
        local win10_checksum
        win10_checksum=$(sha256sum "$WIN10_ISO" | cut -d' ' -f1)
        log_info "SHA256: $win10_checksum"
        echo "    Starting Packer build (45-90 minutes)..."

        packer init "$SCRIPT_DIR/packer/windows-10/" 2>/dev/null || true
        packer build \
            -var "iso_path=$WIN10_ISO" \
            -var "iso_checksum=$win10_checksum" \
            "$SCRIPT_DIR/packer/windows-10/windows-10.pkr.hcl"
        if [ $? -ne 0 ]; then
            echo "ERROR: Packer build failed for Windows 10"
            exit 1
        fi

        if [ "$SKIP_VAGRANT_ADD" = false ]; then
            log_info "Adding to Vagrant..."
            vagrant box remove secscope/windows-10 --force 2>/dev/null || true
            vagrant box add --name secscope/windows-10 \
                "$SCRIPT_DIR/packer/boxes/windows-10.box"
            log_ok "Windows 10 box added to Vagrant"
        fi
    fi

    local build_end=$(date +%s)
    local build_elapsed=$(( (build_end - build_start) / 60 ))
    echo ""
    echo "All boxes built in ${build_elapsed} minutes."
}

# ── Subcommand: status ─────────────────────────────────────────────────────

cmd_status() {
    echo "╔══════════════════════════════════════════╗"
    echo "║       AD Alligator Labs VM Status        ║"
    echo "╚══════════════════════════════════════════╝"
    for vm in "${ALL_VMS[@]}"; do
        local status
        status=$(vagrant status "$vm" 2>/dev/null | grep "$vm" | awk '{print $2}')
        printf "  %-8s %s\n" "$vm" "$status"
    done
}

# ── Subcommand: destroy ────────────────────────────────────────────────────

cmd_destroy() {
    echo "[!] Destroying all VMs..."
    vagrant destroy -f
    echo "[OK] All VMs destroyed."
}

# ── Subcommand: deploy ─────────────────────────────────────────────────────

vm_selected() {
    local vm=$1
    if [ ${#SELECTED_VMS[@]} -eq 0 ]; then
        return 0
    fi
    for s in "${SELECTED_VMS[@]}"; do
        [ "$s" = "$vm" ] && return 0
    done
    return 1
}

# ── Step 1: DC01 base ──
step_dc01_base() {
    log_step "[1/14] DC01 base setup..."
    if check_running dc01; then
        log_skip "DC01 already running"
        SKIPPED_STEPS+=("DC01 base")
        return
    fi
    run_vagrant vagrant up dc01 || { log_err "vagrant up dc01 failed"; exit 1; }
    EXECUTED_STEPS+=("DC01 base")
}

# ── Step 2: DC01 postboot ──
step_dc01_postboot() {
    log_step "[2/14] DC01 AD promotion..."
    if check_dc01_postboot; then
        log_skip "DC01 already a DC"
        SKIPPED_STEPS+=("DC01 postboot")
        return
    fi
    log_verbose "    (WinRM errors during AD DS promotion are expected)"
    run_vagrant vagrant provision dc01 --provision-with postboot

    log_info "Rebooting DC01 to finalize promotion..."
    vagrant reload dc01 --force

    log_info "Polling for AD to initialize..."
    local ready=false
    for i in $(seq 1 24); do
        sleep 5
        if vagrant winrm dc01 -c "Get-ADDomain" 2>/dev/null | grep -q "secscope"; then
            log_ok "AD ready after $((i*5))s"
            ready=true
            break
        fi
        log_verbose "    ... attempt $i/24"
    done
    if [ "$ready" = false ]; then
        log_err "AD did not initialize within 120s"
        exit 1
    fi
    log_info "Triggering NLA re-detection on DC01..."
    vagrant winrm dc01 -c "Restart-Service NlaSvc -Force; Start-Sleep 5" 2>/dev/null || true
    log_ok "DC01 network profile re-evaluated"
    ensure_adws dc01
    EXECUTED_STEPS+=("DC01 postboot")
}

# ── Step 3: DC01 DNS ──
step_dc01_dns() {
    log_step "[3/14] DC01 DNS configuration..."
    if check_dc01_dns; then
        log_skip "DNS already configured"
        SKIPPED_STEPS+=("DC01 DNS")
    else
        run_vagrant vagrant provision dc01 --provision-with dns || { log_err "dns provision failed"; exit 1; }
        EXECUTED_STEPS+=("DC01 DNS")
    fi

    log_info "Cleaning stale NAT DNS records..."
    vagrant winrm dc01 -c '
$zone = "secscope.corp"
Get-DnsServerResourceRecord -ZoneName $zone -RRType A -ErrorAction SilentlyContinue | ForEach-Object {
    $ip = $_.RecordData.IPv4Address.IPAddressToString
    if ($ip -like "10.0.2.*") {
        Write-Host "Removing: $($_.HostName) -> $ip"
        dnscmd localhost /RecordDelete $zone $($_.HostName) A $ip /f 2>&1 | Out-Null
    }
}
Get-DnsServerResourceRecord -ZoneName $zone -RRType AAAA -ErrorAction SilentlyContinue | ForEach-Object {
    dnscmd localhost /RecordDelete $zone $($_.HostName) AAAA $($_.RecordData.IPv6Address.IPAddressToString) /f 2>&1 | Out-Null
}
' 2>/dev/null || true
    log_ok "NAT DNS cleanup done"
}

# ── Step 4: DC01 objects base ──
step_dc01_objects_base() {
    log_step "[4/14] DC01 AD objects — base (users, groups, OUs)..."
    if check_dc01_objects_base; then
        log_skip "Base objects already exist"
        SKIPPED_STEPS+=("DC01 objects (base)")
        return
    fi
    run_vagrant vagrant provision dc01 --provision-with objects-base || { log_err "objects-base failed"; exit 1; }
    EXECUTED_STEPS+=("DC01 objects (base)")
}

# ── Step 5: Boot remaining VMs in parallel ──
step_boot_remaining() {
    log_step "[5/14] Booting remaining VMs in parallel..."
    local to_boot=()
    for vm in "${ALL_MEMBERS[@]}" "${ALL_DCS[@]}"; do
        [ "$vm" = "dc01" ] && continue
        if ! vm_selected "$vm"; then continue; fi
        if [ "$vm" = "lin01" ] && [ "$SKIP_LINUX" = true ]; then continue; fi
        if ! check_running "$vm"; then
            to_boot+=("$vm")
        else
            log_skip "$vm already running"
        fi
    done

    if [ ${#to_boot[@]} -eq 0 ]; then
        log_skip "All VMs already running"
        SKIPPED_STEPS+=("Boot remaining VMs")
        return
    fi

    declare -A pids
    local failures=0
    for vm in "${to_boot[@]}"; do
        log_info "Booting $vm..."
        vagrant up "$vm" &
        pids[$vm]=$!
    done
    for vm in "${to_boot[@]}"; do
        wait ${pids[$vm]} || { log_err "vagrant up $vm failed"; ((failures++)); }
    done
    if [ $failures -gt 0 ]; then
        log_err "$failures VM(s) failed to boot"
        exit 1
    fi
    log_ok "All VMs booted"
    EXECUTED_STEPS+=("Boot remaining VMs")
}

# ── Step 6+7: DC02 + DC03 joins in parallel ──
step_dc_joins() {
    local join_pids=()
    local join_failures=0

    if vm_selected dc02; then
        log_step "[6/14] DC02 domain join... (parallel with DC03)"
        if check_dc02_join; then
            log_skip "DC02 already a DC"
            SKIPPED_STEPS+=("DC02 join")
        else
            (
                vagrant provision dc02 --provision-with join 2>&1 | filter_winrm || true
                vagrant reload dc02 --force
                for i in $(seq 1 24); do
                    sleep 5
                    if vagrant winrm dc02 -c "(Get-CimInstance Win32_ComputerSystem).DomainRole" 2>/dev/null | grep -qE "[45]"; then
                        log_ok "DC02 ready after $((i*5))s"
                        vagrant winrm dc02 -c "Restart-Service NlaSvc -Force; Start-Sleep 5" 2>/dev/null || true
                        log_ok "DC02 network profile re-evaluated"
                        break
                    fi
                    log_verbose "    DC02 attempt $i/24..."
                done
                ensure_adws dc02
            ) &
            join_pids+=($!)
        fi
    fi

    if vm_selected dc03; then
        log_step "[7/14] DC03 domain join... (parallel with DC02)"
        if check_dc03_join; then
            log_skip "DC03 already a DC"
            SKIPPED_STEPS+=("DC03 join")
        else
            (
                vagrant provision dc03 --provision-with join 2>&1 | filter_winrm || true
                vagrant reload dc03 --force
                for i in $(seq 1 24); do
                    sleep 5
                    if vagrant winrm dc03 -c "(Get-CimInstance Win32_ComputerSystem).DomainRole" 2>/dev/null | grep -qE "[45]"; then
                        log_ok "DC03 ready after $((i*5))s"
                        vagrant winrm dc03 -c "Restart-Service NlaSvc -Force; Start-Sleep 5" 2>/dev/null || true
                        log_ok "DC03 network profile re-evaluated"
                        break
                    fi
                    log_verbose "    DC03 attempt $i/24..."
                done
                ensure_adws dc03
            ) &
            join_pids+=($!)
        fi
    fi

    for pid in "${join_pids[@]}"; do
        wait $pid || { log_err "DC join step failed"; ((join_failures++)); }
    done
    if [ $join_failures -gt 0 ]; then
        log_err "$join_failures DC join(s) failed"
        exit 1
    fi
    [ " ${SKIPPED_STEPS[*]} " != *" DC02 join "* ] && EXECUTED_STEPS+=("DC02 join")
    [ " ${SKIPPED_STEPS[*]} " != *" DC03 join "* ] && EXECUTED_STEPS+=("DC03 join")
}

# ── Step 8+9+10: SRV01 services, WS01/WS02 misconfig in parallel ──
step_member_provisioning() {
    local prov_pids=()
    local prov_failures=0

    # SRV01 services
    if vm_selected srv01 && [ "$SKIP_SERVICES" = false ]; then
        log_step "[8/14] SRV01 services... (parallel with WS01/WS02)"
        if check_srv01_services; then
            log_skip "SRV01 services already configured"
            SKIPPED_STEPS+=("SRV01 services")
        else
            (
                vagrant provision srv01 --provision-with services 2>&1 | filter_winrm
            ) &
            prov_pids+=($!)
        fi
    else
        log_skip "SRV01 services"
        SKIPPED_STEPS+=("SRV01 services")
    fi

    # WS01 misconfig
    if vm_selected ws01 && [ "$SKIP_MISCONFIG" = false ]; then
        log_step "[9/14] WS01 misconfigurations... (parallel)"
        if check_ws01_misconfig; then
            log_skip "WS01 already misconfigured"
            SKIPPED_STEPS+=("WS01 misconfig")
        else
            (
                vagrant provision ws01 --provision-with misconfig 2>&1 | filter_winrm
            ) &
            prov_pids+=($!)
        fi
    else
        log_skip "WS01 misconfig"
        SKIPPED_STEPS+=("WS01 misconfig")
    fi

    # WS02 misconfig
    if vm_selected ws02 && [ "$SKIP_MISCONFIG" = false ]; then
        log_step "[10/14] WS02 misconfigurations... (parallel)"
        if check_ws02_misconfig; then
            log_skip "WS02 already misconfigured"
            SKIPPED_STEPS+=("WS02 misconfig")
        else
            (
                vagrant provision ws02 --provision-with misconfig 2>&1 | filter_winrm
            ) &
            prov_pids+=($!)
        fi
    else
        log_skip "WS02 misconfig"
        SKIPPED_STEPS+=("WS02 misconfig")
    fi

    for pid in "${prov_pids[@]}"; do
        wait $pid || { log_err "Member provisioning step failed"; ((prov_failures++)); }
    done
    if [ $prov_failures -gt 0 ]; then
        log_err "$prov_failures provisioning step(s) failed"
        exit 1
    fi
    [ " ${SKIPPED_STEPS[*]} " != *" SRV01 services "* ] && EXECUTED_STEPS+=("SRV01 services")
    [ " ${SKIPPED_STEPS[*]} " != *" WS01 misconfig "* ] && EXECUTED_STEPS+=("WS01 misconfig")
    [ " ${SKIPPED_STEPS[*]} " != *" WS02 misconfig "* ] && EXECUTED_STEPS+=("WS02 misconfig")
}

# ── Step 11: DC01 objects final pass ──
step_dc01_objects_final() {
    log_step "[11/14] DC01 AD objects (final pass)..."
    if check_dc01_objects; then
        log_skip "AD objects final pass already done"
        SKIPPED_STEPS+=("DC01 objects (final)")
        return
    fi
    run_vagrant vagrant provision dc01 --provision-with objects || { log_err "final objects failed"; exit 1; }
    EXECUTED_STEPS+=("DC01 objects (final)")
}

# ── Step 12: Hardening ──
step_hardening() {
    if [ "$SKIP_HARDENING" = true ]; then
        log_skip "Hardening"
        SKIPPED_STEPS+=("Harden")
        return
    fi
    log_step "[12/14] Hardening — removing default vagrant credentials..."

    local all_hardened=true
    for vm in "${ALL_WINDOWS_VMS[@]}"; do
        if ! vm_selected "$vm"; then continue; fi
        if ! check_hardened "$vm"; then
            all_hardened=false
            break
        fi
    done

    if [ "$all_hardened" = true ]; then
        log_skip "Already hardened"
        SKIPPED_STEPS+=("Harden")
        return
    fi

    local harden_pids=()
    local harden_failures=0
    for vm in "${ALL_WINDOWS_VMS[@]}"; do
        if ! vm_selected "$vm"; then continue; fi
        log_info "Hardening $vm..."
        vagrant provision "$vm" --provision-with harden 2>&1 | filter_winrm &
        harden_pids+=($!)
    done
    for pid in "${harden_pids[@]}"; do
        wait $pid || ((harden_failures++))
    done
    if [ $harden_failures -gt 0 ]; then
        log_warn "Hardening failed on $harden_failures VM(s)"
    else
        log_ok "Hardening complete"
    fi
    EXECUTED_STEPS+=("Harden")
}

# ── Deploy orchestrator ──
cmd_deploy() {
    echo "╔══════════════════════════════════════════╗"
    echo "║  Active Directory Alligator Labs — Setup ║"
    echo "╚══════════════════════════════════════════╝"

    preflight

    # ── Sequential deploy pipeline ──
    step_dc01_base
    step_dc01_postboot
    step_dc01_dns
    step_dc01_objects_base

    if [ "$DC01_ONLY" = true ]; then
        echo ""
        log_info "--dc01-only set — stopping after DC01 build"
        SKIPPED_STEPS+=("DC02 join" "DC03 join" "SRV01 services" "WS01 misconfig" "WS02 misconfig" "DC01 objects (final)" "Harden")
        local end_time=$(date +%s)
        local elapsed=$((end_time - START_TIME))
        echo ""
        echo "DC01 Build Complete in $((elapsed / 60))m $((elapsed % 60))s"
        exit 0
    fi

    step_boot_remaining
    step_dc_joins
    step_member_provisioning
    step_dc01_objects_final
    step_hardening

    # ── Summary ──
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║              Setup Summary               ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    printf "  Total time: %dm %ds\n" $((elapsed / 60)) $((elapsed % 60))
    echo ""
    echo "  Steps executed:"
    if [ ${#EXECUTED_STEPS[@]} -eq 0 ]; then
        echo "    (none)"
    else
        for step in "${EXECUTED_STEPS[@]}"; do
            echo "    - $step"
        done
    fi
    echo ""
    echo "  Steps skipped:"
    if [ ${#SKIPPED_STEPS[@]} -eq 0 ]; then
        echo "    (none)"
    else
        for step in "${SKIPPED_STEPS[@]}"; do
            echo "    - $step"
        done
    fi
    echo ""
    echo "Lab fully built and ready."
}

# ── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo "╔══════════════════════════════════════════╗"
    echo "║  Active Directory Alligator Labs — Setup ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo "USAGE:"
    echo "  ./setup.sh [SUBCOMMAND] [OPTIONS]"
    echo ""
    echo "SUBCOMMANDS:"
    echo "  deploy          Deploy lab from VMs (default)"
    echo "  build-boxes     Build Packer boxes sequentially"
    echo "  destroy         Destroy all VMs"
    echo "  status          Show VM states"
    echo "  help            Show this help"
    echo ""
    echo "DEPLOY OPTIONS:"
    echo "  --vms <list>         Comma-separated VM list (default: all)"
    echo "                       dc01,dc02,dc03,srv01,ws01,ws02,lin01"
    echo "  --dc01-only          Build DC01 only, then stop"
    echo "  --skip-services      Skip SRV01 services (IIS, SQL, ADCS)"
    echo "  --skip-misconfig     Skip WS01/WS02 misconfigurations"
    echo "  --skip-hardening     Skip vagrant account hardening"
    echo "  --skip-linux         Skip LIN01"
    echo ""
    echo "BUILD-BOXES OPTIONS:"
    echo "  --server-only        Build only Windows Server 2022 box"
    echo "  --workstation-only   Build only Windows 10 box"
    echo "  --no-vagrant-add     Build boxes but don't add to Vagrant"
    echo "  --server-iso <path>  Custom Server 2022 ISO path"
    echo "  --win10-iso <path>   Custom Windows 10 ISO path"
    echo ""
    echo "OUTPUT OPTIONS:"
    echo "  -v, --verbose        Show all provisioning output"
    echo "  -q, --quiet          Minimal output"
    echo "  --debug              Show suppressed WinRM errors too"
    echo "  --no-color           Disable colored output"
    echo ""
    echo "EXAMPLES:"
    echo "  ./setup.sh                              Full deploy (all VMs)"
    echo "  ./setup.sh deploy --vms dc01,ws01       Deploy only DC01 and WS01"
    echo "  ./setup.sh deploy --dc01-only           Deploy DC01 only"
    echo "  ./setup.sh deploy --skip-misconfig      Deploy without WS vulns"
    echo "  ./setup.sh deploy --verbose             Full output"
    echo "  ./setup.sh build-boxes --server-only    Build Server 2022 box only"
    echo "  ./setup.sh destroy                      Destroy everything"
    echo "  ./setup.sh status                       Show VM states"
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
}

# ═══════════════════════════════════════════════════════════════════════════
# Entry point — argument parsing
# ═══════════════════════════════════════════════════════════════════════════

SUBCMD=""
ARGS=()

# Separate subcommand from options
for arg in "$@"; do
    case $arg in
        deploy|build-boxes|destroy|status|help|-h|--help)
            if [ -z "$SUBCMD" ] && [ "$arg" != "-h" ] && [ "$arg" != "--help" ]; then
                SUBCMD="$arg"
                continue
            fi
            ;;
    esac
    ARGS+=("$arg")
done

# Default subcommand
[ -z "$SUBCMD" ] && SUBCMD="deploy"

# Parse options
i=0
while [ $i -lt ${#ARGS[@]} ]; do
    arg="${ARGS[$i]}"
    case $arg in
        -h|--help)
            show_help; exit 0
            ;;
        -v|--verbose)
            VERBOSE=true
            ;;
        -q|--quiet)
            QUIET=true
            ;;
        --debug)
            DEBUG=true
            ;;
        --no-color)
            NO_COLOR=true
            RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
            ;;
        --vms)
            ((i++))
            IFS=',' read -ra SELECTED_VMS <<< "${ARGS[$i]}"
            ;;
        --dc01-only)
            DC01_ONLY=true
            ;;
        --skip-services)
            SKIP_SERVICES=true
            ;;
        --skip-misconfig)
            SKIP_MISCONFIG=true
            ;;
        --skip-hardening)
            SKIP_HARDENING=true
            ;;
        --skip-linux)
            SKIP_LINUX=true
            ;;
        --server-only)
            BUILD_WIN10=false
            ;;
        --workstation-only)
            BUILD_SERVER=false
            ;;
        --no-vagrant-add)
            SKIP_VAGRANT_ADD=true
            ;;
        --server-iso)
            ((i++))
            SERVER_ISO="${ARGS[$i]}"
            ;;
        --win10-iso)
            ((i++))
            WIN10_ISO="${ARGS[$i]}"
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run './setup.sh help' for usage"
            exit 1
            ;;
    esac
    ((i++))
done

# ── Dispatch ──
case $SUBCMD in
    deploy)
        cmd_deploy
        ;;
    build-boxes)
        cmd_build_boxes
        ;;
    destroy)
        cmd_destroy
        ;;
    status)
        cmd_status
        ;;
    help)
        show_help
        ;;
    *)
        echo "Unknown subcommand: $SUBCMD"
        echo "Run './setup.sh help' for usage"
        exit 1
        ;;
esac
