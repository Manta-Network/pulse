#!/usr/bin/env bash

#ssh_key=${HOME}/.ssh/id_manta_ci
ssh_key=${HOME}/.ssh/id_ed25519
declare -A endpoint_prefix=( [ops]=7p1eol9lz4 [dev]=mab48pe004 [service]=l7ff90u0lf [prod]=hzhmt0krm0 )
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
temp_dir=$(mktemp -d)
#temp_dir=/tmp/pulse-maintain
#mkdir -p ${temp_dir}
#subl ${temp_dir}

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
  done
done
