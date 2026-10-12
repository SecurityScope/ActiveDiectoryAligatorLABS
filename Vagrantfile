# Auto-install required plugins
required_plugins = %w[vagrant-reload vagrant-vbguest vagrant-hostmanager]
plugins_to_install = required_plugins.reject { |p| Vagrant.has_plugin?(p) }
unless plugins_to_install.empty?
  puts "Installing required plugins: #{plugins_to_install.join(', ')}"
  if Vagrant::Util::Platform.windows?
    ENV['PATH'] = "C:\\Program Files\\Oracle\\VirtualBox;" + ENV['PATH']
  end
  success = system "vagrant plugin install #{plugins_to_install.join(' ')}"
  unless success
    puts "ERROR: Plugin install failed. Install manually:"
    plugins_to_install.each { |p| puts "  vagrant plugin install #{p}" }
    exit 1
  end
  exit 0
end

require_relative 'vagrant_plugins/winrm_quiet'

# ─── Load lab.conf (single source of truth) ──────────────────────────────
# Flat KEY=value file shared with setup.sh / setup.ps1 so domain, IPs, boxes
# and passwords live in exactly one place.
_lab_conf = {}
_conf_path = File.join(File.dirname(__FILE__), 'lab.conf')
if File.exist?(_conf_path)
  File.foreach(_conf_path) do |line|
    line = line.strip
    next if line.empty? || line.start_with?('#')
    key, _, val = line.partition('=')
    _lab_conf[key.strip] = val.strip
  end
else
  abort "ERROR: lab.conf not found at #{_conf_path}"
end

DOMAIN        = _lab_conf['DOMAIN']
DOMAIN_UPPER  = _lab_conf['DOMAIN_UPPER']
CHILD_DOMAIN  = _lab_conf['CHILD_DOMAIN']
CHILD_UPPER   = _lab_conf['CHILD_UPPER']
DC01_IP       = _lab_conf['DC01_IP']
DC02_IP       = _lab_conf['DC02_IP']
DC03_IP       = _lab_conf['DC03_IP']
SRV01_IP      = _lab_conf['SRV01_IP']
WS01_IP       = _lab_conf['WS01_IP']
WS02_IP       = _lab_conf['WS02_IP']
LIN01_IP      = _lab_conf['LIN01_IP']
KALI_IP       = _lab_conf['KALI_IP']
ADMIN_PASS    = _lab_conf['ADMIN_PASS']
DSRM_PASS     = _lab_conf['DSRM_PASS']

# Domain Controllers (dc01, dc02, dc03) lose their local SAM database once
# they are promoted (Install-ADDSForest / Install-ADDSDomainController) -
# only domain accounts authenticate afterward, so the WinRM communicator
# must use "Administrator" instead of the local "vagrant" account for
# those three machines. The built-in Administrator account survives
# promotion with the SAME password it had locally (set to "vagrant" by
# Autounattend.xml), until dc01_dns.ps1 resets it to ADMIN_PASS as part of
# the documented setup.sh flow. Anything driving `vagrant provision` /
# `vagrant up` for a DC AFTER that password reset has happened (i.e. every
# step from "objects-base" onward, and any subsequent `vagrant up` once
# the lab is fully built) must set DC_WINRM_PASSWORD=SecScope2024! in the
# environment - setup.sh does this automatically.
DC_WINRM_PASSWORD = ENV['DC_WINRM_PASSWORD'] || "vagrant"

SERVER_BOX      = _lab_conf['SERVER_BOX']
WORKSTATION_BOX = _lab_conf['WORKSTATION_BOX']

