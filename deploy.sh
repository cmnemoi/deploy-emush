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
    docker compose up --build --force-recreate --remove-orphans -d --wait --wait-timeout 10
    docker exec emush-api php bin/console mush:migrate
    echo -e "${GREEN}App launched${NC}"
    echo -e "Access the app at http://localhost:5173"
}

main() {
    pull_latest_code
    setup_env_variables
    launch_app
}

main