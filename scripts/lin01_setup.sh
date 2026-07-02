#!/bin/bash
set -e

DOMAIN_LOWER=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')
DOMAIN_UPPER=$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')

echo "[lin01] Starting setup..."

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

echo "[lin01] Configuring SSSD..."
cat > /etc/sssd/sssd.conf <<EOF
[sssd]
domains = $DOMAIN_LOWER
config_file_version = 2
services = nss, pam

[domain/$DOMAIN_LOWER]
ad_domain = $DOMAIN_LOWER
krb5_realm = $DOMAIN_UPPER
realmd_tags = manages-system joined-with-adcli
cache_credentials = True
id_provider = ad
krb5_store_password_if_offline = True
default_shell = /bin/bash
ldap_id_mapping = True
use_fully_qualified_names = False
fallback_homedir = /home/%u
access_provider = ad
EOF
chmod 600 /etc/sssd/sssd.conf

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
realm join --user=Administrator "$DOMAIN_LOWER" -v <<< "$ADMIN_PASS" 2>&1 | tail -5

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
echo "sshpass -p 'Solo2024!' ssh han@192.168.200.30" > /home/labuser/.bash_history
echo "mysql -h 192.168.200.20 -u svc_sql -pSqlService123 secscope_db" >> /home/labuser/.bash_history
chown labuser:labuser /home/labuser/.bash_history

echo "[lin01] Creating Kerberos keytab (for keytab enumeration exercise)..."
printf 'addent -password -p Administrator@%s -k 1 -e rc4-hmac\n%s\nwkt /etc/krb5.keytab\nquit\n' "$DOMAIN_UPPER" "$ADMIN_PASS" | timeout 10 ktutil 2>/dev/null || true

echo "[lin01] Setup complete"
