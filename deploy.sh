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

# Parse command line arguments
DEPLOYMENT_CHANNEL="stable"
while [[ $# -gt 0 ]]; do
    case $1 in
        --beta)
            DEPLOYMENT_CHANNEL="beta"
            shift
            ;;
        --stable)
            DEPLOYMENT_CHANNEL="stable"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --beta     Deploy beta version (develop branch)"
            echo "  --stable   Deploy stable version (master branch) [default]"
            echo "  --help, -h Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0              # Deploy stable (default)"
            echo "  $0 --beta       # Deploy beta version"
            echo "  $0 --stable     # Deploy stable version"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

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
    release_channel="$(hostname)-${DEPLOYMENT_CHANNEL}"
    
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

generate_vapid_keys() {
    # Génère une paire de clés VAPID (P-256) pour Web Push.
    # Sortie :
    #  - En CI: chemins vers deux fichiers temporaires "PRIVATE:PUBLIC" (base64url)
    #  - Hors CI: "PRIVATE:PUBLIC" (base64url) sur stdout
    # Hypothèse: openssl, xxd, base64, awk, tr, tail sont disponibles.

    local temp_key private_b64 public_b64

    # Fichier temporaire pour la clé EC (P-256)
    temp_key=$(mktemp) || { echo "ERROR: mktemp failed" >&2; return 1; }

    # 1) Génère la clé privée P-256
    if ! openssl ecparam -genkey -name prime256v1 -noout -out "$temp_key" 2>/dev/null; then
        rm -f "$temp_key"
        [ -z "${CI:-}" ] && echo "ERROR: Failed to generate EC key pair" >&2
        return 1
    fi

    # 2) Extrait d (32 octets) en base64url (clé privée VAPID)
    #    On parse la section "priv:" (hex), on concatène, on convertit en binaire, puis base64url.
    private_b64=$(
        openssl ec -in "$temp_key" -text -noout 2>/dev/null |
        awk '/priv:/{flag=1; next} /pub:/{flag=0} flag && /[0-9a-f:]+/{
            gsub(/[: \n]/,""); printf "%s",$0
        }' |
        xxd -r -p |
        base64 -w 0 | tr '+/' '-_' | tr -d '='
    )

    # 3) Extrait la clé publique en format RAW UNCOMPRESSED (65 octets = 0x04 || X(32) || Y(32))
    #    -pubout -outform DER produit une SPKI DER, les 65 derniers octets sont le point EC uncompressed.
    #    CONTRAIREMENT à ton script initial, on NE retire PAS le premier octet 0x04.
    public_b64=$(
        openssl ec -in "$temp_key" -pubout -outform DER 2>/dev/null |
        tail -c 65 |
        base64 -w 0 | tr '+/' '-_' | tr -d '='
    )

    # Nettoyage du fichier temporaire
    rm -f "$temp_key"

    # 4) Validation minimale
    if [ -z "$private_b64" ] || [ -z "$public_b64" ]; then
        [ -z "${CI:-}" ] && echo "ERROR: Failed to extract keys" >&2
        return 1
    fi

    # Vérif rapide: premier octet public doit être 0x04 (optionnel mais utile)
    # (Ne casse pas la sortie; on loggue en stderr si incohérent)
    if command -v base64 >/dev/null 2>&1 && command -v xxd >/dev/null 2>&1; then
        local first_byte
        first_byte=$(printf '%s' "$public_b64" | tr '-_' '+/' | base64 -d 2>/dev/null | xxd -p -c 65 | head -c 2)
        if [ "$first_byte" != "04" ]; then
            [ -z "${CI:-}" ] && echo "WARN: public key first byte is not 0x04" >&2
        fi
    fi

    # 5) Sortie
    if [ -n "${CI:-}" ]; then
        local temp_private temp_public
        temp_private=$(mktemp) || { echo "ERROR: mktemp failed" >&2; return 1; }
        temp_public=$(mktemp) || { echo "ERROR: mktemp failed" >&2; return 1; }
        printf '%s\n' "$private_b64" > "$temp_private"
        printf '%s\n' "$public_b64" > "$temp_public"
        echo "${temp_private}:${temp_public}"
    else
        echo "${private_b64}:${public_b64}"
    fi
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

