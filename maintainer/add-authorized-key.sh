#!/usr/bin/env bash

# usage:
# curl -sLH 'Cache-Control: no-cache, no-store' https://raw.githubusercontent.com/Manta-Network/pulse/main/maintainer/add-authorized-key.sh | bash

declare -A endpoint_prefix=()
endpoint_prefix+=( [ops]=7p1eol9lz4 )
endpoint_prefix+=( [dev]=mab48pe004 )
endpoint_prefix+=( [service]=l7ff90u0lf )
endpoint_prefix+=( [prod]=hzhmt0krm0 )

_decode_property() {
  echo ${1} | base64 --decode | jq -r ${2}
}

new_authorized_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPwoPDvoSzIU8fEFVcPIs7Kjs3x+fh/+9WIAKl0nLkq"
ssh='ssh -i /home/mobula/.ssh/id_manta_ci -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new'

for endpoint_name in "${!endpoint_prefix[@]}"; do
  endpoint_url=https://${endpoint_prefix[${endpoint_name}]}.execute-api.us-east-1.amazonaws.com/prod/instances
  instances_as_base64=( $(curl -sL ${endpoint_url} | jq -r '.instances[] | @base64') )
  for x in ${instances_as_base64[@]}; do
    fqdn=$(_decode_property ${x} .fqdn)
    domain=$(_decode_property ${x} .domain)
    region=$(_decode_property ${x} .region)
    if ${ssh} mobula@${fqdn} "grep -q '${new_authorized_key}' /home/mobula/.ssh/authorized_keys"; then
      echo -e "[${endpoint_name}/${region}/${fqdn}] \e[32mdetected\e[0m"
    #elif ${ssh} mobula@${fqdn} "echo ${new_authorized_key} >> /home/mobula/.ssh/authorized_keys"; then
    $  echo -e "[${endpoint_name}/${region}/${fqdn}] \e[93madded\e[0m"
    else
      echo -e "[${endpoint_name}/${region}/${fqdn}] \e[91merrored\e[0m"
    fi
  done
done
