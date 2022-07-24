#!/usr/bin/env bash

ssh_key=${HOME}/.ssh/id_manta_ci
eval `ssh-agent`
ssh-add ${ssh_key}

declare -A endpoint_prefix=()
endpoint_prefix+=( [ops]=7p1eol9lz4 )
endpoint_prefix+=( [dev]=mab48pe004 )
endpoint_prefix+=( [service]=l7ff90u0lf )
endpoint_prefix+=( [prod]=hzhmt0krm0 )

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
temp_dir=$(mktemp -d)

_decode_property() {
  echo ${1} | base64 --decode | jq -r ${2}
}

for endpoint_name in "${!endpoint_prefix[@]}"; do
  endpoint_url=https://${endpoint_prefix[${endpoint_name}]}.execute-api.us-east-1.amazonaws.com/prod/instances
  if [ -z "${1}" ]; then
    instances_as_base64=( $(curl -sL ${endpoint_url} | jq -r '.instances[] | @base64') )
  else
    instances_as_base64=( $(curl -sL ${endpoint_url} | jq -r --arg domain ${1} '.instances[] | select(.domain == $domain) | @base64') )
  fi

  echo "[${endpoint_name}] observed ${#instances_as_base64[@]} running instances in aws ${endpoint_name} account"
  for x in ${instances_as_base64[@]}; do
    id=$(_decode_property ${x} .id)
    hostname=$(_decode_property ${x} .hostname)
    domain=$(_decode_property ${x} .domain)
    fqdn=$(_decode_property ${x} .fqdn)
    launch=$(_decode_property ${x} .launch)
    machine=$(_decode_property ${x} .machine)
    instance_status=$(_decode_property ${x} .state)
    region=$(_decode_property ${x} .region)
    instance_ip=$(_decode_property ${x} .ip)
    username=mobula
    case ${domain} in
      calamari.systems)
        target_unit=calamari
        ;;
      manta.systems)
        target_unit=manta
        ;;
      rococo.dolphin.engineering)
        target_unit=dolphin
        ;;
      *)
        unset target_unit
        ;;
    esac

    if [[ ${domain} != *"telemetry"* ]] && [[ ${domain} != *"workstation"* ]]; then
      for prefix in rpc ws; do
        if sudo test -L /etc/letsencrypt/live/${prefix}.${domain}/privkey.pem &>/dev/null; then
          #rsync -e "ssh -i ${ssh_key}" --rsync-path='sudo rsync' -azP /etc/letsencrypt/archive/${prefix}.${domain}/ mobula@${fqdn}:/etc/letsencrypt/archive/${prefix}.${domain}
          local_hash=$(sudo sha256sum /etc/letsencrypt/live/${prefix}.${domain}/privkey.pem | cut -d" " -f1)
          remote_hash=$(ssh -i ${ssh_key} ${username}@${fqdn} "sudo sha256sum /etc/letsencrypt/live/${prefix}.${domain}/privkey.pem 2>/dev/null" | cut -d" " -f1)
          echo "[${endpoint_name}/${region}/${fqdn}] cert checksum (${prefix}.${domain}) local ($(hostname -f)): ${local_hash}, remote (${fqdn}): ${remote_hash}"
          if [ "${local_hash}" = "${remote_hash}" ]; then
            echo "[${endpoint_name}/${region}/${fqdn}] detected ${prefix}.${domain} certs on ${fqdn}"
          elif sudo cp -r /etc/letsencrypt/archive/${prefix}.${domain} /home/$(whoami)/ \
            && sudo chown -R $(whoami):$(whoami) /home/$(whoami)/${prefix}.${domain} \
            && scp -r /home/$(whoami)/${prefix}.${domain} mobula@${fqdn}:/home/mobula/ \
            && rm -rf /home/$(whoami)/${prefix}.${domain}; then
            echo "[${endpoint_name}/${region}/${fqdn}] copied ${prefix}.${domain} certs to ${fqdn}"
            ssh -i ${ssh_key} ${username}@${fqdn} "sudo mkdir -p /etc/letsencrypt/{archive,live}/${prefix}.${domain}"
            ssh -i ${ssh_key} ${username}@${fqdn} "sudo cp -r /home/mobula/${prefix}.${domain} /etc/letsencrypt/archive/"
            ssh -i ${ssh_key} ${username}@${fqdn} "rm -rf /home/mobula/${prefix}.${domain}"
            ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown -R root:root /etc/letsencrypt/{archive,live}/${prefix}.${domain}"
            for pem in cert chain fullchain privkey; do
              ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs $(sudo readlink -f /etc/letsencrypt/live/${prefix}.${domain}/${pem}.pem) /etc/letsencrypt/live/${prefix}.${domain}/${pem}.pem"
            done
          else
            echo "[${endpoint_name}/${region}/${fqdn}] failed to copy ${prefix}.${domain} certs to ${fqdn}"
          fi
        fi
      done
    fi
  done
done
