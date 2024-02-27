#!/bin/bash

#in ${1} - IP-address backup server

vagrant ssh client -c bash <<SHELL
sudo BORG_PASSPHRASE="Otus1234" borg init --encryption=repokey borg@${1}:/var/backup/otus_repo/
if [ $? -eq 0 ]; then
  sudo systemctl enable borg-backup.timer
  sudo systemctl start borg-backup.timer
fi

echo 'Complete!'
SHELL