# ─── Helper: define a Windows VM with common boilerplate ─────────────────
# NOTE: `ip:` is informational only (documents each VM's intended internal
# address at the call site). There is no `private_network` stanza - the static
# 192.168.200.x address is assigned inside the guest by dc_base.ps1 /
# domain_join.ps1 on the natnetwork adapter, so this parameter is NOT applied
# here. It is kept so callers read as a self-documenting inventory.
def define_windows_vm(config, name:, ip:, memory: 2048, cpus: 2, box: SERVER_BOX, rdp_port: nil, winrm_port: nil, domain_controller: false)
  config.vm.define name do |vm|
    vm.vm.box = box
    vm.vm.communicator = "winrm"
    if domain_controller
      vm.winrm.username = "Administrator"
      vm.winrm.password = DC_WINRM_PASSWORD
    else
      vm.winrm.username = "vagrant"
      vm.winrm.password = "vagrant"
    end

    # The Packer boxes already ship functional Guest Additions (shared folders
    # + WinRM work). vagrant-vbguest's auto-rebuild re-uploads the 53 MB ISO
    # over WinRM on every boot, which is fragile: it intermittently fails with
    # "Bad HTTP response (400)" or WSMAN "Not enough memory" and aborts the
    # boot (destroying ws01/ws02 mid-build). The host/guest version mismatch is
    # cosmetic, so disable the rebuild for all Windows VMs.
    vm.vbguest.auto_update = false if Vagrant.has_plugin?("vagrant-vbguest")

    if rdp_port
      vm.vm.network "forwarded_port", guest: 3389, host: rdp_port, auto_correct: true
    end
    if winrm_port
      vm.vm.network "forwarded_port", guest: 5985, host: winrm_port, auto_correct: true
    end

    vm.vm.provider "virtualbox" do |v|
      v.gui = false
      v.memory = memory
      v.cpus = cpus
      v.customize ["modifyvm", :id, "--name", "#{name.upcase}.SECSCOPE.CORP"]
      v.customize ["modifyvm", :id, "--vram", "128"]
      v.customize ["modifyvm", :id, "--graphicscontroller", "vboxsvga"]
      v.customize ["modifyvm", :id, "--accelerate3d", "off"]
      if domain_controller
        v.customize ["modifyvm", :id, "--natdnshostresolver1", "off"]
      else
        v.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
      end
      v.customize ["modifyvm", :id, "--nic2", "natnetwork"]
      v.customize ["modifyvm", :id, "--nat-network2", "SECSCOPE.CORP"]
      # Boxes built by Packer boot from DVD (needed for OS install) and that
      # boot order is baked into the exported box. Force disk-first boot here
      # so VMs don't fail with "Could not read from the boot medium!".
      v.customize ["modifyvm", :id, "--boot1", "disk"]
      v.customize ["modifyvm", :id, "--boot2", "none"]
    end

    vm.vm.provision "common", type: "shell", path: "scripts/common_windows.ps1",
      env: { "SKIP_NLA_FIX" => ENV['SKIP_NLA_FIX'] }

    vm.vm.provision "harden", type: "shell", run: "never",
      path: "scripts/harden_windows.ps1"

    yield vm if block_given?
  end
end

