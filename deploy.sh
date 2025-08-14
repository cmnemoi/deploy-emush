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

prompt_for_domain() {
	# Ask user for domain and persist to .env
	# Defaults to existing value or "localhost" if missing
	local current
	current="$(read_env_var DOMAIN)"
	if [ -z "${current:-}" ]; then
		current="localhost"
	fi
	# Only prompt if still at default value
	if [ "${current}" != "localhost" ]; then
		return 0
	fi
	printf "%s" "Enter domain name for this deployment [${current}]: "
	read -r input || input=""
	# Use default when user presses Enter
	input="${input:-$current}"
	# Normalize: strip protocol and trailing slash
	input="${input#http://}"
	input="${input#https://}"
	input="${input%/}"
	if [ "${input}" != "${current}" ]; then
		log_info "Updating DOMAIN to ${input}"
	fi
	upsert_env_var DOMAIN "${input}"
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
    # Escape sed replacement specials (| and &). Using '|' delimiter to avoid '/' conflicts
    local escaped
    escaped=$(printf '%s' "${value}" | sed -e 's/[|&\\]/\\&/g')
    if grep -q "^${key}=" .env; then
        sed -i -E "s|^${key}=.*|${key}=\"${escaped}\"|" .env
    else
        echo "${key}=\"${escaped}\"" >> .env
    fi
}

