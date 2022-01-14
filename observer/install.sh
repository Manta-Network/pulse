#!/usr/bin/env bash

mkdir -p ${HOME}/{.local/{bin,share/mongo},.ssh}

curl -sLo ${HOME}/.local/bin/observe.sh https://raw.githubusercontent.com/Manta-Network/pulse/main/observer/observe.sh
chmod +x ${HOME}/.local/bin/observe.sh
sudo semanage fcontext -m -t bin_t -s system_u ${HOME}/.local/bin/observe.sh
sudo restorecon -vF ${HOME}/.local/bin/observe.sh

sudo curl -sLo /etc/yum.repos.d/mongodb-org-4.4.repo https://raw.githubusercontent.com/Manta-Network/pulse/main/observer/mongodb-org-4.4.repo

sudo dnf install -y mongodb-org-shell

if [ ! -s ${HOME}/.local/share/mongo/X509-cert-6160546126728082096.pem ]; then
  echo "mongo credential cert is missing (${HOME}/.local/share/mongo/X509-cert-6160546126728082096.pem)"
else
  chmod 600 ${HOME}/.local/share/mongo/X509-cert-6160546126728082096.pem
fi
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

sudo curl -sLo /etc/systemd/system/manta-node-observe.service https://raw.githubusercontent.com/Manta-Network/pulse/main/observer/observe.service
sudo systemctl enable --now manta-node-observe.service
