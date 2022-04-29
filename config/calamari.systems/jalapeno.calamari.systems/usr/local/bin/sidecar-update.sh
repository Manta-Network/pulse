#!/usr/bin/env bash

if [[ -z "${node_version}" ]]; then
  echo "required environment variable 'node_version' is not set" 1>&2
  exit 1
fi

if [[ -z "${sidecar_path}" ]]; then
  echo "required environment variable 'sidecar_path' is not set" 1>&2
  exit 1
fi

export NVM_DIR=${HOME}/.nvm

if [ ! -f /home/$(whoami)/.nvm/versions/node/${node_version}/bin/yarn ]; then
  latest_nvm_tag=$(curl -sL https://api.github.com/repos/nvm-sh/nvm/releases | jq -r '[ .[] | .tag_name ] | .[0]' 2>/dev/null || echo ${fallback_nvm_tag})
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${latest_nvm_tag}/install.sh | bash
  source ${NVM_DIR}/nvm.sh
  source ${NVM_DIR}/bash_completion
  nvm install ${node_version}
  nvm use ${node_version}
  ${NVM_DIR}/versions/node/${node_version}/bin/npm install --global npm yarn
fi
export PATH=${NVM_DIR}/versions/node/${node_version}/bin:${PATH}
latest_sidecar_tag=$(curl -sL https://api.github.com/repos/paritytech/substrate-api-sidecar/releases | jq -r '[ .[] | .tag_name ] | .[0]' 2>/dev/null || echo ${fallback_sidecar_tag})
[ -f ${sidecar_path}/package.json ] && observed_sidecar_tag=$(jq -r '.dependencies["@substrate/api-sidecar"]' ${sidecar_path}/package.json)
if [ -f ${sidecar_path}/package.json ] && [ "${latest_sidecar_tag:1}" = "${observed_sidecar_tag:1}" ]; then
  echo "observed sidecar tag (${observed_sidecar_tag:1}) in: ${sidecar_path}/package.json, matches latest sidecar tag (${latest_sidecar_tag:1}) from: https://github.com/paritytech/substrate-api-sidecar/releases"
else
  echo "observed sidecar tag (${observed_sidecar_tag:1}) in: ${sidecar_path}/package.json, does not match latest sidecar tag (${latest_sidecar_tag:1}) from: https://github.com/paritytech/substrate-api-sidecar/releases"
  rm -rf ${sidecar_path}/*
  mkdir -p ${sidecar_path}/logs
  if ${NVM_DIR}/versions/node/${node_version}/bin/yarn --cwd ${sidecar_path} add @substrate/api-sidecar && [ -f ${sidecar_path}/node_modules/.bin/substrate-api-sidecar ]; then
    echo "installed @substrate/api-sidecar ${latest_sidecar_tag} to ${sidecar_path}"
  else
    echo "failed to install @substrate/api-sidecar ${latest_sidecar_tag} to ${sidecar_path}"
    exit 1
  fi
fi
