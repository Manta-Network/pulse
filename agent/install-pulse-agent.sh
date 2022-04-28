#!/usr/bin/env bash

# usage:
# curl -sLH 'Cache-Control: no-cache, no-store' https://raw.githubusercontent.com/Manta-Network/pulse/main/agent/install-pulse-agent.sh | bash

if ! getent group pulse > /dev/null 2>&1; then
  sudo groupadd --system pulse
  echo "groupadd pulse, result: $?"
fi
if ! getent passwd pulse > /dev/null 2>&1; then
  sudo useradd \
    --system \
    --gid pulse \
    --groups $(getent group wheel > /dev/null 2>&1 && echo wheel || echo sudo) \
    --create-home \
    --shell /sbin/nologin \
    --comment 'pulse agent service account' \
    pulse
  echo "useradd pulse, result: $?"
fi
sudo sh -c 'echo "pulse ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-pulse-daemon'

systemctl is-active --quiet pulse-agent.service && sudo systemctl stop pulse-agent.service
sudo curl \
  -sLo /etc/systemd/system/pulse-agent.service \
  https://raw.githubusercontent.com/Manta-Network/pulse/main/agent/pulse-agent.service

sudo curl \
  -sLo /usr/local/bin/pulse-agent.sh \
  https://raw.githubusercontent.com/Manta-Network/pulse/main/agent/pulse-agent.sh
sudo chmod +x /usr/local/bin/pulse-agent.sh

systemctl is-enabled --quiet pulse-agent.service || sudo systemctl enable pulse-agent.service
sudo systemctl start pulse-agent.service
