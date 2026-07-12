#!/bin/bash
set -e

echo "[packer] Installing VirtualBox Guest Additions..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

echo "[packer] Installing build dependencies..."
apt-get install -y -qq build-essential dkms "linux-headers-$(uname -r)" perl

echo "[packer] Mounting Guest Additions ISO..."
mkdir -p /mnt/vboxga
mount -o ro /dev/sr1 /mnt/vboxga 2>/dev/null || mount -o ro /dev/sr0 /mnt/vboxga

echo "[packer] Running VBoxLinuxAdditions.run..."
sh /mnt/vboxga/VBoxLinuxAdditions.run || true

echo "[packer] Cleaning up..."
umount /mnt/vboxga 2>/dev/null || true
rmdir /mnt/vboxga 2>/dev/null || true
apt-get remove -y build-essential dkms "linux-headers-$(uname -r)" 2>/dev/null || true
apt-get autoremove -y -qq 2>/dev/null || true
apt-get clean -qq

echo "[packer] Guest Additions installed."
