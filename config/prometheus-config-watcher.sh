#!/usr/bin/env bash

remote_config_base_url=https://raw.githubusercontent.com/Manta-Network/pulse/main/config
temp_dir=$(mktemp -d)

config_changed=false
for local_config_file in /etc/prometheus/*.yml; do
  remote_config_url=${remote_config_base_url}/$(basename ${local_config_file})
  remote_config_file=${temp_dir}/$(basename ${local_config_file})
  if curl -sLo ${remote_config_file} ${remote_config_url}; then
    echo "${remote_config_file} downloaded from ${remote_config_url}"
  else
    echo "failed to download ${remote_config_file} from ${remote_config_url}"
    exit 1
  fi

  remote_config_hash=$(/usr/bin/sha256sum ${remote_config_file} | cut -d ' ' -f1)
  local_config_hash=$(/usr/bin/sha256sum ${local_config_file} | cut -d ' ' -f1)

  if [ "${remote_config_hash}" = "${local_config_hash}" ]; then
    echo "${local_config_file} has a checksum matching ${remote_config_url} (${local_config_hash})"
    rm ${remote_config_file}
  else
    if mv ${remote_config_file} ${local_config_file}; then
      config_changed=true
      echo "${local_config_file} has been replaced with ${remote_config_url}  and now has checksum: ${remote_config_hash}"
    else
      echo "failed to replace ${local_config_file} with: ${remote_config_file} (${remote_config_url})"
      exit 1
    fi
  fi
done
rmdir ${temp_dir}
if [ "${config_changed}" = true ] ; then
  if /usr/bin/systemctl reload prometheus.service; then
    echo "prometheus.service has been reloaded because its configuration changed."
  else
    echo "failed to reload prometheus.service after its configuration changed."
  fi
fi
