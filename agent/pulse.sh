#!/usr/bin/env bash

if [ ! -f /etc/os-release ]; then
  echo "pulse run aborted. unsupported os."
  exit 1
else
  . /etc/os-release
  case ${ID} in
    ubuntu)
      package_manager=apt
      ;;
    fedora)
      package_manager=dnf
      ;;
    *)
      echo "pulse run aborted. unsupported os."
      exit 1
      ;;
  esac
fi

for package in curl git jq; do
  if ! command -v ${package}; then
    sudo ${package_manager} install -y ${package}
  fi
done

_decode_property() {
  echo ${1} | base64 --decode | jq -r ${2}
}

echo "pulse run started"

tmp_dir=$(mktemp -d)
fqdn=$(hostname -f)
domain=$(hostname -d)

for watched_path in /etc/nginx/sites-available; do
  if curl \
    -sLo ${tmp_dir}/sites-available.json \
    https://api.github.com/repos/Manta-Network/pulse/contents/config/${domain}/${fqdn}${watched_path}; then
    list=( $(jq -r '.[] | @base64' ${tmp_dir}/sites-available.json) )
    declare -A validated=()
    declare -A updated=()
    declare -A errored=()
    for x in ${list[@]}; do
      gh_sha=$(_decode_property ${x} .sha)
      gh_path=$(_decode_property ${x} .path)
      fs_path=${gh_path/"config/${domain}/${fqdn}"/}
      fs_sha=$(git hash-object ${fs_path})
      if [ "${gh_sha}" = "${fs_sha}" ]; then
        validated+=( $(basename ${fs_path}) )
      else
        if sudo curl \
          -sLo ${fs_path} \
          https://raw.githubusercontent.com/Manta-Network/pulse/main/${gh_path} \
          && sudo systemctl reload nginx.service; then
          updated+=( $(basename ${fs_path}) )
          #echo "${fs_path} has been updated to match https://github.com/Manta-Network/pulse/blob/main/${gh_path}"
        else
          errored+=( $(basename ${fs_path}) )
          echo "${fs_path} has failed to update and does not match https://github.com/Manta-Network/pulse/blob/main/${gh_path}"
        fi
      fi
    done
    echo "${watched_path} updated: ${#updated[@]}, validated: ${#validated[@]}, errored: ${#errored[@]}"
    unset validated
    unset updated
    unset errored
  else
    rm -f ${tmp_dir}/sites-available.json
  fi
done

rm -rf ${tmp_dir}
echo "pulse run completed"
