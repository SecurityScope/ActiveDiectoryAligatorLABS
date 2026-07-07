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
  default     = "iso/Win10_22H2_English_x64v1.iso"
  description = "Path to Windows 10 ISO"
}

variable "iso_checksum" {
  type        = string
  default     = "none"
  description = "SHA256 checksum. Get with: sha256sum your.iso"
}

variable "output_directory" {
  type    = string
  default = "packer/builds/windows-10"
}

variable "box_output" {
  type    = string
  default = "packer/boxes/windows-10.box"
}

source "virtualbox-iso" "windows-10" {
  vm_name              = "packer-windows-10"
  iso_url              = var.iso_path
  iso_checksum         = var.iso_checksum == "none" ? "none" : "sha256:${var.iso_checksum}"
  disk_size            = 61440
  memory               = 4096
  cpus                 = 4
  headless             = true
  guest_os_type        = "Windows10_64"
  communicator         = "winrm"
  winrm_username       = "vagrant"
  winrm_password       = "vagrant"
  winrm_timeout        = "4h"
  winrm_port           = 5985
  winrm_use_ssl        = false
  winrm_insecure       = true
  shutdown_command     = "shutdown /s /t 10 /f /d p:4:1"
  shutdown_timeout     = "15m"
  output_directory     = var.output_directory
  guest_additions_mode = "attach"

  floppy_files = [
    "packer/autounattend/windows-10/Autounattend.xml",
    "packer/scripts/setup_winrm.ps1",
    "packer/scripts/setup_vagrant.ps1"
  ]

  boot_wait    = "10s"
  boot_command = ["<spacebar><spacebar>"]

  vboxmanage = [
    ["modifyvm", "{{.Name}}", "--boot1", "dvd"],
    ["modifyvm", "{{.Name}}", "--vram", "128"],
    ["modifyvm", "{{.Name}}", "--graphicscontroller", "vboxsvga"],
    ["modifyvm", "{{.Name}}", "--nat-localhostreachable1", "on"],
    ["modifyvm", "{{.Name}}", "--audio", "none"],
    ["modifyvm", "{{.Name}}", "--usb", "off"],
    ["modifyvm", "{{.Name}}", "--clipboard", "disabled"]
  ]
}

build {
  name    = "windows-10"
  sources = ["source.virtualbox-iso.windows-10"]

  provisioner "powershell" {
    scripts = [
      "packer/scripts/install_vboxga.ps1",
      "packer/scripts/optimize.ps1",
      "packer/scripts/cleanup.ps1"
    ]
    elevated_user     = "vagrant"
    elevated_password = "vagrant"
  }

  post-processor "vagrant" {
    output               = var.box_output
    vagrantfile_template = "packer/windows-10/vagrantfile-template.rb"
    keep_input_artifact  = false
  }
}
