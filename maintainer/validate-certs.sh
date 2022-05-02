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
    region=$(_decode_property ${x} .region)
    cert_domains=( $(ssh -i /home/mobula/.ssh/id_manta_ci -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new mobula@${fqdn} "sudo certbot certificates 2>/dev/null | grep 'Domains:' | sed -r 's/Domains: //g'") )
    if [ "${cert_domains[0]}" = "${fqdn}" ]; then
      echo -e "[${endpoint_name}/${region}/${fqdn}] \e[32m${cert_domains[0]}\e[0m"
    elif [ ${#cert_domains[@]} -eq 0 ]; then
      last_certbot_rate_limit=$(ssh -i /home/mobula/.ssh/id_manta_ci mobula@${fqdn} 'sudo cat /var/log/letsencrypt/letsencrypt.log | egrep ":ERROR:certbot.log:There were too many requests of a given type" | cut -d"," -f1 | tail -1')
      if [ -n "${last_certbot_rate_limit}" ]; then
        days_since_rate_limit_hit=$(( ($(date +%s) - $(date --date="${last_certbot_rate_limit}" +%s) )/(60*60*24) ))
        if (( days_since_rate_limit_hit > 7 )); then
          its_ok_to_talk_to_lets_encrypt=true
          echo -e "[${endpoint_name}/${region}/${fqdn}] \e[93mcert missing. let's encrypt rate limit expiration detected\e[0m"
        else
          its_ok_to_talk_to_lets_encrypt=false
          echo -e "[${endpoint_name}/${region}/${fqdn}] \e[91mcert missing. let's encrypt rate limit hit ${days_since_rate_limit_hit} days ago (${last_certbot_rate_limit})\e[0m"
        fi
      else
        its_ok_to_talk_to_lets_encrypt=true
        echo -e "[${endpoint_name}/${region}/${fqdn}] \e[93mcert missing. no let's encrypt rate limit detected\e[0m"
      fi
    else
      echo -e "[${endpoint_name}/${region}/${fqdn}] \e[91m${cert_domains[0]}\e[0m"
    fi
  done
done
