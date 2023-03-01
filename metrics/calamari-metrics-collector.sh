#!/bin/bash

_decode_property() {
  echo ${1} | base64 --decode | jq -r ${2}
}

collators_as_base64=$(curl -sL https://raw.githubusercontent.com/Manta-Network/sparta/main/calamari.json | jq -r '.[] | @base64')
for x in ${collators_as_base64[@]}; do
  ss58=$(_decode_property ${x} .ss58)
  for chain in calamari kusama; do
    metrics_url=$(_decode_property ${x} .metrics.${chain})
    if [[ ${metrics_url} == http* ]]; then
      mkdir -p /var/lib/metrics/${ss58}
      if curl -sLo /var/lib/metrics/${ss58}/${chain}.txt ${metrics_url}/metrics && [ -s /var/lib/metrics/${ss58}/${chain}.txt ]; then
        if prom2json /var/lib/metrics/${ss58}/${chain}.txt 2> /dev/null | jq --sort-keys '. |= sort_by(.name)' > /var/lib/metrics/${ss58}/${chain}.json && [ -s /var/lib/metrics/${ss58}/${chain}.json ]; then
          echo /var/lib/metrics/${ss58}/${chain}.json
        else
          rm -f /var/lib/metrics/${ss58}/${chain}.json
        fi
      else
        rm -f /var/lib/metrics/${ss58}/${chain}.txt
      fi
    fi
  done
done

find /var/lib/metrics -type f -empty -print -delete
find /var/lib/metrics -type d -empty -print -delete
