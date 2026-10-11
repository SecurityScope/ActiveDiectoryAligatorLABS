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
  default     = "iso/ubuntu-24.04.4-live-server-amd64.iso"
  description = "Path to Ubuntu Server 24.04 LTS ISO"
}

variable "iso_checksum" {
  type        = string
  default     = "none"
  description = "SHA256 checksum. Get with: sha256sum your.iso"
}

variable "output_directory" {
  type    = string
  default = "packer/builds/ubuntu-v2"
}

variable "box_output" {
  type    = string
  default = "packer/boxes/ubuntu-server.box"
}

source "virtualbox-iso" "ubuntu-server" {
  vm_name               = "packer-ubuntu-server"
  iso_url               = var.iso_path
  iso_checksum          = var.iso_checksum == "none" ? "none" : "sha256:${var.iso_checksum}"
  disk_size             = 20480
  memory                = 1024
  cpus                  = 2
  headless              = true
  guest_os_type         = "Ubuntu_64"
  communicator          = "ssh"
  ssh_username          = "vagrant"
  ssh_password          = "vagrant"
  ssh_timeout           = "2h"
  shutdown_command      = "sudo shutdown -P now"
  shutdown_timeout      = "5m"
  output_directory      = var.output_directory
  guest_additions_mode  = "attach"

  http_directory  = "packer/ubuntu-server/http"
  http_port_min   = 8000
  http_port_max   = 8000

  boot_wait             = "10s"
  boot_command = [
    "e<wait1s>",
    "<down><down><end>",
    "<bs><bs><bs><bs><bs>",
    " autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---",
    "<leftCtrlOn>x<leftCtrlOff>"
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
  name    = "ubuntu-server"
  sources = ["source.virtualbox-iso.ubuntu-server"]

  provisioner "shell" {
    scripts = [
      "packer/scripts/install_vboxga_linux.sh"
    ]
  }

  post-processor "vagrant" {
    output               = var.box_output
    vagrantfile_template = "packer/ubuntu-server/vagrantfile-template.rb"
    keep_input_artifact  = false
  }
}