update_release_metadata() {
    local commit_hash="$1"
    local release_channel
    release_channel="$(hostname)"
    sed -i -E "s|^VITE_APP_API_RELEASE_COMMIT=.*|VITE_APP_API_RELEASE_COMMIT=\"${commit_hash}\"|" .env
    sed -i -E "s|^VITE_APP_API_RELEASE_CHANNEL=.*|VITE_APP_API_RELEASE_CHANNEL=\"${release_channel}\"|" .env
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

generate_strong_alnum_secret() {
    # Generates a 40-char alphanumeric secret to avoid encoding/escaping issues
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40
}

db_volume_initialized() {
    # Returns 0 if the Postgres data volume folder is non-empty, else 1
    local volume_path
    volume_path=$(docker volume inspect emush_emush-database-data -f '{{ .Mountpoint }}' 2>/dev/null || true)
    if [ -z "$volume_path" ] || [ ! -d "$volume_path" ]; then
        return 1
    fi
    if [ "$(ls -A "$volume_path" 2>/dev/null | wc -l)" -gt 0 ]; then
        return 0
    fi
    return 1
}

sync_postgres_password_in_toml() {
    # Usage: sync_postgres_password_in_toml PASSWORD
    local password="$1"
    if [ -f eternaltwin.local.toml ]; then
        sed -i -E '/^\[postgres\]/,/^\[/{s|^password = ".*"|password = "'"${password}"'"|}' eternaltwin.local.toml || true
    fi
}

sync_etwin_admin_password_in_toml() {
    # Usage: sync_etwin_admin_password_in_toml PASSWORD
    local password="$1"
    if [ -f eternaltwin.local.toml ]; then
        sed -i -E '/^\[seed.user.admin\]/,/^\[/{s|^password = ".*"|password = "'"${password}"'"|}' eternaltwin.local.toml || true
    fi
}

ensure_db_password_and_sync() {
    local current
    current="$(read_env_var POSTGRES_PASSWORD)"

    if [ -z "${current:-}" ] || [ "${current}" = "__GENERATED_ON_FIRST_DEPLOY__" ]; then
        if db_volume_initialized; then
            echo -e "${RED}ERROR:${NC} Postgres volume already initialized but POSTGRES_PASSWORD is missing. Set it in .env to the existing DB password or remove the volume if data can be discarded: docker volume rm emush_emush-database-data"
            exit 1
        fi
        local new_db_pass
        new_db_pass="$(generate_strong_alnum_secret)"
        upsert_env_var POSTGRES_PASSWORD "${new_db_pass}"
        local new_db_url
        new_db_url="postgresql://emush:${new_db_pass}@emush-database:5432/emush?serverVersion=17"
        upsert_env_var DATABASE_URL "${new_db_url}"
        log_ok "Generated POSTGRES_PASSWORD and updated DATABASE_URL"
        sync_postgres_password_in_toml "${new_db_pass}"
    else
        # Ensure TOML is synced from existing value
        sync_postgres_password_in_toml "${current}"
        log_warn "POSTGRES_PASSWORD already set, synced to eternaltwin.local.toml"
    fi
}

ensure_etwin_admin_password_and_sync() {
    local current
    current="$(read_env_var ETERNALTWIN_ADMIN_PASSWORD)"
    if [ -z "${current:-}" ] || [ "${current}" = "__GENERATED_ON_FIRST_DEPLOY__" ]; then
        local new_admin_pass
        new_admin_pass="$(generate_strong_alnum_secret)"
        upsert_env_var ETERNALTWIN_ADMIN_PASSWORD "${new_admin_pass}"
        sync_etwin_admin_password_in_toml "${new_admin_pass}"
        log_ok "Generated ETERNALTWIN_ADMIN_PASSWORD and updated eternaltwin.local.toml"
    else
        sync_etwin_admin_password_in_toml "${current}"
        log_warn "ETERNALTWIN_ADMIN_PASSWORD already set, synced to eternaltwin.local.toml"
    fi
}

sync_etwin_secret_in_toml() {
    # Usage: sync_etwin_secret_in_toml SECRET
    local secret="$1"
    if [ -f eternaltwin.local.toml ]; then
        # Update only within the [seed.app.emush_production] section
        sed -i -E '/^\[seed.app.emush_production\]/,/^\[/{s|^secret = ".*"|secret = "'"${secret}"'"|}' eternaltwin.local.toml || true
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

sync_etwin_domain_in_toml() {
	# Sync domain-dependent URIs in eternaltwin.local.toml
	local domain uri oauth_cb
	domain="$(read_env_var DOMAIN)"
	if [ -z "${domain:-}" ]; then
		domain="localhost"
	fi
	uri="https://emush.${domain}/"
	oauth_cb="https://api.emush.${domain}/oauth/callback"
	if [ -f eternaltwin.local.toml ]; then
		# Update only within the [seed.app.emush_production] section
		sed -i -E '/^\[seed.app.emush_production\]/,/^\[/{s|^uri = ".*"|uri = "'"${uri}"'"|}' eternaltwin.local.toml || true
		sed -i -E '/^\[seed.app.emush_production\]/,/^\[/{s|^oauth_callback = ".*"|oauth_callback = "'"${oauth_cb}"'"|}' eternaltwin.local.toml || true
	fi
}

restrict_sensitive_permissions() {
    chmod 600 .env || true
    chmod 600 eternaltwin.local.toml || true
}

pull_latest_code() {
    log_info "Pulling latest code..."
    git fetch origin
    git pull origin main
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
	prompt_for_domain
    update_release_metadata "${commit_hash}"
    ensure_app_secret
    ensure_jwt_passphrase
    ensure_db_password_and_sync
    ensure_etwin_admin_password_and_sync
    ensure_oauth_secret_and_sync
	sync_etwin_domain_in_toml
    restrict_sensitive_permissions
    log_ok "Environment variables set"
}

launch_app() {
	# Compute APP_URL from DOMAIN set in .env
	local domain
    local admin_pass
    admin_pass="$(read_env_var ETERNALTWIN_ADMIN_PASSWORD)"
	domain="$(read_env_var DOMAIN)"
	if [ -z "${domain:-}" ]; then
		domain="localhost"
	fi
	APP_URL="http://emush.${domain}/"
    echo -e "${YELLOW}Launching app...${NC}"
    docker compose build
    docker compose run --rm emush-api php bin/console lexik:jwt:generate-keypair --no-interaction --skip-if-exists
    docker compose run --rm emush-eternaltwin yarn eternaltwin db sync
    docker compose up --force-recreate --remove-orphans -d --wait --wait-timeout 15
    docker compose run --rm emush-api php bin/console mush:migrate
    echo -e "${GREEN}App launched at ${APP_URL}${NC}"
    log_info "You can connect with admin account: admin / ${admin_pass} (please change it)"
}

main() {
    pull_latest_code
    setup_env_variables
    launch_app
}

main