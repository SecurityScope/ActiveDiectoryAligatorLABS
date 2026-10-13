#!/bin/bash
set -e

DOMAIN_LOWER=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')
DOMAIN_UPPER=$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')

echo "[lin01] Starting setup..."

# Detect the internal (natnetwork) NIC by exclusion rather than assuming eth1:
# the debian/bookworm64 box may name it eth1, enp0s8, ens6, ... The management
# NIC is the one carrying the default route (VirtualBox NAT); the internal NIC
# is the other ethernet device.
MGMT_IF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
INT_IF=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' \
    | grep -E '^(eth|en|ens|enp)' | grep -v "^${MGMT_IF}$" | head -n1)
INT_IF=${INT_IF:-eth1}
echo "[lin01] Internal NIC detected: $INT_IF (mgmt: ${MGMT_IF:-unknown}) -> $LIN01_IP"
cat > /etc/network/interfaces.d/${INT_IF}.cfg <<EOF
auto $INT_IF
iface $INT_IF inet static
    address $LIN01_IP/24
EOF
ip link set "$INT_IF" up 2>/dev/null || true
ip addr add "$LIN01_IP/24" dev "$INT_IF" 2>/dev/null || true

echo "[lin01] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    sssd sssd-tools realmd adcli \
    krb5-user libpam-krb5 \
    samba-common-bin \
    openssh-server \
    python3 python3-pip \
    wget curl git \
    net-tools nmap \
    2>/dev/null

echo "[lin01] Configuring DNS to point at DC01..."
cat > /etc/resolv.conf <<EOF
nameserver $DC01_IP
search $DOMAIN_LOWER
EOF
chattr +i /etc/resolv.conf 2>/dev/null || true

echo "[lin01] Configuring Kerberos..."
cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = $DOMAIN_UPPER
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    $DOMAIN_UPPER = {
        kdc = dc01.$DOMAIN_LOWER
        admin_server = dc01.$DOMAIN_LOWER
    }

[domain_realm]
    .$DOMAIN_LOWER = $DOMAIN_UPPER
    $DOMAIN_LOWER = $DOMAIN_UPPER
EOF

# NOTE: Do NOT pre-write /etc/sssd/sssd.conf here. If an sssd.conf with this
# domain already exists, `realm join` reports "Already joined to this domain"
# and SKIPS the actual join - so no LIN01$ computer account is created in AD and
# no machine keytab is fetched (the host only *looks* joined locally). Let
# `realm join` create sssd.conf and do the real join; the lab-specific SSSD
# tweaks are applied AFTER the join, below.
rm -f /etc/sssd/sssd.conf

echo "[lin01] Waiting for DC01 to be reachable..."
for i in $(seq 1 30); do
    if ping -c 1 -W 2 $DC01_IP &>/dev/null; then
        echo "[lin01] DC01 reachable"
        break
    fi
    echo "[lin01] Attempt $i/30, waiting..."
    sleep 10
done

echo "[lin01] Joining domain $DOMAIN_LOWER..."
# Pipe to `tail` was masking the realm-join exit status from `set -e` (PIPESTATUS
# of the pipeline is tail's), so a failed join was silently treated as success.
# Feed the password on stdin (--stdin-password where supported, else here-string)
# and check realm's own exit status explicitly.
join_rc=0
if realm join --help 2>&1 | grep -q -- '--stdin-password'; then
    printf '%s' "$ADMIN_PASS" | realm join --user=Administrator --stdin-password "$DOMAIN_LOWER" -v || join_rc=$?
else
    realm join --user=Administrator "$DOMAIN_LOWER" -v <<< "$ADMIN_PASS" || join_rc=$?
fi
if [ "$join_rc" -ne 0 ]; then
    if realm list 2>/dev/null | grep -qi "$DOMAIN_LOWER"; then
        echo "[lin01] realm join returned $join_rc but host is already joined ($DOMAIN_LOWER); continuing"
    else
        echo "[lin01] ERROR: realm join failed (rc=$join_rc) and host is not joined to $DOMAIN_LOWER"
        exit 1
    fi
else
    echo "[lin01] realm join succeeded"
fi

# Verify the join actually created the machine account / keytab (realm can report
# a misleading state). If LIN01$ keys aren't in the keytab, the join didn't work.
if ! klist -k /etc/krb5.keytab 2>/dev/null | grep -qiE "LIN01\\\$@"; then
    echo "[lin01] ERROR: no LIN01\$ keys in /etc/krb5.keytab - the realm join did not complete"
    exit 1
