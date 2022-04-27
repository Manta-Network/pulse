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
    repo_sha=$(_decode_property ${x} .sha)
    repo_path=$(_decode_property ${x} .path)
    fs_path=${repo_path/"config/${domain}/${fqdn}"/}
    fs_sha=$(git hash-object ${fs_path})
    if [ "${repo_sha}" = "${fs_sha}" ]; then
      echo "${fs_path} matches https://github.com/Manta-Network/pulse/main/${repo_path}"
    else
      echo "${fs_path} does not match https://github.com/Manta-Network/pulse/main/${repo_path}"
    fi
  done
else
  rm -f ${tmp_dir}/sites-available.json
fi

rm -rf ${tmp_dir}
echo "pulse run completed"
