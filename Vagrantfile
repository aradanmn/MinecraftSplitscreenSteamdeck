# =============================================================================
# Vagrant VM for Minecraft Splitscreen integration testing
# =============================================================================
# Provider: libvirt (Linux) or virtualbox (Mac/Windows)
# Box: Ubuntu 24.04 LTS
#
# Quick start:
#   vagrant up                                    # first-time provision (~10 min)
#   vagrant snapshot save fresh-install           # save clean state
#   vagrant ssh -c "cd /project && sudo ./install-minecraft-splitscreen.sh"
#   vagrant snapshot restore fresh-install        # reset to clean state
#
# Run integration tests directly:
#   vagrant ssh -c "cd /project && tests/vm/run-integration.sh"
#
# SSH into the VM:
#   vagrant ssh
# =============================================================================

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"

  # Shared folder: project root is available as /project inside the VM
  config.vm.synced_folder ".", "/project", type: "rsync",
    rsync__exclude: [".git/", "tests/bats/", "tests/bats-install/"]

  # Forward SSH agent so git operations inside VM can use host credentials
  config.ssh.forward_agent = true

  # ---- libvirt (Linux host) ----
  config.vm.provider "libvirt" do |v|
    v.memory = 4096
    v.cpus   = 4
    v.video_vram = 64
  end

  # ---- VirtualBox (Mac/Windows host) ----
  config.vm.provider "virtualbox" do |v|
    v.memory = 4096
    v.cpus   = 4
    v.customize ["modifyvm", :id, "--vram", "64"]
  end

  # Run provision script once on first `vagrant up`
  config.vm.provision "shell", path: "tests/vm/provision.sh"
end
