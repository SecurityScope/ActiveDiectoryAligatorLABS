# -*- mode: ruby -*-
Vagrant.configure("2") do |config|
  config.vm.guest        = :windows
  config.vm.communicator = "winrm"
  config.winrm.username  = "vagrant"
  config.winrm.password  = "vagrant"
  config.vm.provider "virtualbox" do |v|
    v.customize ["modifyvm", :id, "--memory", "2048"]
    v.customize ["modifyvm", :id, "--cpus", "2"]
    # The Packer build boots from DVD (--boot1 dvd) to install Windows from ISO.
    # That boot order is baked into the exported box, so it must be reset to
    # boot from the hard disk here, or every VM built from this box will fail
    # with "Could not read from the boot medium!" since no DVD is attached.
    v.customize ["modifyvm", :id, "--boot1", "disk"]
    v.customize ["modifyvm", :id, "--boot2", "none"]
  end
end
