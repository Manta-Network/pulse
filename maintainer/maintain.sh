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
_ipv4dec() {
  for i; do
    echo $i | {
      IFS=./
      read a b c d e
      test -z "$e" && e=32
      echo -n "$((a<<24|b<<16|c<<8|d)) $((-1<<(32-e))) "
    }
  done
}
_ipv4_network_includes() {
  _ipv4dec $2 $1 | {
    read addr1 mask1 addr2 mask2
    if (( (addr1&mask2) == (addr2&mask2) && mask1 >= mask2 )); then
      true
    else
      false
    fi
  }
}
function _join_by {
  local d=${1-} f=${2-}
  if shift 2; then
    printf %s "$f" "${@/#/$d}"
  fi
}

upsert_cname() {
  local prefix=${1}
  local fqdn=${2}
  local tld=${3}
  local hosted_zone_id=$(basename $(aws route53 list-hosted-zones --profile pelagos-ops | jq --arg tld ${tld}. -r '.HostedZones[] | select(.Name == $tld) | .Id'))
  if ! getent hosts ${prefix}.${fqdn}; then
    echo '{
      "Changes": [
        {
          "Action": "UPSERT",
          "ResourceRecordSet": {
            "Name": "",
            "Type": "CNAME",
            "TTL": 300,
            "ResourceRecords": [
              {
                "Value": ""
              }
            ]
          }
        }
      ]
    }' | jq --arg cname ${prefix}.${fqdn} --arg fqdn ${fqdn} '. | .Changes[0].ResourceRecordSet.Name = $cname | .Changes[0].ResourceRecordSet.ResourceRecords[0].Value = $fqdn' > ${temp_dir}/${prefix}.${fqdn}.json
    aws route53 change-resource-record-sets \
      --profile pelagos-ops \
      --hosted-zone-id ${hosted_zone_id} \
      --change-batch=file://${temp_dir}/${prefix}.${fqdn}.json
    sleep 30
  fi
}

# fetch list of existing health checks
aws route53 list-health-checks --profile pelagos-ops > ${temp_dir}/health-checks.json

# fetch ws-ssl (nginx) configuration
curl -sLo ${temp_dir}/ssl.conf https://raw.githubusercontent.com/Manta-Network/pulse/main/maintainer/ssl.conf

