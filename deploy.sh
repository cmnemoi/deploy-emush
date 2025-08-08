#!/bin/bash

set -e
set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info() { echo -e "${YELLOW}$1${NC}"; }
log_warn() { echo -e "${YELLOW}$1${NC}"; }
log_ok() { echo -e "${GREEN}$1${NC}"; }

get_short_commit_hash() {
    (cd emush && git rev-parse --short HEAD)
}

ensure_env_files() {
    # Ensure .env exists (from template) and local Eternaltwin config exists
    if [ ! -f .env ]; then
        cp .env.example .env
        cp eternaltwin.toml eternaltwin.local.toml
    fi
    if [ ! -f eternaltwin.local.toml ]; then
        cp eternaltwin.toml eternaltwin.local.toml
    fi
}

read_env_var() {
    # Usage: read_env_var KEY -> prints value or empty
    local key="$1"
    grep -E "^${key}=" .env | cut -d'=' -f2- | tr -d '"' || true
}

upsert_env_var() {
    # Usage: upsert_env_var KEY VALUE (value will be quoted in file)
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" .env; then
        sed -i "s/^${key}=.*/${key}=\"${value}\"/" .env
    else
        echo "${key}=\"${value}\"" >> .env
    fi
}

update_release_metadata() {
    local commit_hash="$1"
    local release_channel
    release_channel="$(hostname)"
    sed -i "s/^VITE_APP_API_RELEASE_COMMIT=.*/VITE_APP_API_RELEASE_COMMIT=\"${commit_hash}\"/" .env
    sed -i "s/^VITE_APP_API_RELEASE_CHANNEL=.*/VITE_APP_API_RELEASE_CHANNEL=\"${release_channel}\"/" .env
}

ensure_app_secret() {
    local current
    current="$(read_env_var APP_SECRET)"
    if [ -z "${current:-}" ] || [ "${current}" = "your-secret-key-here" ]; then
        local new_secret
        new_secret="$(openssl rand -hex 32)"
        upsert_env_var APP_SECRET "${new_secret}"
        log_ok "Generated APP_SECRET"
    else
        log_warn "APP_SECRET already set, keeping existing value"
    fi
}

ensure_jwt_passphrase() {
    local current
    current="$(read_env_var JWT_PASSPHRASE)"
    if [ -z "${current:-}" ] || [ "${current}" = "your-jwt-passphrase-here" ]; then
        local new_pass
        new_pass="$(openssl rand -base64 48)"
        upsert_env_var JWT_PASSPHRASE "${new_pass}"
        log_ok "Generated JWT_PASSPHRASE"
    else
        log_warn "JWT_PASSPHRASE already set, keeping existing value"
    fi
}

sync_etwin_secret_in_toml() {
    # Usage: sync_etwin_secret_in_toml SECRET
    local secret="$1"
    if [ -f eternaltwin.local.toml ]; then
        # Update only within the [seed.app.emush_production] section
        sed -i '/^\[seed.app.emush_production\]/,/^\[/{s/^secret = \".*\"/secret = \"'"${secret}"'\"/}' eternaltwin.local.toml || true
    fi
}

ensure_oauth_secret_and_sync() {
    local current
    current="$(read_env_var OAUTH_SECRET_ID)"
    if [ -z "${current:-}" ] || [ "${current}" = "my_super_eternaltwin_oauth_secret" ]; then
        local new_secret
        new_secret="$(openssl rand -hex 32)"
        upsert_env_var OAUTH_SECRET_ID "${new_secret}"
        sync_etwin_secret_in_toml "${new_secret}"
        log_ok "Generated OAUTH_SECRET_ID and updated eternaltwin.local.toml"
    else
        sync_etwin_secret_in_toml "${current}"
        log_warn "OAUTH_SECRET_ID already set, synced to eternaltwin.local.toml"
    fi
}

restrict_sensitive_permissions() {
    chmod 600 .env || true
    chmod 600 eternaltwin.local.toml || true
}

pull_latest_code() {
    log_info "Pulling latest code..."
    cd emush
    git fetch origin
    git checkout develop
    git pull origin develop
    cd ..
    log_ok "Code pulled"
}

setup_env_variables() {
    local commit_hash
    commit_hash="$(get_short_commit_hash)"

    ensure_env_files
    update_release_metadata "${commit_hash}"
    ensure_app_secret
    ensure_jwt_passphrase
    ensure_oauth_secret_and_sync
    restrict_sensitive_permissions
    log_ok "Environment variables set"
}

launch_app() {
    APP_URL=$(grep -oP 'VITE_APP_URL="\K[^"]+' .env)
    echo -e "${YELLOW}Launching app...${NC}"
    docker compose build
    docker compose run --rm emush-api php bin/console lexik:jwt:generate-keypair --no-interaction --overwrite
    docker compose run --rm emush-api php bin/console mush:migrate
    docker compose run --rm emush-eternaltwin yarn eternaltwin db sync
    docker compose up --force-recreate --remove-orphans -d --wait --wait-timeout 15
    echo -e "${GREEN}App launched at ${APP_URL}${NC}"
}

main() {
    pull_latest_code
    setup_env_variables
    launch_app
}

main