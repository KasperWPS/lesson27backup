# Домашнее задание № 17 по теме: "Резервное копирование". К курсу Administrator Linux. Professional

## Задание

- Настроить стенд Vagrant с двумя виртуальными машинами:
  - backup
    - Директория для резервных копий **/var/backup**. Это должна быть отдельная точка монтирования.
    - Репозиторий для резервных копий должен быть зашифрован ключом или паролем
  - client
    - Написать скрипт для снятия резервных копий. Скрипт запускается из соответствующей Cron джобы, либо systemd timer-а
    - Настроить логирование процесса бэкапа. Если настраивать не в syslog, то обязательно организовать ротацию логов
    - Имя бэкапа должно содержать информацию о времени снятия бекапа;
    - Глубина бекапа должна быть год, хранить можно по последней копии на конец месяца, кроме последних трех. Последние три месяца должны содержать копии на каждый день. Т.е. должна быть правильно настроена политика удаления старых бэкапов
    - Резервная копия снимается каждые 5 минут. Такой частый запуск в целях демонстрации


### Выполнение

Настроен стенд vagrant (VMs: client; backup), его конфиг:
*На provisioning/files/client/init_borg.sh дать права на запуск chmod +x ./provisioning/files/client/init_borg.sh*

```json
[
        {
                "name": "client",
                "cpus": 2,
                "gui": false,
                "box": "centos/7",
                "ip_addr": "192.168.56.150",
                "memory": "1024",
                "no_share": true
        },
        {
                "name": "backup",
                "cpus": 2,
                "gui": false,
                "box": "centos/7",
                "ip_addr": "192.168.56.160",
                "memory": 1024,
                "no_share": true,
                "disks": {
                        "sata1": {
                                "dfile": "./disks/sata1.vdi",
                                "size": "2048",
                                "port": "1"
                        }
                }
        }
]
```

Vagrantfile

```ruby
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
    t.run = {inline: "bash -c 'if [ -f ./provisioning/files/id_ssh_rsa.pub ]; then rm ./provisioning/files/id_ssh_rsa.pub; fi'"}
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
```

Playbook:

```yaml
---
- hosts: all
  become: true
  gather_facts: false

  tasks:
  - name: Accept login with password from sshd
    ansible.builtin.lineinfile:
      path: /etc/ssh/sshd_config
      regexp: '^PasswordAuthentication no$'
      line: 'PasswordAuthentication yes'
      state: present
    notify:
      - Restart sshd

  - name: Install epel-release
    ansible.builtin.yum:
      name: epel-release
      state: present

  - name: Install soft
    ansible.builtin.yum:
      name:
        - vim
        - mc
        - tcpdump
        - borgbackup
      state: present

  - name: Set timezone
    community.general.timezone:
      name: Europe/Moscow
    notify:
      - Restart Chrony service

  handlers:

  - name: Restart Chrony service
    ansible.builtin.service:
      name: chronyd
      state: restarted

  - name: Restart sshd
    ansible.builtin.service:
      name: sshd
      state: restarted

- hosts: client
  become: true
  gather_facts: false

  tasks:

  - name: Create .ssh directory
    ansible.builtin.file:
      path: /root/.ssh
      state: directory

    # Только для стенда
  - name: Copy config ssh for root user
    ansible.builtin.copy:
      src: ./files/client/ssh_config
      dest: /root/.ssh/config
      mode: '0600'

  - name: Generate key-pair
    community.crypto.openssh_keypair:
      path: /root/.ssh/id_rsa
      size: 2048
    notify:
      - Fetch public cert

  - name: Copy borg-backup.service
    ansible.builtin.copy:
      src: ./files/client/borg-backup.service
      dest: /etc/systemd/system/borg-backup.service
      mode: '0640'

  - name: Copy borg-backup.timer
    ansible.builtin.copy:
      src: ./files/client/borg-backup.timer
      dest: /etc/systemd/system/borg-backup.timer
      mode: '0640'

  handlers:
  - name: Fetch public cert
    ansible.builtin.fetch:
      src: /root/.ssh/id_rsa.pub
      dest: ./files/id_rsa.pub
      flat: true

- hosts: backup
  become: true
  gather_facts: false

  tasks:

  - name: Add user borg
    ansible.builtin.user:
      name: borg

  - name: Create .ssh directory
    ansible.builtin.file:
      path: /home/borg/.ssh
      state: directory

  - name: Copy public cert
    ansible.builtin.copy:
      src: ./files/id_rsa.pub
      dest: /home/borg/.ssh/authorized_keys

  - name: Create /var/backup directory
    ansible.builtin.file:
      path: /var/backup
      # Установка прав на точку монтирования не распространяется на ФС подключаемого раздела
      # поэтому необходимо установить права на корень ФС подключаемого раздела
      # это сделано в inline shell-ptovisioner Vagrant
      owner: borg
      group: borg
      state: directory
```

После поднятия виртуалок проверяем что всё настроено по заданию:

```bash
vagrant ssh backup -c lsblk
```
```
NAME   MAJ:MIN RM SIZE RO TYPE MOUNTPOINT
sda      8:0    0  40G  0 disk
└─sda1   8:1    0  40G  0 part /
sdb      8:16   0   2G  0 disk
└─sdb1   8:17   0   2G  0 part /var/backup
```

Подключен раздел объемом 2 Гб, примонтирован на /var/backup



