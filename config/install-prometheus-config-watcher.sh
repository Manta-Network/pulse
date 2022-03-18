#!/usr/bin/env bash

sudo curl -sLo /usr/local/bin/prometheus-config-watcher.sh https://raw.githubusercontent.com/Manta-Network/pulse/main/config/prometheus-config-watcher.sh
sudo chmod +x /usr/local/bin/prometheus-config-watcher.sh
sudo curl -sLo /etc/systemd/system/prometheus-config-watcher.service https://raw.githubusercontent.com/Manta-Network/pulse/main/config/prometheus-config-watcher.service
sudo systemctl enable -now prometheus-config-watcher.service
journalctl -u prometheus-config-watcher.service -f
