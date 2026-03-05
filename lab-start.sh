#!/usr/bin/env bash

set -a
source .env
set +a

mkdir -p $CONFIGS_FOLDER/adguard

docker compose --env-file .env -f lab-compose.yml up -d
