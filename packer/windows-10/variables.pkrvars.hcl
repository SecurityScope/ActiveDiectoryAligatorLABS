# Copy this file and fill in your values
# Usage: packer build -var-file="my.pkrvars.hcl" .
# Windows 10 ISO sources:
#   - microsoft.com/software-download/windows10
#   - uupdump.net (UUP Dump) for latest builds
#   - Visual Studio Subscriptions for Enterprise edition
# Pro edition recommended; Enterprise also works
iso_path     = "/mnt/DataDisk/securityscope_labs/network/ActiveDirectoryAlligatorLABS/iso/Win10_22H2_English_x64v1.iso"
iso_checksum = "none"  # Set to "none" to skip checksum verification
