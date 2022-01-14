#!/usr/bin/env bash

db_cert=${HOME}/.local/share/mongo/X509-cert-6160546126728082096.pem
db_host=cluster0.l9bsv.mongodb.net
db_name=observation
db_connection="mongodb+srv://${db_host}/${db_name}?authSource=%24external&authMechanism=MONGODB-X509&retryWrites=true&w=majority"
declare -A endpoint_prefix=( [ops]=7p1eol9lz4 [dev]=mab48pe004 [service]=l7ff90u0lf [prod]=hzhmt0krm0 )
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
temp_dir=$(mktemp -d)

_decode_property() {
  echo ${1} | base64 --decode | jq -r ${2}
}

if mongo --quiet --tls --tlsCertificateKeyFile ${db_cert} ${db_connection} < ${script_dir}/remove-expired-observations.js > ${temp_dir}/remove-expired-observations.result.json; then
  echo "expired observations removed"
  jq -c . ${temp_dir}/remove-expired-observations.result.json
else
  echo "failed to remove expired observations"
fi

for endpoint_name in "${!endpoint_prefix[@]}"; do
  endpoint_url=https://${endpoint_prefix[${endpoint_name}]}.execute-api.us-east-1.amazonaws.com/prod/instances
  instances_as_base64=( $(curl -sL ${endpoint_url} | jq -r '.instances[] | @base64') )
  observed=$(date --iso=seconds)
  echo "- observed ${#instances_as_base64[@]} running instances in aws ${endpoint_name} account"
  for x in ${instances_as_base64[@]}; do
    hostname=$(_decode_property ${x} .hostname)
    domain=$(_decode_property ${x} .domain)
    fqdn=$(_decode_property ${x} .fqdn)
    launch=$(_decode_property ${x} .launch)
    machine=$(_decode_property ${x} .machine)
    instance_status=$(_decode_property ${x} .state)
    region=$(_decode_property ${x} .region)
    instance_ip=$(_decode_property ${x} .ip)

    ssh_status=$(ssh -i ${HOME}/.ssh/id_manta_ci -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new mobula@${fqdn} exit 2>&1 1>/dev/null)
    if [ -n "${ssh_status}" ] ; then
      unit='"[]"'
      echo ${ssh_status}
    else
      ssh_status=active
      unit=$(ssh -i ${HOME}/.ssh/id_manta_ci -o ConnectTimeout=3 mobula@${fqdn} 'systemctl list-units --type service --full --all --plain --no-legend --no-pager' | sed 's/ \{1,\}/,/g' | jq --raw-input --slurp '
        [
          split("\n")
          | map(split(","))
          | .[0:-1]
          | map( { "unit": .[0], "load": .[1], "active": .[2], "sub": .[3] } )
          | .[]
          | select(
              (.unit | startswith("calamari"))
              or (.unit | startswith("manta"))
              or (.unit | startswith("dolphin"))
              or (.unit | startswith("baikal"))
              or (.unit | startswith("como"))
              or (.unit | startswith("tahoe"))
              or (.unit | startswith("nginx"))
              or (.unit | startswith("telemetry"))
              or (.unit | startswith("alertmanager"))
              or (.unit | startswith("prometheus"))
            )
        ] | tostring')
    fi
    

    # todo: check security groups for unexpected open ports

    echo "  - ${fqdn}"
    mongo --quiet --tls --tlsCertificateKeyFile ${db_cert} ${db_connection} <<EOF
db.node.updateOne(
  { fqdn: "${fqdn}" },
  {
    \$set: {
      fqdn: "${fqdn}",
      hostname: "${hostname}",
      domain: "${domain}",
      ip: "${instance_ip}",
      machine: "${machine}",
      launch: "${launch}",
      region: "${region}",
      account_alias: "manta-${endpoint_name}"
    },
    \$push: {
      observations: {
        time: new ISODate("${observed}"),
        status: {
          instance: "${instance_status}",
          ssh: "${ssh_status@Q}",
          dns_ip: "$(getent hosts ${fqdn} | head -n1 | cut -d " " -f1)"
        },
        unit: JSON.parse("${unit:1:${#unit}-2}")
      }
    }
  },
  { upsert: true }
)
EOF
  done
done
# todo: check if any previously existing instances did not show up in the running instance lists and create a status to reflect the missing state
