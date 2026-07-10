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

DOMAIN        = "secscope.corp"
DOMAIN_UPPER  = "SECSCOPE"
CHILD_DOMAIN  = "it.secscope.corp"
CHILD_UPPER   = "IT"
DC01_IP       = "192.168.200.10"
DC02_IP       = "192.168.200.11"
DC03_IP       = "192.168.200.12"
SRV01_IP      = "192.168.200.20"
WS01_IP       = "192.168.200.30"
WS02_IP       = "192.168.200.31"
LIN01_IP      = "192.168.200.40"
KALI_IP       = "192.168.200.99"
ADMIN_PASS    = "SecScope2024!"
DSRM_PASS     = "DsrmPass2024!"

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

SERVER_BOX      = "secscope/windows-server-2022"
WORKSTATION_BOX = "secscope/windows-10"

# ─── Helper: define a Windows VM with common boilerplate ─────────────────

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

    vm.vm.provision "common", type: "shell", path: "scripts/common_windows.ps1"

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
        "DSRM_PASS"    => DSRM_PASS
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
        "DC01_IP"      => DC01_IP
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
        "DC01_IP"      => DC01_IP
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

    vm.vm.provision "join", type: "shell", path: "scripts/domain_join.ps1", env: {
      "DOMAIN"       => DOMAIN,
      "DOMAIN_UPPER" => DOMAIN_UPPER,
      "ADMIN_PASS"   => ADMIN_PASS,
      "DC01_IP"      => DC01_IP,
      "VM_IP"        => SRV01_IP,
      "VM_NAME"      => "SRV01",
      "LOG_PREFIX"   => "srv01_join"
    }

    vm.vm.provision "join-reload", type: :reload

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

    vm.vm.provision "join", type: "shell", path: "scripts/domain_join.ps1", env: {
      "DOMAIN"       => DOMAIN,
      "DOMAIN_UPPER" => DOMAIN_UPPER,
      "ADMIN_PASS"   => ADMIN_PASS,
      "DC01_IP"      => DC01_IP,
      "VM_IP"        => WS01_IP,
      "VM_NAME"      => "WS01",
      "LOG_PREFIX"   => "ws01_join"
    }

    vm.vm.provision "join-reload", type: :reload

    vm.vm.provision "misconfig", type: "shell", run: "never",
      path: "scripts/ws01_misconfig.ps1", env: {
        "DOMAIN" => DOMAIN
      }
  end

  # ─── WS02 ─── Domain Workstation, Unconstrained Delegation ────────────────

  define_windows_vm(config, name: "ws02", ip: WS02_IP, box: WORKSTATION_BOX, rdp_port: 53390, winrm_port: 55988) do |vm|
    vm.vm.provision "sysprep", type: "shell", run: "never",
      path: "scripts/sysprep_sid.ps1"

    vm.vm.provision "join", type: "shell", path: "scripts/domain_join.ps1", env: {
      "DOMAIN"       => DOMAIN,
      "DOMAIN_UPPER" => DOMAIN_UPPER,
      "ADMIN_PASS"   => ADMIN_PASS,
      "DC01_IP"      => DC01_IP,
      "VM_IP"        => WS02_IP,
      "VM_NAME"      => "WS02",
      "LOG_PREFIX"   => "ws02_join"
    }

    vm.vm.provision "join-reload", type: :reload

    vm.vm.provision "misconfig", type: "shell", run: "never",
      path: "scripts/ws02_misconfig.ps1"
  end

  # ─── LIN01 ─── Debian Linux Domain Member ─────────────────────────────────

  config.vm.define "lin01" do |vm|
    vm.vm.box = "debian/bookworm64"

    vm.vm.provider "virtualbox" do |v|
      v.gui = false
      v.memory = 1024
      v.cpus = 1
      v.customize ["modifyvm", :id, "--name", "LIN01.SECSCOPE.CORP"]
      v.customize ["modifyvm", :id, "--nic2", "natnetwork"]
      v.customize ["modifyvm", :id, "--nat-network2", "SECSCOPE.CORP"]
    end

    vm.vm.provision "setup", type: "shell", path: "scripts/lin01_setup.sh", env: {
      "DOMAIN"     => DOMAIN,
      "DC01_IP"    => DC01_IP,
      "ADMIN_PASS" => ADMIN_PASS
    }

    vm.vm.provision "harden", type: "shell", run: "never",
      inline: "usermod -L vagrant"
  end

end
