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

if curl \
  -sLo ${tmp_dir}/sites-available.json \
  https://api.github.com/repos/Manta-Network/pulse/contents/config/${domain}/${fqdn}/etc/nginx/sites-available; then
  list=( $(jq -r '.[] | @base64' ${tmp_dir}/sites-available.json) )
  for x in ${list[@]}; do
    gh_sha=$(_decode_property ${x} .sha)
    gh_path=$(_decode_property ${x} .path)
    fs_path=${gh_path/"config/${domain}/${fqdn}"/}
    fs_sha=$(git hash-object ${fs_path})
    if [ "${gh_sha}" != "${fs_sha}" ] && sudo curl \
      -sLo ${fs_path} \
      https://raw.githubusercontent.com/Manta-Network/pulse/main/${gh_path}; then
      sudo systemctl reload nginx.service
      echo "${fs_path} has been updated to match https://github.com/Manta-Network/pulse/blob/main/${gh_path}"
    fi
  done
else
  rm -f ${tmp_dir}/sites-available.json
fi

rm -rf ${tmp_dir}
echo "pulse run completed"
