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

for package in curl jq; do
  if ! command -v ${package}; then
    sudo ${package_manager} install -y ${package}
  fi
done

echo "pulse run started"

tmp_dir=$(mktemp -d)
fqdn=$(hostname -f)
domain=$(hostname -d)

if curl \
  -sLo ${tmp_dir}/${fqdn}.json \
  https://api.github.com/repos/Manta-Network/pulse/contents/config/${domain}/${fqdn}; then
else
  rm -f ${tmp_dir}/${fqdn}.json
fi

rm -rf ${tmp_dir}
echo "pulse run completed"
