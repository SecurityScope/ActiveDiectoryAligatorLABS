Vagrant.configure("2") do |config|
  config.vm.guest        = :linux
  config.vm.communicator = "ssh"
  config.ssh.username    = "vagrant"
  config.ssh.password    = "vagrant"
  config.vm.provider "virtualbox" do |v|
    v.customize ["modifyvm", :id, "--memory", "1024"]
    v.customize ["modifyvm", :id, "--cpus", "1"]
    v.customize ["modifyvm", :id, "--boot1", "disk"]
    v.customize ["modifyvm", :id, "--boot2", "none"]
  end
end
