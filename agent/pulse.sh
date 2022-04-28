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
      sudo_group=sudo
      ;;
    fedora)
      package_manager=dnf
      package_resolver="dnf list"
      sudo_group=wheel
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
watched_paths+=( /etc/sudoers.d )
watched_paths+=( /usr/share/keyrings )
watched_paths+=( /etc/apt/sources.list.d )
watched_paths+=( /etc/nginx/sites-available )
watched_paths+=( /usr/lib/systemd/system )

tmp_dir=$(mktemp -d)
fqdn=$(hostname -f)
domain=$(hostname -d)

for watched_path in ${watched_paths[@]}; do
  # if a watched path's existence relies on installation of a package (ie: creation of
  # /etc/nginx/sites-available relies on installation of nginx), we simply ignore that
  # path until after the directory has been created by the package installer.
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
      fs_sha=$(sudo git hash-object ${fs_path})
      if [ "${gh_sha}" = "${fs_sha}" ]; then
        validated+=( ${fs_path} )
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

          updated+=( ${fs_path} )
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

          errored+=( ${fs_path} )
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
    echo "${watched_path} validated: ${#validated[@]}, updated: ${#updated[@]}, errored: ${#errored[@]}"
    unset validated
    unset updated
    unset errored
  fi
done

# https://raw.githubusercontent.com/Manta-Network/pulse/main/config/calamari.systems/jalapeno.calamari.systems/cloud-config.yml
if curl \
  -sLo ${tmp_dir}/cloud-config.yml \
  https://raw.githubusercontent.com/Manta-Network/pulse/main/config/${domain}/${fqdn}/cloud-config.yml; then

  users_as_base64=( $(yq -r '.users[] | select(. != "default") | @base64' ${tmp_dir}/cloud-config.yml) )
  if (( ${#users_as_base64[@]} )); then
    declare -a validated=()
    declare -a created=()
    declare -a errored=()
    for x in ${users_as_base64[@]}; do
      name=$(_decode_property ${x} .name)
      group=$(_decode_property ${x} .primary_group)
      gecos=$(_decode_property ${x} .gecos)
      sudo=$(_decode_property ${x} .sudo)
      system=$(_decode_property ${x} .system)
      no_create_home=$(_decode_property ${x} .no_create_home)
      keys=$(_decode_property ${x} .ssh_authorized_keys)
      homedir=$(_decode_property ${x} .homedir)
      [ "homedir" = null ] && homedir=/home/${name}

      if getent passwd ${name} > /dev/null 2>&1 && getent group ${group} > /dev/null 2>&1; then
        validated+=( ${name} )
        if [ -n "${keys}" ]; then
          sudo -H -u ${name} mkdir -p /home/${name}/.ssh
          sudo -H -u ${name} sh -c "echo \"${keys}\" > /home/${name}/.ssh/authorized_keys"
        fi
      else
        # create group if its name is distinct from username and doesn't already exist
        [ "${group}" != "${name}" ] && getent group ${group} > /dev/null 2>&1 || sudo groupadd $([ "${system}" = true ] && echo "--system") ${group}
        if sudo useradd \
          $([ "${no_create_home}" != true ] && echo "--create-home") \
          $([ "${no_create_home}" != true ] && echo "--home-dir ${homedir}") \
          $([ "${group}" != "${name}" ] && echo "--gid ${group}") \
          $([ "${group}" = "${name}" ] && echo "--user-group") \
          $([ "${system}" = true ] && echo "--system") \
          $([ "${sudo}" = true ] && echo "--groups ${sudo_group}") \
          $([ "${gecos}" = null ] || echo "--comment \"${gecos}\"") \
          ${name}; then
          created+=( ${name} )
          if [ -n "${keys}" ]; then
            sudo -H -u ${name} mkdir -p /home/${name}/.ssh
            sudo -H -u ${name} sh -c "echo \"${keys}\" > /home/${name}/.ssh/authorized_keys"
          fi
        else
          errored+=( ${name} )
        fi
      fi
    done
    echo "users validated: ${#validated[@]}, created: ${#created[@]}, errored: ${#errored[@]}"
    unset validated
    unset created
    unset errored
  fi

  packages=( $(yq -r '.packages[]' ${tmp_dir}/cloud-config.yml) )
  if (( ${#packages[@]} )); then
    declare -a validated=()
    declare -a installed=()
    declare -a errored=()
    for package in ${packages[@]}; do
      if ${package_resolver} ${package} &>/dev/null; then
        validated+=( ${package} )
      elif sudo ${package_manager} install -y ${package}; then
        installed+=( ${package} )
      else
        errored+=( ${package} )
      fi
    done
    echo "packages validated: ${#validated[@]}, installed: ${#installed[@]}, errored: ${#errored[@]}"
    unset validated
    unset installed
    unset errored
  fi

fi
rm -rf ${tmp_dir}
echo "pulse run completed"
