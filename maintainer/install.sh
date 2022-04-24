#!/usr/bin/env bash

mkdir -p ${HOME}/{.aws,.local/bin,.ssh}

curl -sLo ${HOME}/.local/bin/maintain.sh https://raw.githubusercontent.com/Manta-Network/pulse/main/maintainer/maintain.sh
chmod +x ${HOME}/.local/bin/maintain.sh

sudo setsebool -P rsync_client 1
sudo semanage fcontext -m -t bin_t -s system_u ${HOME}/.local/bin/maintain.sh
sudo restorecon -vF ${HOME}/.local/bin/maintain.sh
setfacl -Rm u:root:rwx ${HOME}/.ssh
setfacl -Rm u:root:rw ${HOME}/.ssh/known_hosts

sudo dnf install -y \
  certbot \
  curl \
  jq \
  python3-certbot-dns-route53 \
  python3-pip
sudo pip install \
  awscli \
  yq

if [ ! -s ${HOME}/.ssh/id_manta_ci.pub ]; then
  echo "ssh public key is missing (${HOME}/.ssh/id_manta_ci.pub)"
else
  chmod 644 ${HOME}/.ssh/id_manta_ci.pub
fi
if [ ! -s ${HOME}/.ssh/id_manta_ci ]; then
  echo "ssh private key is missing (${HOME}/.ssh/id_manta_ci)"
else
  chmod 600 ${HOME}/.ssh/id_manta_ci
fi
ssh-add ${HOME}/.ssh/id_manta_ci

if [ ! -s ${HOME}/.aws/credentials ]; then
  echo "aws credentials file is missing (${HOME}/.aws/credentials)"
else
  chmod 600 ${HOME}/.aws/credentials
fi

sudo curl -H 'Cache-Control: no-cache, no-store' -sLo /etc/systemd/system/manta-node-maintain.service https://raw.githubusercontent.com/Manta-Network/pulse/main/maintainer/maintain.service
sudo systemctl daemon-reload
sudo systemctl enable --now manta-node-maintain.service

sudo curl -H 'Cache-Control: no-cache, no-store' -sLo /etc/systemd/system/calamari-node-maintain.service https://raw.githubusercontent.com/Manta-Network/pulse/main/maintainer/calamari-node-maintain.service
sudo systemctl daemon-reload
sudo systemctl enable --now calamari-node-maintain.service

