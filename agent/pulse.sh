#!/usr/bin/env bash

if [ ! -f /etc/os-release ]; then
  echo "pulse run aborted. unsupported os."
  exit 1
else
  . /etc/os-release
  case ${ID} in
    ubuntu)
      package_manager=apt
      package_resolver="dpkg -l"
      ;;
    fedora)
      package_manager=dnf
      package_resolver="dnf list"
      ;;
    *)
      echo "pulse run aborted. unsupported os."
      exit 1
      ;;
  esac
fi

# os package manager packages depended on by this script
declare -a pm_packages=()
pm_packages+=( curl )
pm_packages+=( git )
pm_packages+=( jq )
pm_packages+=( python3 )
pm_packages+=( python3-pip )

# pip packages depended on by this script
declare -a pip_packages=()
pip_packages+=( pip )
pip_packages+=( yq )

for package in ${pm_packages[@]}; do
  ${package_resolver} ${package} &>/dev/null || sudo ${package_manager} install -y ${package}
done

export PATH=${PATH}:${HOME}/.local/bin
for package in ${pip_packages[@]}; do
  pip list --uptodate | grep "${package} " || pip install --upgrade ${package}
done

_decode_property() {
  echo ${1} | base64 --decode | jq -r ${2}
}

echo "pulse run started"

declare -a watched_paths=()
watched_paths+=( /usr/share/keyrings )
watched_paths+=( /etc/apt/sources.list.d )
watched_paths+=( /etc/nginx/sites-available )
watched_paths+=( /usr/lib/systemd/system )

tmp_dir=$(mktemp -d)
fqdn=$(hostname -f)
domain=$(hostname -d)

for watched_path in ${watched_paths[@]}; do
  if [ -d ${watched_path} ] && curl \
    -sLo ${tmp_dir}/watched-paths.json \
    https://api.github.com/repos/Manta-Network/pulse/contents/config/${domain}/${fqdn}${watched_path}; then
    list=( $(jq -r '.[] | @base64' ${tmp_dir}/watched-paths.json) )
    declare -a validated=()
    declare -a updated=()
    declare -a errored=()
    for x in ${list[@]}; do
      gh_sha=$(_decode_property ${x} .sha)
      gh_path=$(_decode_property ${x} .path)
      fs_path=${gh_path/"config/${domain}/${fqdn}"/}
      fs_sha=$(git hash-object ${fs_path})
      if [ "${gh_sha}" = "${fs_sha}" ]; then
        validated+=( $(basename ${fs_path}) )
      else

        # pre change action
        case ${watched_path} in
          /usr/lib/systemd/system)
            sudo systemctl stop $(basename ${fs_path})
            ;;
          *)
            ;;
        esac

        if sudo curl \
          -sLo ${fs_path} \
          https://raw.githubusercontent.com/Manta-Network/pulse/main/${gh_path}; then

          # post change success action
          case ${watched_path} in
            /etc/apt/sources.list.d)
              sudo apt update
              ;;
            /etc/nginx/sites-available)
              sudo systemctl reload nginx.service
              ;;
            /usr/lib/systemd/system)
              sudo systemctl daemon-reload
              ;;
            *)
              ;;
          esac
          # end post change success action

          updated+=( $(basename ${fs_path}) )
          #echo "${fs_path} has been updated to match https://github.com/Manta-Network/pulse/blob/main/${gh_path}"
        else

          # post change failure action
          case ${watched_path} in
            /etc/nginx/sites-available)
              sudo systemctl reload nginx.service
              ;;
            /usr/lib/systemd/system)
              sudo systemctl daemon-reload
              ;;
            *)
              ;;
          esac
          # end post change failure action

          errored+=( $(basename ${fs_path}) )
          echo "${fs_path} has failed to update and does not match https://github.com/Manta-Network/pulse/blob/main/${gh_path}"
        fi

        # post change action
        case ${watched_path} in
          /usr/lib/systemd/system)
            sudo systemctl start $(basename ${fs_path})
            ;;
          *)
            ;;
        esac
        # end post change action

      fi
    done
    echo "${watched_path} updated: ${#updated[@]}, validated: ${#validated[@]}, errored: ${#errored[@]}"
    unset validated
    unset updated
    unset errored
  fi
done

# https://raw.githubusercontent.com/Manta-Network/pulse/main/config/calamari.systems/jalapeno.calamari.systems/cloud-config.yml
if curl \
  -sLo ${tmp_dir}/cloud-config.yml \
  https://raw.githubusercontent.com/Manta-Network/pulse/main/config/${domain}/${fqdn}/cloud-config.yml; then
  declare -a validated=()
  declare -a installed=()
  declare -a errored=()
  packages=( $(yq -r '.packages[]' ${tmp_dir}/cloud-config.yml) )
  for package in ${packages[@]}; do
    if ${package_resolver} ${package} &>/dev/null; then
      validated+=( ${package} )
    elif sudo ${package_manager} install -y ${package}; then
      installed+=( ${package} )
    else
      errored+=( ${package} )
    fi
  done
  echo "packages installed: ${#installed[@]}, validated: ${#validated[@]}, errored: ${#errored[@]}"
  unset validated
  unset installed
  unset errored
fi
rm -rf ${tmp_dir}
echo "pulse run completed"
