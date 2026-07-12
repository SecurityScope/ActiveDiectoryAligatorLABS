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
  default     = "iso/debian-12.15.0-amd64-netinst-preseed.iso"
  description = "Path to Debian Bookworm net-install ISO (with baked-in preseed)"
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
  memory                = 1024
  cpus                  = 2
  headless              = true
  guest_os_type         = "Debian_64"
  communicator          = "ssh"
  ssh_username          = "vagrant"
  ssh_password          = "vagrant"
  ssh_timeout           = "2h"
  shutdown_command      = "sudo shutdown -P now"
  shutdown_timeout      = "5m"
  output_directory      = var.output_directory
  guest_additions_mode  = "attach"

  boot_wait             = "5s"
  boot_command = [
    "<enter>"
  ]

  vboxmanage = [
    ["modifyvm", "{{.Name}}", "--boot1", "disk"],
    ["modifyvm", "{{.Name}}", "--boot2", "dvd"],
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
