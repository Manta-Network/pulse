#!/usr/bin/env bash

# usage:
# curl -sLH 'Cache-Control: no-cache, no-store' https://raw.githubusercontent.com/Manta-Network/pulse/main/maintainer/validate-certs.sh | bash

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
    cert_domains=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'sudo certbot certificates 2>/dev/null | grep Domains:' | sed -r 's/Domains: //g') )
    if [ "${cert_domains[0]}" = "${fqdn}" ]; then
      echo "[${endpoint_name}/${region}/${fqdn}] \e[32m${cert_domains[0]}\e[0m"
    else
      echo "[${endpoint_name}/${region}/${fqdn}] \e[91m${cert_domains[0]}\e[0m"
    fi
  done
done