ensure_vapid_keys() {
    local current_public current_private current_vite_public
    current_public="$(read_env_var VAPID_PUBLIC_KEY)"
    current_private="$(read_env_var VAPID_PRIVATE_KEY)"
    current_vite_public="$(read_env_var VITE_VAPID_PUBLIC_KEY)"
    
    if [ -z "${current_public:-}" ] || [ "${current_public}" = "__GENERATED_ON_FIRST_DEPLOY__" ] || \
       [ -z "${current_private:-}" ] || [ "${current_private}" = "__GENERATED_ON_FIRST_DEPLOY__" ] || \
       [ -z "${current_vite_public:-}" ] || [ "${current_vite_public}" = "__GENERATED_ON_FIRST_DEPLOY__" ]; then
        
        log_info "Generating VAPID keys..."
        local vapid_keys private_key public_key
        vapid_keys="$(generate_vapid_keys)"
        
        # Handle different output formats based on CI environment
        if [ -n "${CI:-}" ]; then
            # In CI: vapid_keys contains "temp_private_file:temp_public_file"
            local temp_private_file temp_public_file
            temp_private_file="${vapid_keys%:*}"
            temp_public_file="${vapid_keys#*:}"
            private_key="$(cat "$temp_private_file")"
            public_key="$(cat "$temp_public_file")"
            # Clean up temporary files
            rm -f "$temp_private_file" "$temp_public_file"
        else
            # Outside CI: vapid_keys contains "private_key:public_key"
            private_key="${vapid_keys%:*}"
            public_key="${vapid_keys#*:}"
        fi
        
        upsert_env_var VAPID_PRIVATE_KEY "${private_key}"
        upsert_env_var VAPID_PUBLIC_KEY "${public_key}"
        upsert_env_var VITE_VAPID_PUBLIC_KEY "${public_key}"
        
        log_ok "Generated VAPID keys for Web Push notifications"
    else
        log_warn "VAPID keys already set, keeping existing values"
    fi
}

ensure_admin_id_from_database() {
    local current
    current="$(read_env_var ADMIN)"
    if [ -z "${current:-}" ] || [ "${current}" = "your-etwin-id-here" ]; then
        log_info "Attempting to retrieve admin ID from database..."
        
        # Wait for database to be ready
        local max_attempts=30
        local attempt=1
        while [ $attempt -le $max_attempts ]; do
            if docker compose exec -T emush-database pg_isready -U emush >/dev/null 2>&1; then
                break
            fi
            log_info "Waiting for database to be ready... (attempt $attempt/$max_attempts)"
            sleep 2
            attempt=$((attempt + 1))
        done
        
        if [ $attempt -gt $max_attempts ]; then
            log_warn "Database not ready after $max_attempts attempts, skipping admin ID retrieval"
            return 0
        fi
        
        # Try to get admin ID from database
        local admin_id
        admin_id=$(docker compose exec -T emush-database psql -U emush -d "eternaltwin.prod" -t -c "SELECT users.user_id FROM users INNER JOIN user_username_history uuh ON users.user_id = uuh.user_id WHERE username = 'admin';" 2>/dev/null | tr -d ' \n' || echo "")
        
        if [ -n "${admin_id:-}" ] && [ "${admin_id}" != "0" ]; then
            upsert_env_var ADMIN "${admin_id}"
            log_ok "Retrieved admin ID from database: ${admin_id}"
        else
            log_warn "Could not retrieve admin ID from database, keeping placeholder value"
            log_info "You may need to manually set ADMIN in .env after first login"
        fi
    else
        log_warn "ADMIN already set to: ${current}"
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
    log_info "Pulling latest code for channel: ${DEPLOYMENT_CHANNEL}..."
    git fetch origin
    git pull origin main
    
    cd emush
    git fetch origin
    
    case "${DEPLOYMENT_CHANNEL}" in
        "beta"|"develop")
            log_info "Switching to beta (develop branch)"
            git checkout develop
            git pull origin develop
            ;;
        "stable"|"master"|*)
            log_info "Switching to stable (master branch)"
            git checkout master
            git pull origin master
            ;;
    esac
    
    cd ..
    log_ok "Code pulled for ${DEPLOYMENT_CHANNEL} channel"
}

setup_env_variables() {
    local commit_hash
    local domain
    commit_hash="$(get_short_commit_hash)"

    ensure_env_files
	prompt_for_domain
    domain="$(read_env_var DOMAIN)"
    upsert_env_var VITE_ETERNALTWIN_URL "https://eternaltwin.${domain}/"
    update_release_metadata "${commit_hash}"
    ensure_app_secret
    ensure_jwt_passphrase
    ensure_db_password_and_sync
    ensure_etwin_admin_password_and_sync
    ensure_oauth_secret_and_sync
    ensure_vapid_keys
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
	APP_URL="https://emush.${domain}/"
    echo -e "${YELLOW}Launching app...${NC}"
    docker compose build --no-cache
    docker compose run --rm emush-api php bin/console lexik:jwt:generate-keypair --no-interaction --skip-if-exists
    docker compose run --rm emush-eternaltwin yarn eternaltwin db sync
    docker compose up --force-recreate --remove-orphans -d --wait --wait-timeout 15
    docker compose run --rm emush-api php bin/console mush:migrate
    ensure_admin_id_from_database
    docker compose up --force-recreate --remove-orphans -d --wait --wait-timeout 15
    echo -e "${GREEN}App launched at ${APP_URL}${NC}"
    
    # Only display admin credentials if not in CI environment
    if [ -z "${CI:-}" ]; then
        log_info "You can connect with admin account:"
        log_info "  - username: admin"
        log_info "  - password: ${admin_pass} (please change it)"
    fi
}

main() {
    pull_latest_code
    setup_env_variables
    launch_app
}

main