```bash
vagrant ssh backup -c 'ls -la /var/backup/'
```
```
total 24
drwxr-xr-x.  4 root root  4096 Feb 27 19:40 .
drwxr-xr-x. 19 root root   268 Feb 27 19:40 ..
drwx------.  2 root root 16384 Feb 27 19:40 lost+found
drwxr-xr-x.  3 borg borg  4096 Feb 28 00:22 otus_repo
```

Инициализирован репозиторий otus_repo

```bash
vagrant ssh client -c 'sudo borg list borg@192.168.56.160:/var/backup/otus_repo'
```
```
Remote: Warning: Permanently added '192.168.56.160' (ECDSA) to the list of known hosts.
Enter passphrase for key ssh://borg@192.168.56.160/var/backup/otus_repo:
etc-2024-02-27_23:59:55              Tue, 2024-02-27 23:59:57 [b353df0e1cfc2d6b7b2a1042eb0072812bfa0969eb5c6aae049fad309679a40f]
etc-2024-02-28_00:26:56              Wed, 2024-02-28 00:26:57 [50b3798d96abcb9542b1f115b8cba19cedf7ebd978b05964eccf015bf08335e7]
```

В репозитории имеются резервные копии

```bash
vagrant ssh client -c 'sudo systemctl list-timers --all'
```
```
NEXT                         LEFT     LAST                         PASSED       UNIT                         ACTIVATES
Wed 2024-02-28 00:31:55 MSK  16s ago  Wed 2024-02-28 00:32:11 MSK  93ms ago     borg-backup.timer            borg-backup.service
Wed 2024-02-28 19:50:55 MSK  19h left Tue 2024-02-27 19:50:55 MSK  4h 41min ago systemd-tmpfiles-clean.timer systemd-tmpfiles-clean.n/a                          n/a      n/a                          n/a          systemd-readahead-done.timer systemd-readahead-done.
3 timers listed.
```

Таймер systemd работает


```bash
vagrant ssh client -c 'sudo journalctl --since today'
```
```
Feb 28 00:32:11 client sudo[26658]:  vagrant : TTY=pts/0 ; PWD=/home/vagrant ; USER=root ; COMMAND=/bin/systemctl list-timers --all
Feb 28 00:32:11 client sudo[26658]: pam_unix(sudo:session): session opened for user root by vagrant(uid=0)
Feb 28 00:32:12 client borg[26656]: Remote: Warning: Permanently added '192.168.56.160' (ECDSA) to the list of known hosts.
Feb 28 00:32:13 client borg[26656]: ------------------------------------------------------------------------------
Feb 28 00:32:13 client borg[26656]: Archive name: etc-2024-02-28_00:32:12
Feb 28 00:32:13 client borg[26656]: Archive fingerprint: 5fa11414a7df98c40a09ff24542241bdfe75ee38bcdddabfbbe5c6e6ada7f601
Feb 28 00:32:13 client borg[26656]: Time (start): Wed, 2024-02-28 00:32:13
Feb 28 00:32:13 client borg[26656]: Time (end):   Wed, 2024-02-28 00:32:13
Feb 28 00:32:13 client borg[26656]: Duration: 0.44 seconds
Feb 28 00:32:13 client borg[26656]: Number of files: 1716
Feb 28 00:32:13 client borg[26656]: Utilization of max. archive size: 0%
Feb 28 00:32:13 client borg[26656]: ------------------------------------------------------------------------------
Feb 28 00:32:13 client borg[26656]: Original size      Compressed size    Deduplicated size
Feb 28 00:32:13 client borg[26656]: This archive:               28.52 MB             13.54 MB                621 B
Feb 28 00:32:13 client borg[26656]: All archives:               85.56 MB             40.62 MB             11.97 MB
Feb 28 00:32:13 client borg[26656]: Unique chunks         Total chunks
Feb 28 00:32:13 client borg[26656]: Chunk index:                    1303                 5151
Feb 28 00:32:13 client borg[26656]: ------------------------------------------------------------------------------
Feb 28 00:32:14 client borg[26697]: Remote: Warning: Permanently added '192.168.56.160' (ECDSA) to the list of known hosts.
```

Логи пишутся в systemd

```bash
vagrant ssh client -c 'sudo cat /etc/systemd/system/borg-backup.service'
```
```
[Unit]
Description=Borg Backup

[Service]
Type=oneshot

# Парольная фраза
Environment="BORG_PASSPHRASE=Otus1234"
# Репозиторий
Environment=REPO=borg@192.168.56.160:/var/backup/otus_repo/
# Что бэкапим
Environment=BACKUP_TARGET=/etc

# Создание бэкапа
ExecStart=/bin/borg create \
    --stats                \
    ${REPO}::etc-{now:%%Y-%%m-%%d_%%H:%%M:%%S} ${BACKUP_TARGET} \
    >> /var/log/borg/borg.log

# Проверка бэкапа
ExecStart=/bin/borg check ${REPO}

# Очистка старых бэкапов
ExecStart=/bin/borg prune \
    --keep-daily  90      \
    --keep-monthly 12     \
    --keep-yearly  1      \
    ${REPO}
```

- Репозиторий зашифрован паролем **Otus1234**
- Глубина бэкапа 1 год
- Хранится по последней копии на конец месяца
- Последние 3 месяца копии на каждый день



