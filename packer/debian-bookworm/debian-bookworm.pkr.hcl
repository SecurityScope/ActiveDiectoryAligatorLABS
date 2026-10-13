packer {
  required_plugins {
    virtualbox = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/virtualbox"
    }
  }
}

variable "iso_path" {
  type        = string
  default     = "iso/debian-12.15.0-amd64-netinst.iso"
  description = "Path to the Debian Bookworm net-install ISO (plain; preseed is served over HTTP)"
}

variable "iso_checksum" {
  type        = string
  default     = "none"
  description = "SHA256 checksum. Get with: sha256sum your.iso"
}

variable "output_directory" {
  type    = string
  default = "packer/builds/debian-bookworm"
}

variable "box_output" {
  type    = string
  default = "packer/boxes/debian-bookworm.box"
}

source "virtualbox-iso" "debian-bookworm" {
  vm_name               = "packer-debian-bookworm"
  iso_url               = var.iso_path
  iso_checksum          = var.iso_checksum == "none" ? "none" : "sha256:${var.iso_checksum}"
  disk_size             = 20480
  memory                = 2048
  cpus                  = 2
  headless              = true
  guest_os_type         = "Debian_64"
  communicator          = "ssh"
  ssh_username          = "vagrant"
  ssh_password          = "vagrant"
  ssh_timeout           = "30m"
  ssh_handshake_attempts = "100"
  shutdown_command      = "sudo shutdown -P now"
  shutdown_timeout      = "5m"
  output_directory      = var.output_directory
  guest_additions_mode  = "attach"

  # Serve the preseed over HTTP so we don't depend on a baked-in-preseed ISO.
  http_directory        = "packer/debian-bookworm/http"

  # Interrupt the isolinux boot menu (<esc> -> boot: prompt), then start the
  # text installer with our HTTP preseed. The old boot_command was just
  # ["<wait>"], which never started an automated install, so the installer sat
  # at its menu forever and SSH never came up.
  boot_wait             = "10s"
  boot_command = [
    "<esc><wait>",
    "install <wait>",
    "preseed/url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg <wait>",
    "debian-installer=en_US.UTF-8 <wait>",
    "auto=true <wait>",
    "priority=critical <wait>",
    "locale=en_US.UTF-8 <wait>",
    "kbd-chooser/method=us <wait>",
    "keyboard-configuration/xkb-keymap=us <wait>",
    "netcfg/get_hostname=debian <wait>",
    "netcfg/get_domain=local <wait>",
    "netcfg/choose_interface=auto <wait>",
    "fb=false <wait>",
    "debconf/frontend=noninteractive <wait>",
    "console-setup/ask_detect=false <wait>",
    "console-keymaps-at/keymap=us <wait>",
    "<enter><wait>"
  ]

  vboxmanage = [
    ["modifyvm", "{{.Name}}", "--boot1", "dvd"],
    ["modifyvm", "{{.Name}}", "--boot2", "disk"],
    ["modifyvm", "{{.Name}}", "--nictype1", "virtio"],
    ["modifyvm", "{{.Name}}", "--uart1", "0x3F8", "4"],
    ["modifyvm", "{{.Name}}", "--uartmode1", "file", "/tmp/packer-serial.log"],
    ["modifyvm", "{{.Name}}", "--vram", "128"],
    ["modifyvm", "{{.Name}}", "--graphicscontroller", "vmsvga"],
    ["modifyvm", "{{.Name}}", "--audio", "none"],
    ["modifyvm", "{{.Name}}", "--usb", "off"],
    ["modifyvm", "{{.Name}}", "--clipboard", "disabled"]
  ]
}

build {
  name    = "debian-bookworm"
  sources = ["source.virtualbox-iso.debian-bookworm"]

  provisioner "shell" {
    # Packer's shell provisioner runs as the SSH user (vagrant); the GA script
    # does apt-get/mount which need root, so run it via sudo (password piped to
    # sudo -S). Without this it failed with apt exit status 100.
    execute_command = "echo 'vagrant' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    scripts = [
      "packer/scripts/install_vboxga_linux.sh"
    ]
  }

  post-processor "vagrant" {
    output               = var.box_output
    vagrantfile_template = "packer/debian-bookworm/vagrantfile-template.rb"
    keep_input_artifact  = false
  }
}