for endpoint_name in "${!endpoint_prefix[@]}"; do
  endpoint_url=https://${endpoint_prefix[${endpoint_name}]}.execute-api.us-east-1.amazonaws.com/prod/instances
  instances_as_base64=( $(curl -sL ${endpoint_url} | jq -r '.instances[] | @base64') )
  required_ssh_ingress_subnets=( $(curl -sL https://raw.githubusercontent.com/Manta-Network/pulse/main/config/ingress.yml | yq -r --arg endpoint ${endpoint_name} '.[$endpoint].subnet.required[]') )
  optional_ssh_ingress_subnets=( $(curl -sL https://raw.githubusercontent.com/Manta-Network/pulse/main/config/ingress.yml | yq -r --arg endpoint ${endpoint_name} '.[$endpoint].subnet.optional[]') )
  allowed_ssh_ingress_subnets=( "${required_ssh_ingress_subnets[@]}" "${optional_ssh_ingress_subnets[@]}" )

  echo "observed ${#instances_as_base64[@]} running instances in aws ${endpoint_name} account"
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
    detected_ssh_ingress_subnets_path=${temp_dir}/ssh_ingress_subnets-${fqdn}.json
    detected_authorized_keys_path=${temp_dir}/authorized_keys-${fqdn}-${username}
    profile=pelagos-${endpoint_name}
    security_group_ids=$(aws ec2 describe-instances \
      --profile ${profile} \
      --region ${region} \
      --instance-id ${id} \
      --query 'Reservations[].Instances[].SecurityGroups[].GroupId[]' \
      --output text)
    aws ec2 describe-security-groups \
      --profile ${profile} \
      --region ${region} \
      --group-ids ${security_group_ids} \
      --query 'SecurityGroups[*].{ name: GroupName, id: GroupId, ingress: IpPermissions[?ToPort==`22`].IpRanges[*].CidrIp }' \
      --filters Name=ip-permission.from-port,Values=22 Name=ip-permission.to-port,Values=22 | jq --arg region ${region} '[.[] | { id, name, region: $region, ingress }]' > ${detected_ssh_ingress_subnets_path}
    security_groups_as_base64=( $(jq -r '.[] | @base64' ${detected_ssh_ingress_subnets_path}) )

    for y in ${security_groups_as_base64[@]}; do
      security_group_id=$(_decode_property ${y} .id)
      detected_ssh_ingress_subnets=( $(_decode_property ${y} .ingress[0] | jq -r '.[]') )

      # grant ingress access for required subnets
      for required_ssh_ingress_subnet in ${required_ssh_ingress_subnets[@]}; do
        required_ssh_ingress_subnet_is_included=false
        for detected_ssh_ingress_subnet in ${detected_ssh_ingress_subnets[@]}; do
          if _ipv4_network_includes ${detected_ssh_ingress_subnet} ${required_ssh_ingress_subnet}; then
            required_ssh_ingress_subnet_is_included=true
          fi
        done
        if [ "${required_ssh_ingress_subnet_is_included}" = true ]; then
          echo "detected required ssh ingress subnet: ${required_ssh_ingress_subnet} in manta-${endpoint_name}/${region}/${security_group_id}"
        else
          auth_result_path=${temp_dir}/authorize-ssh-ingress-${security_group_id}-$(uuidgen).json
          if aws ec2 authorize-security-group-ingress \
            --profile ${profile} \
            --region ${region} \
            --group-id ${security_group_id} \
            --protocol tcp \
            --port 22 \
            --cidr ${required_ssh_ingress_subnet} > ${auth_result_path} && [ "$(jq -r '.Return' ${auth_result_path})" = "true" ]; then
            echo "  granted ssh access for required ingress subnet: ${required_ssh_ingress_subnet} in manta-${endpoint_name}/${region}/${security_group_id}"
          else
            echo "  failed to grant ssh access for required ingress subnet: ${required_ssh_ingress_subnet} in manta-${endpoint_name}/${region}/${security_group_id}"
          fi
        fi
        if aws ec2 authorize-security-group-ingress \
            --profile ${profile} \
            --region ${region} \
            --group-id ${security_group_id} \
            --protocol tcp \
            --port 80 \
            --cidr 0.0.0.0/0; then
          echo "  granted http access on manta-${endpoint_name}/${region}/${security_group_id}"
        else
          echo "  failed to grant http access on manta-${endpoint_name}/${region}/${security_group_id}"
        fi
      done

      # revoke (or alert for non-prod) ingress access for disallowed subnets
      for detected_ssh_ingress_subnet in ${detected_ssh_ingress_subnets[@]}; do
        is_allowed_ssh_ingress_subnet=false
        #echo "${allowed_ssh_ingress_subnets[@]}"
        for allowed_ssh_ingress_subnet in ${allowed_ssh_ingress_subnets[@]}; do
          #echo "checking if ${allowed_ssh_ingress_subnet} contains ${detected_ssh_ingress_subnet}"
          if _ipv4_network_includes ${allowed_ssh_ingress_subnet} ${detected_ssh_ingress_subnet}; then
            is_allowed_ssh_ingress_subnet=true
          fi
        done
        if [ "${is_allowed_ssh_ingress_subnet}" = true ] ; then
          echo "detected allowed ssh ingress subnet: ${detected_ssh_ingress_subnet} in manta-${endpoint_name}/${region}/${security_group_id}"
        else
          case ${endpoint_name} in
            prod)
            if aws ec2 revoke-security-group-ingress \
              --profile ${profile} \
              --region ${region} \
              --group-id ${security_group_id} \
              --protocol tcp \
              --port 22 \
              --cidr ${detected_ssh_ingress_subnet} &> /dev/null; then
              echo "  revoked ssh access for disallowed ingress subnet: ${detected_ssh_ingress_subnet} from manta-${endpoint_name}/${region}/${security_group_id}"
            else
              echo "  failed to revoke ssh access for disallowed ingress subnet: ${detected_ssh_ingress_subnet} from manta-${endpoint_name}/${region}/${security_group_id}"
            fi
            # todo: discord security alert
            ;;
            *)
            echo "detected disallowed ssh ingress subnet: ${detected_ssh_ingress_subnet} in manta-${endpoint_name}/${region}/${security_group_id}"
            # todo: discord security alert
            ;;
          esac
        fi
      done
    done
    if ssh -i ${ssh_key} -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new ${username}@${fqdn} "cat /home/${username}/.ssh/authorized_keys" > ${detected_authorized_keys_path} && [ -s ${detected_authorized_keys_path} ]; then
      echo "fetched ${detected_authorized_keys_path}"
    else
      rm ${detected_authorized_keys_path}
    fi
    if [[ ${domain} != *"telemetry"* ]] && [[ ${domain} != *"workstation"* ]]; then
      health_check_id=$(jq --arg fqdn rpc.${fqdn} '.HealthChecks[] | select(.HealthCheckConfig.FullyQualifiedDomainName == $fqdn) | .Id' ${temp_dir}/health-checks.json)
      if [ -n "${health_check_id}" ]; then
        echo "detected existing health check: rpc.${fqdn}"
      else
        echo '{
          "Port": 443,
          "Type": "HTTPS",
          "ResourcePath": "/health",
          "RequestInterval": 30,
          "FailureThreshold": 3,
          "MeasureLatency": true,
          "EnableSNI": true
        }' | jq \
          --arg fqdn rpc.${fqdn} \
          '
            .
            | .FullyQualifiedDomainName = $fqdn
          ' > ${temp_dir}/health-check-${fqdn}.json
        if aws route53 create-health-check \
          --profile pelagos-ops \
          --caller-reference rpc.${fqdn} \
          --health-check-config file://${temp_dir}/health-check-${fqdn}.json; then
          echo "created health check: rpc.${fqdn}"
        else
          echo "failed to create health check: rpc.${fqdn}"
        fi
      fi

      # dns for unique rpc fqdn
      upsert_cname rpc ${fqdn} ${domain}

      manta_service_units=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'systemctl list-units --type service --full --all --plain --no-legend --no-pager' | grep -E 'calamari|dolphin|manta' | cut -d " " -f1) )
      # todo: request the specific unit of interest rather than any of calamari/dolphin/manta
      manta_service_unit_file_path=$(ssh -i ${ssh_key} ${username}@${fqdn} "systemctl status ${manta_service_units[0]}" | grep -Po "/[a-z/]*/${manta_service_units[0]}")
      manta_service_rpc_port=$(ssh -i ${ssh_key} ${username}@${fqdn} "cat ${manta_service_unit_file_path}" | grep " --rpc-port " | grep -Eo "[0-9]{4}")
      if [ -z "${manta_service_rpc_port}" ]; then
        manta_service_rpc_port=9933
      fi
      manta_service_ws_port=$(ssh -i ${ssh_key} ${username}@${fqdn} "cat ${manta_service_unit_file_path}" | grep " --ws-port " | grep -Eo "[0-9]{4}")
      if [ -z "${manta_service_ws_port}" ]; then
        manta_service_ws_port=9944
      fi

      # nginx config for unique ws cert/fqdn
      ssh -i ${ssh_key} ${username}@${fqdn} "sudo sed -i 's/localhost:9944/localhost:${manta_service_ws_port}/g' /etc/nginx/sites-available/default-ssl"

      # nginx config for unique rpc cert/fqdn
      sed "s/PORT/${manta_service_rpc_port}/g" ${temp_dir}/ssl.conf > ${temp_dir}/rpc.${fqdn}.conf
      sed -i "s/SERVER_NAME/rpc.${fqdn}/g" ${temp_dir}/rpc.${fqdn}.conf
      sed -i "s/CERT_NAME/${fqdn}/g" ${temp_dir}/rpc.${fqdn}.conf
      ssh -i ${ssh_key} ${username}@${fqdn} 'sudo rm -f /etc/nginx/sites-available/rpc-proxy /etc/nginx/sites-enabled/rpc'

      #rsync -e "ssh -i ${ssh_key}" --rsync-path='sudo rsync' -vz ${temp_dir}/rpc.${fqdn}.conf mobula@${fqdn}:/etc/nginx/sites-available/
      scp ${temp_dir}/rpc.${fqdn}.conf mobula@${fqdn}:/home/mobula/rpc.${fqdn}.conf
      ssh -i ${ssh_key} ${username}@${fqdn} "sudo mv /home/mobula/rpc.${fqdn}.conf /etc/nginx/sites-available/rpc.${fqdn}.conf"
      ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown root:root /etc/nginx/sites-available/rpc.${fqdn}.conf"
      ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs /etc/nginx/sites-available/rpc.${fqdn}.conf /etc/nginx/sites-enabled/rpc.${fqdn}.conf"

      cert_domains=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'sudo certbot certificates | grep Domains:' | sed -r 's/Domains: //g') )
      if [[ " ${cert_domains[*]} " =~ " rpc.${fqdn} " ]]; then
        echo "detected rpc.${fqdn} in cert domains (${cert_domains[@]})"
      else
        cert_domains+=( rpc.${fqdn} )
        echo "adding rpc.${fqdn} to cert domains (${cert_domains[@]})"
        ssh -i ${ssh_key} ${username}@${fqdn} 'sudo ln -frs /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default'
        ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
        ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot certonly --expand --agree-tos --no-eff-email --preferred-challenges http --webroot -w /var/www/html -m ops@manta.network -d $(_join_by ' -d ' ${cert_domains[@]})"
        ssh -i ${ssh_key} ${username}@${fqdn} 'sudo ln -frs /etc/nginx/sites-available/default-ssl /etc/nginx/sites-enabled/default'
        ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
      fi

      # shared rpc/ws cert/fqdn
      sed "s/PORT/${manta_service_ws_port}/g" ${temp_dir}/ssl.conf > ${temp_dir}/ws-ssl.conf
      sed "s/PORT/${manta_service_rpc_port}/g" ${temp_dir}/ssl.conf > ${temp_dir}/rpc-ssl.conf
      for prefix in rpc ws; do
        if sudo test -L /etc/letsencrypt/live/${prefix}.${domain}/privkey.pem && sudo test -e /etc/letsencrypt/live/${prefix}.${domain}/privkey.pem; then
          #rsync -e "ssh -i ${ssh_key}" --rsync-path='sudo rsync' -azP /etc/letsencrypt/archive/${prefix}.${domain}/ mobula@${fqdn}:/etc/letsencrypt/archive/${prefix}.${domain}
          scp -r /etc/letsencrypt/archive/${prefix}.${domain} mobula@${fqdn}:/home/mobula/
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo cp -r /home/mobula/${prefix}.${domain} /etc/letsencrypt/archive/"
          ssh -i ${ssh_key} ${username}@${fqdn} "rm -rf /home/mobula/${prefix}.${domain}"
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown -R root:root /etc/letsencrypt/archive/${prefix}.${domain}"
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo mkdir -p /etc/letsencrypt/live/${prefix}.${domain}"
          for pem in cert chain fullchain privkey; do
            ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs $(readlink -f /etc/letsencrypt/live/${prefix}.${domain}/${pem}.pem) /etc/letsencrypt/live/${prefix}.${domain}/${pem}.pem"
          done
          #rsync -e "ssh -i ${ssh_key}" --rsync-path='sudo rsync' -azP /etc/letsencrypt/live/${prefix}.${domain}/ mobula@${fqdn}:/etc/letsencrypt/live/${prefix}.${domain}
          # create nginx shared fqdn config
          sed "s/SERVER_NAME/${prefix}.${domain}/g" ${temp_dir}/${prefix}-ssl.conf > ${temp_dir}/${prefix}.${domain}.conf
          sed -i "s/CERT_NAME/${prefix}.${domain}/g" ${temp_dir}/${prefix}.${domain}.conf
          #rsync -e "ssh -i ${ssh_key}" --rsync-path='sudo rsync' -vz ${temp_dir}/${prefix}.${domain}.conf mobula@${fqdn}:/etc/nginx/sites-available/
          scp ${temp_dir}/${prefix}.${domain}.conf mobula@${fqdn}:/home/mobula/${prefix}.${domain}.conf
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo mv /home/mobula/${prefix}.${domain}.conf /etc/nginx/sites-available/${prefix}.${domain}.conf"
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown root:root /etc/nginx/sites-available/${prefix}.${domain}.conf"
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs /etc/nginx/sites-available/${prefix}.${domain}.conf /etc/nginx/sites-enabled/${prefix}.${domain}.conf"
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
        fi
      done

      # metrics
      if ssh ${username}@${fqdn} 'curl --head http://localhost:9616/metrics &> /dev/null' && ssh ${username}@${fqdn} 'curl --head http://localhost:9615/metrics &> /dev/null'; then

        # relay dns for metrics
        upsert_cname relay.metrics ${fqdn} ${domain}

        # nginx config for relay.metrics cert/fqdn
        sed "s/PORT/9616/g" ${temp_dir}/ssl.conf > ${temp_dir}/relay.metrics.${fqdn}.conf
        sed -i "s/SERVER_NAME/relay.metrics.${fqdn}/g" ${temp_dir}/relay.metrics.${fqdn}.conf
        sed -i "s/CERT_NAME/${fqdn}/g" ${temp_dir}/relay.metrics.${fqdn}.conf

        scp ${temp_dir}/relay.metrics.${fqdn}.conf ${username}@${fqdn}:/home/${username}/relay.metrics.${fqdn}.conf
        ssh -i ${ssh_key} ${username}@${fqdn} "sudo mv /home/${username}/relay.metrics.${fqdn}.conf /etc/nginx/sites-available/relay.metrics.${fqdn}.conf"
        ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown root:root /etc/nginx/sites-available/relay.metrics.${fqdn}.conf"

        cert_domains=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'sudo certbot certificates | grep Domains:' | sed -r 's/Domains: //g') )
        if [[ " ${cert_domains[*]} " =~ " relay.metrics.${fqdn} " ]]; then
          echo "detected relay.metrics.${fqdn} in cert domains (${cert_domains[@]})"
        else
          cert_domains+=( relay.metrics.${fqdn} )
          echo "adding relay.metrics.${fqdn} to cert domains (${cert_domains[@]})"
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo ln -frs /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default'
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot certonly --expand --agree-tos --no-eff-email --preferred-challenges http --webroot -w /var/www/html -m ops@manta.network -d $(_join_by ' -d ' ${cert_domains[@]})"
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo ln -frs /etc/nginx/sites-available/default-ssl /etc/nginx/sites-enabled/default'
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs /etc/nginx/sites-available/relay.metrics.${fqdn}.conf /etc/nginx/sites-enabled/relay.metrics.${fqdn}.conf"
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
        fi

        # para dns for metrics
        upsert_cname para.metrics ${fqdn} ${domain}

        # nginx config for para.metrics cert/fqdn
        sed "s/PORT/9615/g" ${temp_dir}/ssl.conf > ${temp_dir}/para.metrics.${fqdn}.conf
        sed -i "s/SERVER_NAME/para.metrics.${fqdn}/g" ${temp_dir}/para.metrics.${fqdn}.conf
        sed -i "s/CERT_NAME/${fqdn}/g" ${temp_dir}/para.metrics.${fqdn}.conf

        scp ${temp_dir}/para.metrics.${fqdn}.conf ${username}@${fqdn}:/home/${username}/para.metrics.${fqdn}.conf
        ssh -i ${ssh_key} ${username}@${fqdn} "sudo mv /home/${username}/para.metrics.${fqdn}.conf /etc/nginx/sites-available/para.metrics.${fqdn}.conf"
        ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown root:root /etc/nginx/sites-available/para.metrics.${fqdn}.conf"

        cert_domains=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'sudo certbot certificates | grep Domains:' | sed -r 's/Domains: //g') )
        if [[ " ${cert_domains[*]} " =~ " para.metrics.${fqdn} " ]]; then
          echo "detected para.metrics.${fqdn} in cert domains (${cert_domains[@]})"
        else
          cert_domains+=( para.metrics.${fqdn} )
          echo "adding para.metrics.${fqdn} to cert domains (${cert_domains[@]})"
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo ln -frs /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default'
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot certonly --expand --agree-tos --no-eff-email --preferred-challenges http --webroot -w /var/www/html -m ops@manta.network -d $(_join_by ' -d ' ${cert_domains[@]})"
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo ln -frs /etc/nginx/sites-available/default-ssl /etc/nginx/sites-enabled/default'
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs /etc/nginx/sites-available/para.metrics.${fqdn}.conf /etc/nginx/sites-enabled/para.metrics.${fqdn}.conf"
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
        fi

      elif ssh ${username}@${fqdn} 'curl --head http://localhost:9615/metrics &> /dev/null'; then
        # relay only dns for metrics
        upsert_cname relay.metrics ${fqdn} ${domain}

        # nginx config for relay.metrics cert/fqdn
        sed "s/PORT/9615/g" ${temp_dir}/ssl.conf > ${temp_dir}/relay.metrics.${fqdn}.conf
        sed -i "s/SERVER_NAME/relay.metrics.${fqdn}/g" ${temp_dir}/relay.metrics.${fqdn}.conf
        sed -i "s/CERT_NAME/${fqdn}/g" ${temp_dir}/relay.metrics.${fqdn}.conf

        scp ${temp_dir}/relay.metrics.${fqdn}.conf ${username}@${fqdn}:/home/${username}/relay.metrics.${fqdn}.conf
        ssh -i ${ssh_key} ${username}@${fqdn} "sudo mv /home/${username}/relay.metrics.${fqdn}.conf /etc/nginx/sites-available/relay.metrics.${fqdn}.conf"
        ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown root:root /etc/nginx/sites-available/relay.metrics.${fqdn}.conf"

        cert_domains=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'sudo certbot certificates | grep Domains:' | sed -r 's/Domains: //g') )
        if [[ " ${cert_domains[*]} " =~ " relay.metrics.${fqdn} " ]]; then
          echo "detected relay.metrics.${fqdn} in cert domains (${cert_domains[@]})"
        else
          cert_domains+=( relay.metrics.${fqdn} )
          echo "adding relay.metrics.${fqdn} to cert domains (${cert_domains[@]})"
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo ln -frs /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default'
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot certonly --expand --agree-tos --no-eff-email --preferred-challenges http --webroot -w /var/www/html -m ops@manta.network -d $(_join_by ' -d ' ${cert_domains[@]})"
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo ln -frs /etc/nginx/sites-available/default-ssl /etc/nginx/sites-enabled/default'
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs /etc/nginx/sites-available/relay.metrics.${fqdn}.conf /etc/nginx/sites-enabled/relay.metrics.${fqdn}.conf"
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
        fi
      fi
    fi
  done
done
