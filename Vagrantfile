# -*- mode: ruby -*- 
# vi: set ft=ruby : vsa
Vagrant.require_version ">= 2.0.0"

require 'json'

f = JSON.parse(File.read(File.join(File.dirname(__FILE__), 'config.json')))
# Локальная переменная PATH_SRC для монтирования
$PathSrc = ENV['PATH_SRC'] || "."

Vagrant.configure(2) do |config|
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
  end

  # включить переадресацию агента ssh
  config.ssh.forward_agent = true
  # использовать стандартный для vagrant ключ ssh
  config.ssh.insert_key = false

  # Удалить открытую часть ключевой пары при уничтожении клиентской машины
  # https://developer.hashicorp.com/vagrant/docs/triggers/configuration#only_on
  config.trigger.after :destroy do |t|
    t.only_on = "client"
    t.info = "Delete public cert"
    t.run = {inline: "bash -c 'if [ -f ./provisioning/files/id_rsa.pub ]; then rm ./provisioning/files/id_rsa.pub; fi'"}
  end

  backup_ip = 0
  f.each do |i|
    if i['name'].eql? "backup"
      backup_ip = i['ip_addr']
    end
  end

  last_vm = f[(f.length)-1]['name']

  config.trigger.after :up do |triggerAfterUp|
    triggerAfterUp.only_on = last_vm
    triggerAfterUp.info = "Create remote borg repository"
    triggerAfterUp.run = { path: "./provisioning/files/client/init_borg.sh", args: "#{backup_ip}" }
  end

  f.each do |g|

    config.vm.define g['name'] do |s|
      s.vm.box = g['box']
      s.vm.hostname = g['name']
      s.vm.network 'private_network', ip: g['ip_addr']

      if g['forward_port']
        s.vm.network 'forwarded_port', guest: g['forward_port'], host: g['forward_port']
      end

      s.vm.synced_folder $PathSrc, "/vagrant", disabled: g['no_share']

      s.vm.provider :virtualbox do |virtualbox|
        virtualbox.customize [
          "modifyvm",             :id,
          "--audio",              "none",
          "--cpus",               g['cpus'],
          "--memory",             g['memory'],
          "--graphicscontroller", "VMSVGA",
          "--vram",               "64"
        ]

        attachController = false

        if g['disks']
          g['disks'].each do |dname, dconf|
            unless File.exist? (dconf['dfile'])
              attachController = true
              virtualbox.customize [
                'createhd',
                '--filename', dconf['dfile'],
                '--variant',  'Fixed',
                '--size',     dconf['size']
              ]
            end
          end
          if attachController == true
            virtualbox.customize [
              "storagectl", :id,
              "--name",     "SAS Controller",
              "--add",      "sas"
            ]
          end
          g['disks'].each do |dname, dconf|
            virtualbox.customize [
              'storageattach', :id,
              '--storagectl',  'SAS Controller',
              '--port',        dconf['port'],
              '--device',      0,
              '--type',        'hdd',
              '--medium',      dconf['dfile']
            ]
          end
        end
        virtualbox.gui = g['gui']
        virtualbox.name = g['name']
      end
      s.vm.provision "ansible" do |ansible|
        ansible.playbook = "provisioning/playbook.yml"
        ansible.become = "true"
      end
      if g['name'].eql? "backup"
        s.vm.provision "shell", inline: <<-SHELL
          if [ -b /dev/sdb ] && [ ! -b /dev/sdb1 ]; then
            parted -s /dev/sdb mklabel gpt
            parted /dev/sdb mkpart primary ext4 0% 100%

            if [ $? -eq 0 ]; then
              mkfs.ext4 /dev/sdb1
              partid=`blkid -o export /dev/sdb1 | grep PARTUUID`
              echo "${partid} /var/backup ext4 noatime 0 0" >> /etc/fstab
              mount /var/backup
              mkdir /var/backup/otus_repo
              chown borg:borg /var/backup/otus_repo
            fi
          fi
        SHELL
      end
    end
  end
end