fi
echo "[lin01] Machine account keytab present (join confirmed)"

echo "[lin01] Applying lab SSSD settings (short usernames, home dirs, offline creds)..."
# realm join writes a default sssd.conf (fully-qualified names, /home/%u@%d).
# Tweak it for the lab AFTER the join so we don't block the join itself.
if [ -f /etc/sssd/sssd.conf ]; then
    sed -i 's/^use_fully_qualified_names.*/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
    sed -i 's#^fallback_homedir.*#fallback_homedir = /home/%u#' /etc/sssd/sssd.conf
    grep -q '^use_fully_qualified_names' /etc/sssd/sssd.conf || sed -i "/^\[domain\/$DOMAIN_LOWER\]/a use_fully_qualified_names = False" /etc/sssd/sssd.conf
    grep -q '^fallback_homedir'          /etc/sssd/sssd.conf || sed -i "/^\[domain\/$DOMAIN_LOWER\]/a fallback_homedir = /home/%u" /etc/sssd/sssd.conf
    grep -q '^cache_credentials'         /etc/sssd/sssd.conf || sed -i "/^\[domain\/$DOMAIN_LOWER\]/a cache_credentials = True" /etc/sssd/sssd.conf
    grep -q '^default_shell'             /etc/sssd/sssd.conf || sed -i "/^\[domain\/$DOMAIN_LOWER\]/a default_shell = /bin/bash" /etc/sssd/sssd.conf
    chmod 600 /etc/sssd/sssd.conf
    systemctl restart sssd 2>/dev/null || service sssd restart 2>/dev/null || true
    echo "[lin01] SSSD settings applied + restarted"
else
    echo "[lin01] WARNING: /etc/sssd/sssd.conf not found after join"
fi

echo "[lin01] Enabling SSH with password auth..."
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
systemctl restart sshd || service sshd restart

echo "[lin01] Configuring auto home directory creation..."
cat >> /etc/pam.d/common-session <<'EOF'
session required pam_mkhomedir.so skel=/etc/skel/ umask=0077
EOF

echo "[lin01] Creating local labuser account..."
useradd -m -s /bin/bash labuser 2>/dev/null || true
echo "labuser:LabUser2024!" | chpasswd 2>/dev/null || true

echo "[lin01] Planting SSH key for han..."
mkdir -p /home/han/.ssh 2>/dev/null || true
ssh-keygen -t ed25519 -f /tmp/han_key -N "" -q
cp /tmp/han_key.pub /home/han/.ssh/authorized_keys 2>/dev/null || true
chmod 700 /home/han/.ssh 2>/dev/null || true
chmod 600 /home/han/.ssh/authorized_keys 2>/dev/null || true
cp /tmp/han_key /opt/.hidden_key
chmod 644 /opt/.hidden_key

echo "[lin01] Planting credentials in bash history for labuser..."
mkdir -p /home/labuser/.ssh
# Target real/plausible hosts: han over SSH to lin01 (a Linux SSH host), and
# svc_sql to the MSSQL instance on SRV01 (impacket's mssqlclient, since SRV01
# runs MSSQL not MySQL). The value is the leaked credentials either way.
echo "sshpass -p 'Solo2024!' ssh han@lin01.$DOMAIN_LOWER" > /home/labuser/.bash_history
echo "impacket-mssqlclient svc_sql:SqlService123@192.168.200.20 -windows-auth" >> /home/labuser/.bash_history
echo "kinit han@$DOMAIN_UPPER" >> /home/labuser/.bash_history
chown labuser:labuser /home/labuser/.bash_history

echo "[lin01] Planting known_hosts (lateral-target hint)..."
cat > /home/labuser/.ssh/known_hosts <<EOF
lin01.$DOMAIN_LOWER,$LIN01_IP ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderKeyForLabKnownHostsEntryOnly000000000
EOF
chown -R labuser:labuser /home/labuser/.ssh
chmod 700 /home/labuser/.ssh
chmod 644 /home/labuser/.ssh/known_hosts

echo "[lin01] Creating Kerberos keytab (for keytab enumeration exercise)..."
printf 'addent -password -p Administrator@%s -k 1 -e rc4-hmac\n%s\nwkt /etc/krb5.keytab\nquit\n' "$DOMAIN_UPPER" "$ADMIN_PASS" | timeout 10 ktutil 2>/dev/null || true

echo "[lin01] Setup complete"
