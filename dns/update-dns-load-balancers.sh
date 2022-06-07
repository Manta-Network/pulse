#!/usr/bin/env bash

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
config_dir=${script_dir}/../config

_decode_property() {
  echo ${1} | base64 --decode | jq -r ${2}
}

aws route53 list-health-checks --profile pelagos-ops > /tmp/health-checks.json

for domain in calamari.systems manta.systems rococo.dolphin.engineering; do
  tld=$(echo ${domain} | rev | cut -d '.' -f1-2 | rev)
  hosted_zone_id=$(basename $(aws route53 list-hosted-zones --profile pelagos-ops | jq --arg tld ${tld}. -r '.HostedZones[] | select(.Name == $tld) | .Id'))
  echo "- ${domain} (tld: ${tld}, zone: ${hosted_zone_id})"
  if [ -f ${config_dir}/ws.${domain}.json ]; then
    changes_as_base64=( $(jq -r '.Changes[] | @base64' ${config_dir}/ws.${domain}.json) )
    for x in ${changes_as_base64[@]}; do
      hostname=$(_decode_property ${x} .ResourceRecordSet.SetIdentifier)
      echo "  - ${hostname}.${domain}"
      health_check_id=$(
        jq -r \
          --arg rpc_fqdn rpc.${hostname}.${domain} \
          '
            .HealthChecks[]
            | select(.HealthCheckConfig.FullyQualifiedDomainName == $rpc_fqdn)
            | .Id
          ' \
          /tmp/health-checks.json
      )
      echo "    - health check id: ${health_check_id}"
      if jq \
        --arg identifier ${hostname} \
        --arg health_check_id ${health_check_id} \
        '
          (
            .Changes[]
            | select(.ResourceRecordSet.SetIdentifier == $identifier)
            | .ResourceRecordSet.HealthCheckId
          )
          |= $health_check_id
        ' \
        ${config_dir}/ws.${domain}.json \
        > /tmp/ws.${domain}.json; then
        rm ${config_dir}/ws.${domain}.json
        mv /tmp/ws.${domain}.json ${config_dir}/ws.${domain}.json
      fi
      is_collator=$(
        yq \
          --arg job "$(echo ${tld} | cut -d '.' -f1) invulnerable collator (ssl)" \
          --arg fqdn ${hostname}.${domain} \
          '.scrape_configs[] | select (.job_name == $job) | any(.static_configs[0].targets[] == $fqdn; .)' \
          ${config_dir}/prometheus.yml
      )
      if [ ${is_collator} = true ]; then
        weight=30
      else
        weight=200
      fi
      echo "    - weight: ${weight}"
      if jq \
        --arg identifier ${hostname} \
        --arg weight ${weight} \
        '
          (
            .Changes[]
            | select(.ResourceRecordSet.SetIdentifier == $identifier)
            | .ResourceRecordSet.Weight
          )
          |= ($weight | tonumber)
        ' \
        ${config_dir}/ws.${domain}.json \
        > /tmp/ws.${domain}.json; then
        rm ${config_dir}/ws.${domain}.json
        mv /tmp/ws.${domain}.json ${config_dir}/ws.${domain}.json
      fi
    done
    aws route53 change-resource-record-sets \
      --profile pelagos-ops \
      --hosted-zone-id ${hosted_zone_id} \
      --change-batch=file://${config_dir}/ws.${domain}.json
  fi
done
