#!/bin/sh

fqdn_list=( $(hostname -f) )
for prefix in api cockpit pulse rpc ws; do
  if nslookup ${prefix}.$(hostname -f) >/dev/null 2>&1 ; then
    fqdn_list+=( ${prefix}.$(hostname -f) )
  fi
done
echo "${fqdn_list[@]}"

if ! sudo certbot certificates | grep api.$(hostname -f) \
  || ! sudo certbot certificates | grep cockpit.$(hostname -f) \
  || ! sudo certbot certificates | grep pulse.$(hostname -f) \
  || ! sudo certbot certificates | grep rpc.$(hostname -f) \
  || ! sudo certbot certificates | grep ws.$(hostname -f) \
  && [ ${#fqdn_list[@]} -gt 1 ]; then
  sudo certbot certonly \
    --non-interactive \
    --agree-tos \
    --expand \
    --preferred-challenges http \
    --webroot \
    -w /usr/share/nginx/html \
    -m ops@manta.network \
    -d "${fqdn_list[@]}"
fi

[ -s /home/mobula/pulse/favicon.ico ] || curl \
  -o /home/mobula/pulse/favicon.ico \
  https://raw.githubusercontent.com/Manta-Network/pulse/main/node/home/mobula/pulse/favicon.ico

sudo curl \
  -o /etc/nginx/sites-available/pulse \
  https://raw.githubusercontent.com/Manta-Network/pulse/main/node/etc/nginx/sites-available/pulse

sudo sed "s/HOSTNAME/$(hostname -f)/g" \
  /etc/nginx/sites-available/pulse
sudo ln -sfr \
  /etc/nginx/sites-available/pulse \
  /etc/nginx/sites-enabled/pulse
sudo systemctl reload nginx
