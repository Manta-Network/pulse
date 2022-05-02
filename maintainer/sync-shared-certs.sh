#!/usr/bin/env bash

# usage:
# curl -sLH 'Cache-Control: no-cache, no-store' https://raw.githubusercontent.com/Manta-Network/pulse/main/maintainer/sync-shared-certs.sh | bash -s --dry-run

declare -A endpoint_prefix=()
endpoint_prefix+=( [ops]=7p1eol9lz4 )
endpoint_prefix+=( [dev]=mab48pe004 )
endpoint_prefix+=( [service]=l7ff90u0lf )
endpoint_prefix+=( [prod]=hzhmt0krm0 )

_decode_property() {
  echo ${1} | base64 --decode | jq -r ${2}
}

for endpoint_name in "${!endpoint_prefix[@]}"; do
  endpoint_url=https://${endpoint_prefix[${endpoint_name}]}.execute-api.us-east-1.amazonaws.com/prod/instances
  instances_as_base64=( $(curl -sL ${endpoint_url} | jq -r '.instances[] | @base64') )
  for x in ${instances_as_base64[@]}; do
    fqdn=$(_decode_property ${x} .fqdn)
    domain=$(_decode_property ${x} .domain)
    for cert in rpc.${domain} ws.${domain}; do
      for lifecycle in archive live; do
        if sudo test -d /etc/letsencrypt/${lifecycle}/${cert}; then
          if ! diff <(ssh -i /home/mobula/.ssh/id_manta_ci -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new mobula@${fqdn} sudo ls -R /etc/letsencrypt/${lifecycle}/${cert}) <(sudo ls -R /etc/letsencrypt/${lifecycle}/${cert}) &>/dev/null; then
            if sudo rsync \
              --archive \
              --compress \
              --delete \
              --human-readable \
              --progress \
              --rsync-path='sudo rsync' \
              --verbose \
              -e 'ssh -i /home/mobula/.ssh/id_manta_ci' \
              /etc/letsencrypt/${lifecycle}/${cert}/ \
              mobula@${fqdn}:/etc/letsencrypt/${lifecycle}/${cert}; then
              echo -e "\e[93msynced ${fqdn}:/etc/letsencrypt/${lifecycle}/${cert}\e[0m"
            else
              echo -e "\e[91mfailed to synced ${fqdn}:/etc/letsencrypt/${lifecycle}/${cert}\e[0m"
            fi
          else
            echo -e "\e[32mvalidated ${fqdn}:/etc/letsencrypt/${lifecycle}/${cert}\e[0m"
          fi
        fi
      done
    done
  done
done
