#!/usr/bin/env bash

set -a
source .env
set +a

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timezone)
            timezone="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

mkdir -p $DATA_FOLDER
mkdir -p $DATA_FOLDER/downloads/content
mkdir -p $DATA_FOLDER/media/{shows,movies}
mkdir -p $CONFIGS_FOLDER

if [ ! -f .secrets ]; then
    echo "First time start, bootstrapping secrets"
    read -p "PIA user: " pia_user
    read -sp "PIA password: " pia_password
    echo "PIA_USER=$pia_user" > .secrets
    echo "PIA_PASSWORD='$pia_password'" >> .secrets
    echo "VPN_SERVER=placeholder" >> .secrets

    if [[ -n "$timezone" ]]; then
        echo "TIMEZONE=$timezone" >> .secrets
    fi
fi

set -a
source .env
source .secrets
set +a
if [ ! -f ${VPN_WG_CONFIG} ]; then
    echo "WireGuard config file is not found, do you want to create it? (at ${VPN_WG_CONFIG}) (Y/n)"
    read answer
    if [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "" ]]; then
        echo "Creating wireguard file (make sure Go is installed before continuing: go version)"
        read -p "Region: (using nl_amsterdam for netherlands by default, write 'usa' USA)"
        go install github.com/Ephemeral-Dust/pia-wg-config@latest
        if [[ "$region" == "" ]]; then
            region="nl_amsterdam"
        fi
        if [[ "$region" == "usa" ]]; then
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

    set -a
    source .secrets
    set +a
fi

docker compose --env-file .env --env-file .secrets -f compose.yml up -d

cp indexers/* ${PROWLARR_FOLDER}/Definitions/
