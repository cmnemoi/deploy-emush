#!/bin/bash

set -e
set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pull_latest_code() {
    echo -e "${YELLOW}Pulling latest code...${NC}"
    cd emush
    git fetch origin
    git checkout develop
    git pull origin develop
    cd ..
    echo -e "${GREEN}Code pulled${NC}"
}

setup_env_variables() {
    COMMIT_HASH=$(cd emush && git rev-parse --short HEAD)
    cp .env.example .env
    sed -i "s/VITE_APP_API_RELEASE_COMMIT=.*/VITE_APP_API_RELEASE_COMMIT=$COMMIT_HASH/" .env
    sed -i "s/VITE_APP_API_RELEASE_CHANNEL=.*/VITE_APP_API_RELEASE_CHANNEL=$(hostname)/" .env
    echo -e "${GREEN}Environment variables set${NC}"
}

launch_app() {
    echo -e "${YELLOW}Launching app...${NC}"
    docker compose down
    docker volume rm -f emush_api-public
    docker compose build
    docker compose run emush-api php bin/console mush:migrate
    docker compose run emush-eternaltwin yarn eternaltwin db sync
    docker compose up --force-recreate --remove-orphans -d --wait --wait-timeout 15
    echo -e "${GREEN}App launched at http://localhost:5173${NC}"
}

main() {
    pull_latest_code
    setup_env_variables
    launch_app
}

main