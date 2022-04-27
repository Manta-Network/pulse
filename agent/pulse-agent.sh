#!/usr/bin/env bash

sha=$(curl -s https://api.github.com/repos/Manta-Network/pulse/commits/main | jq -r .sha)
curl \
  -sLH 'Cache-Control: no-cache, no-store' \
  https://raw.githubusercontent.com/Manta-Network/pulse/${sha/null/main}/agent/pulse.sh | bash