Vagrant.configure("2") do |config|

  config.vm.boot_timeout = 900
  config.winrm.timeout   = 180
  config.winrm.retry_limit = 30
  config.winrm.retry_delay = 10

  config.hostmanager.enabled = true
  config.hostmanager.manage_host = false   # false: do NOT edit host OS hosts file (UAC on Windows, permissions on Linux/macOS)
  config.hostmanager.manage_guest = false
  config.hostmanager.ignore_private_ip = false

  config.trigger.before :up do |trigger|
    trigger.name = "Create SECSCOPE.CORP NAT Network"
    if Vagrant::Util::Platform.windows?
      trigger.run = {
        inline: 'cmd /c "\"C:\\Program Files\\Oracle\\VirtualBox\\VBoxManage.exe\" natnetwork add --netname SECSCOPE.CORP --network 192.168.200.0/24 --enable --dhcp off & exit 0"'
      }
    else
      trigger.run = {
        inline: '/bin/bash -c "VBoxManage natnetwork add --netname SECSCOPE.CORP --network 192.168.200.0/24 --enable --dhcp off 2>/dev/null; VBoxManage natnetwork modify --netname SECSCOPE.CORP --enable 2>/dev/null; exit 0"'
      }
    end
  end

  # ─── DC01 ─── Primary Domain Controller ──────────────────────────────────

  define_windows_vm(config, name: "dc01", ip: DC01_IP, rdp_port: 33889, winrm_port: 59849, domain_controller: true) do |vm|
    vm.vm.provision "base", type: "shell", path: "scripts/dc_base.ps1", env: {
      "DC_IP"      => DC01_IP,
      "DC01_IP"    => DC01_IP,
      "DC_NAME"    => "DC01",
      "LOG_PREFIX" => "dc01_base",
      "DNS_SERVER" => "127.0.0.1"
    }

    vm.vm.provision "sysprep", type: "shell", run: "never",
      path: "scripts/sysprep_sid.ps1"

    vm.vm.provision "base-reload", type: :reload

    vm.vm.provision "postboot", type: "shell", run: "never",
      path: "scripts/dc01_postboot.ps1", env: {
        "DOMAIN"       => DOMAIN,
        "DOMAIN_UPPER" => DOMAIN_UPPER,
        "DSRM_PASS"    => DSRM_PASS
      }

    vm.vm.provision "postboot-reload", type: :reload, run: "never"

    vm.vm.provision "dns", type: "shell", run: "never",
      path: "scripts/dc01_dns.ps1", env: {
        "DOMAIN"       => DOMAIN,
        "CHILD_DOMAIN" => CHILD_DOMAIN,
        "ADMIN_PASS"   => ADMIN_PASS,
        "DC01_IP"      => DC01_IP,
        "DC02_IP"      => DC02_IP,
        "DC03_IP"      => DC03_IP,
        "SRV01_IP"     => SRV01_IP,
        "WS01_IP"      => WS01_IP,
        "WS02_IP"      => WS02_IP,
        "LIN01_IP"     => LIN01_IP,
        "KALI_IP"      => KALI_IP
      }

    vm.vm.provision "objects-base", type: "shell", run: "never",
      path: "scripts/dc01_objects.ps1", env: {
        "DOMAIN"         => DOMAIN,
        "DOMAIN_UPPER"   => DOMAIN_UPPER,
        "CHILD_DOMAIN"   => CHILD_DOMAIN,
        "CHILD_UPPER"    => CHILD_UPPER,
        "ADMIN_PASS"     => ADMIN_PASS,
        "DSRM_PASS"      => DSRM_PASS,
        "SKIP_COMPUTERS" => "true"
      }

    vm.vm.provision "objects", type: "shell", run: "never",
      path: "scripts/dc01_objects.ps1", env: {
        "DOMAIN"       => DOMAIN,
        "DOMAIN_UPPER" => DOMAIN_UPPER,
        "CHILD_DOMAIN" => CHILD_DOMAIN,
        "CHILD_UPPER"  => CHILD_UPPER,
        "ADMIN_PASS"   => ADMIN_PASS,
        "DSRM_PASS"    => DSRM_PASS,
        # When set (by setup.py's per-member ACL pass) only that member's
        # computer ACLs are applied, so building one member doesn't wait on the
        # others. Empty (manual `vagrant provision dc01 --provision-with objects`)
        # processes all members.
        "MEMBER_SCOPE" => ENV['MEMBER_SCOPE']
      }

    vm.vm.provision "avupdate-gpo", type: "shell", run: "never",
      path: "scripts/dc01_av_update_gpo.ps1", env: {
        "DOMAIN" => DOMAIN
      }

    vm.vm.provision "child-dns", type: "shell", run: "never",
      path: "scripts/dc01_child_dns.ps1", env: {
        "DOMAIN"       => DOMAIN,
        "CHILD_DOMAIN" => CHILD_DOMAIN,
        "DC03_IP"      => DC03_IP
      }
  end

  # ─── DC02 ─── Secondary Domain Controller ─────────────────────────────────

  define_windows_vm(config, name: "dc02", ip: DC02_IP, rdp_port: 33890, winrm_port: 59850, domain_controller: true) do |vm|
    vm.vm.provision "sysprep", type: "shell", run: "never",
      path: "scripts/sysprep_sid.ps1"

    vm.vm.provision "base", type: "shell", path: "scripts/dc_base.ps1", env: {
      "DC_IP"      => DC02_IP,
      "DC01_IP"    => DC01_IP,
      "DC_NAME"    => "DC02",
      "LOG_PREFIX" => "dc02_base"
    }

    vm.vm.provision "base-reload", type: :reload

    vm.vm.provision "join", type: "shell", run: "never",
      path: "scripts/dc02_join.ps1", env: {
        "DOMAIN"       => DOMAIN,
        "DOMAIN_UPPER" => DOMAIN_UPPER,
        "ADMIN_PASS"   => ADMIN_PASS,
        "DC01_IP"      => DC01_IP,
        "DC_IP"        => DC02_IP
      }

    vm.vm.provision "join-reload", type: :reload, run: "never"

    vm.vm.provision "postboot", type: "shell", run: "never",
      path: "scripts/dc02_postboot.ps1", env: {
        "DOMAIN"     => DOMAIN,
        "ADMIN_PASS" => ADMIN_PASS,
        "DC01_IP"    => DC01_IP,
        "DC03_IP"    => DC03_IP
      }
  end

  # ─── DC03 ─── Subdomain Controller (it.secscope.corp) ──────────────

  define_windows_vm(config, name: "dc03", ip: DC03_IP, rdp_port: 33891, winrm_port: 59851, domain_controller: true) do |vm|
    vm.vm.provision "sysprep", type: "shell", run: "never",
      path: "scripts/sysprep_sid.ps1"

    vm.vm.provision "base", type: "shell", path: "scripts/dc_base.ps1", env: {
      "DC_IP"      => DC03_IP,
      "DC01_IP"    => DC01_IP,
      "DC_NAME"    => "DC03",
      "LOG_PREFIX" => "dc03_base",
      "DNSSUFFIX"  => "it.secscope.corp"
    }

    vm.vm.provision "base-reload", type: :reload

    vm.vm.provision "join", type: "shell", run: "never",
      path: "scripts/dc03_join.ps1", env: {
        "DOMAIN"       => DOMAIN,
        "DOMAIN_UPPER" => DOMAIN_UPPER,
        "CHILD_DOMAIN" => CHILD_DOMAIN,
        "ADMIN_PASS"   => ADMIN_PASS,
        "DC01_IP"      => DC01_IP,
        "DC_IP"        => DC03_IP
      }

    vm.vm.provision "join-reload", type: :reload, run: "never"

    vm.vm.provision "postboot", type: "shell", run: "never",
      path: "scripts/dc03_postboot.ps1", env: {
        "DOMAIN"       => DOMAIN,
        "CHILD_DOMAIN" => CHILD_DOMAIN,
        "ADMIN_PASS"   => ADMIN_PASS,
        "DC01_IP"      => DC01_IP
      }
  end

  # ─── SRV01 ─── MSSQL + IIS + ADCS CA ─────────────────────────────────────

  define_windows_vm(config, name: "srv01", ip: SRV01_IP, memory: 3072, rdp_port: 33892, winrm_port: 59852) do |vm|
    vm.vm.provision "sysprep", type: "shell", run: "never",
      path: "scripts/sysprep_sid.ps1"

    vm.vm.provision "join", type: "shell", run: "never", path: "scripts/domain_join.ps1", env: {
      "DOMAIN"       => DOMAIN,
      "DOMAIN_UPPER" => DOMAIN_UPPER,
      "ADMIN_PASS"   => ADMIN_PASS,
      "DC01_IP"      => DC01_IP,
      "VM_IP"        => SRV01_IP,
      "VM_NAME"      => "SRV01",
      "VM_OU"        => "OU=Servers",
      "LOG_PREFIX"   => "srv01_join"
    }

    vm.vm.provision "join-reload", type: :reload, run: "never"

    vm.vm.provision "services", type: "shell", run: "never",
      path: "scripts/srv01_services.ps1", env: {
        "DOMAIN"     => DOMAIN,
        "ADMIN_PASS" => ADMIN_PASS
      }
  end

  # ─── WS01 ─── Domain Workstation, Primary Pivot Target ────────────────────

  define_windows_vm(config, name: "ws01", ip: WS01_IP, box: WORKSTATION_BOX, rdp_port: 53389, winrm_port: 55987) do |vm|
    vm.vm.provision "sysprep", type: "shell", run: "never",
      path: "scripts/sysprep_sid.ps1"

    vm.vm.provision "join", type: "shell", run: "never", path: "scripts/domain_join.ps1", env: {
      "DOMAIN"       => DOMAIN,
      "DOMAIN_UPPER" => DOMAIN_UPPER,
      "ADMIN_PASS"   => ADMIN_PASS,
      "DC01_IP"      => DC01_IP,
      "VM_IP"        => WS01_IP,
      "VM_NAME"      => "WS01",
      "VM_OU"        => "OU=Workstations,OU=IT",
      "LOG_PREFIX"   => "ws01_join"
    }

    vm.vm.provision "join-reload", type: :reload, run: "never"

    vm.vm.provision "misconfig", type: "shell", run: "never",
      path: "scripts/ws01_misconfig.ps1", env: {
        "DOMAIN" => DOMAIN
      }
  end

  # ─── WS02 ─── Domain Workstation, Unconstrained Delegation ────────────────

  define_windows_vm(config, name: "ws02", ip: WS02_IP, box: WORKSTATION_BOX, rdp_port: 53390, winrm_port: 55988) do |vm|
    vm.vm.provision "sysprep", type: "shell", run: "never",
      path: "scripts/sysprep_sid.ps1"

    vm.vm.provision "join", type: "shell", run: "never", path: "scripts/domain_join.ps1", env: {
      "DOMAIN"       => DOMAIN,
      "DOMAIN_UPPER" => DOMAIN_UPPER,
      "ADMIN_PASS"   => ADMIN_PASS,
      "DC01_IP"      => DC01_IP,
      "VM_IP"        => WS02_IP,
      "VM_NAME"      => "WS02",
      "VM_OU"        => "OU=Workstations,OU=IT",
      "LOG_PREFIX"   => "ws02_join"
    }

    vm.vm.provision "join-reload", type: :reload, run: "never"

    vm.vm.provision "misconfig", type: "shell", run: "never",
      path: "scripts/ws02_misconfig.ps1"
  end

  # ─── LIN01 ─── Debian Linux Domain Member ─────────────────────────────────

  config.vm.define "lin01" do |vm|
    vm.vm.box = "debian/bookworm64"
    vm.ssh.username = "vagrant"
    vm.ssh.insert_key = false

    # The debian/bookworm64 box ships GuestAdditions 6.0.0 while the host runs
    # VirtualBox 7.2. vagrant-vbguest tries to rebuild them on boot, which runs
    # `apt-get install linux-headers-$(uname -r)` - a headers package that is
    # not present in the box's apt sources (E: Unable to locate package
    # linux-headers-6.1.0-29-amd64), aborting the boot. lin01 relies on the
    # uploaded shell provisioner, not shared folders, so GuestAdditions are not
    # needed here - disable the auto-rebuild.
    vm.vbguest.auto_update = false if Vagrant.has_plugin?("vagrant-vbguest")

    vm.vm.network "forwarded_port", guest: 22, host: 22240, auto_correct: true

    vm.vm.provider "virtualbox" do |v|
      v.gui = false
      v.memory = 1024
      v.cpus = 1
      v.customize ["modifyvm", :id, "--name", "LIN01.SECSCOPE.CORP"]
      v.customize ["modifyvm", :id, "--nic2", "natnetwork"]
      v.customize ["modifyvm", :id, "--nat-network2", "SECSCOPE.CORP"]
      v.customize ["modifyvm", :id, "--boot1", "disk"]
      v.customize ["modifyvm", :id, "--boot2", "none"]
    end

    vm.vm.provision "setup", type: "shell", path: "scripts/lin01_setup.sh", env: {
      "DOMAIN"     => DOMAIN,
      "DC01_IP"    => DC01_IP,
      "ADMIN_PASS" => ADMIN_PASS,
      "LIN01_IP"   => LIN01_IP
    }

    # Fully remove the vagrant account. Set a root password FIRST (to ADMIN_PASS)
    # so console/root login survives - otherwise deleting vagrant (the only
    # sudoer) locks you out. Then kill vagrant's live processes and userdel -r.
    vm.vm.provision "harden", type: "shell", run: "never", env: { "ADMIN_PASS" => ADMIN_PASS },
      inline: <<-SHELL
        set -e
        echo "root:${ADMIN_PASS}" | chpasswd
        echo "[harden] root password set (console login preserved)"
        pkill -KILL -u vagrant 2>/dev/null || true
        sleep 1
        userdel -r -f vagrant 2>/dev/null || true
        if id vagrant >/dev/null 2>&1; then
          echo "[harden] WARNING: vagrant user still present"
        else
          echo "[harden] vagrant user deleted (home removed)"
        fi
      SHELL
  end

end
