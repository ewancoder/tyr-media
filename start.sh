#!/usr/bin/env bash

if [ ! -f .secrets ]; then
    echo "First time start, bootstrapping secrets"
    read -p "PIA user: " pia_user
    read -sp "PIA password: " pia_password
    echo "PIA_USER=$pia_user" > .secrets
    echo "PIA_PASSWORD=$pia_password" >> .secrets
    echo "VPN_SERVER=placeholder" >> .secrets
fi

source .secrets
source .env
if [ ! -f ${VPN_WG_CONFIG} ]; then
    echo "WireGuard config file is not found, do you want to create it? (at ${VPN_WG_CONFIG}) (Y/n)"
    read answer
    if [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "" ]]; then
        echo "Creating wireguard file (make sure Go is installed before continuing: go version)"
        read -p "Region: (nl_amsterdam for netherlands, empty for default USA): " region
        go install github.com/Ephemeral-Dust/pia-wg-config@latest
        if [[ "$region" == "" ]]; then
            ~/go/bin/pia-wg-config -o temp_wg.conf --server --port-forwarding $PIA_USER $PIA_PASSWORD
        else
            ~/go/bin/pia-wg-config -r $region -o temp_wg.conf --server --port-forwarding $PIA_USER $PIA_PASSWORD
        fi
        mv temp_wg.conf ${VPN_WG_CONFIG}
    else
        echo "Skipping wireguard configuration."
    fi
fi
if [ -f ${VPN_WG_CONFIG} ]; then
    SERVER_NAME=$(cat ${VPN_WG_CONFIG} | grep ServerCommonName | awk '{print $3}')
    echo "VPN server name: $SERVER_NAME"

    sed -i "s/VPN_SERVER=.*/VPN_SERVER=$SERVER_NAME/" .secrets
fi

docker compose --env-file .env --env-file .secrets -f compose.yml up -d
