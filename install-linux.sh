#!/usr/bin/env bash
# =============================================================================
# PayShield — Generic Linux Installer (any distro with Docker already installed)
#
# Counterpart to install-ubuntu.sh for non-Ubuntu Linux hosts (Debian,
# RHEL/CentOS/Rocky, Amazon Linux, openSUSE, Arch, etc.). Distro package
# managers differ too much (apt/yum/dnf/zypper/pacman) to script generically
# and safely, so this script assumes Docker Engine + the Compose plugin are
# ALREADY installed via your distro's own package manager --
# https://docs.docker.com/engine/install/ has the exact steps per distro.
# Everything after that point (env generation, TLS cert, compose actions,
# tier selection) is identical to install-ubuntu.sh.
#
# Run as root or with sudo, from the project root:
#   sudo bash install/install-linux.sh
#
# Environment options (export before running):
#   PAYSHIELD_ENV     development | uat | production  (default: development)
#   PAYSHIELD_DOMAIN  hostname for nginx TLS cert     (default: localhost)
#   INSTALL_DIR       where to copy the stack          (default: /opt/payshield)
#   SKIP_OLLAMA       set to 1 to skip the 4 GB LLM pull (full tier only)
#   PAYSHIELD_TIER    full | minimal  (default: full)
#     full    — all 15 services (docker-compose.yml)
#     minimal — 4 services only (install/docker-compose.minimal.linux.yml):
#               nginx, backend, postgres, redis. Same 4-service definition
#               already proven in payshield-backend/docker-compose.minimal.yml.
#
# Actions (pass as first argument):
#   install   Full install — checks Docker, env, TLS, starts the stack (default)
#   up        Start the stack (Docker already installed, .env already exists)
#   down      Stop containers (keep data)
#   destroy   Stop + delete ALL data
#   restart   Restart all containers
#   logs      Tail all service logs
#   status    Container status
#   health    HTTP health-check all services
#   migrate   Run Alembic migrations
#   update    Pull latest images + rebuild
#   uninstall Remove containers and volumes (does NOT touch Docker itself)
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'; RESET='\033[0m'

step()  { echo -e "${CYAN}  ==> $*${RESET}"; }
ok()    { echo -e "${GREEN}   ok  $*${RESET}"; }
warn()  { echo -e "${YELLOW} WARN  $*${RESET}"; }
err()   { echo -e "${RED}ERROR  $*${RESET}" >&2; }
banner(){ echo ""; echo -e "${WHITE}$(printf '=%.0s' {1..60})${RESET}"; echo -e "${WHITE}  $*${RESET}"; echo -e "${WHITE}$(printf '=%.0s' {1..60})${RESET}"; echo ""; }

# ── Configuration ─────────────────────────────────────────────────────────────
ACTION="${1:-install}"
PAYSHIELD_ENV="${PAYSHIELD_ENV:-development}"
PAYSHIELD_DOMAIN="${PAYSHIELD_DOMAIN:-localhost}"
INSTALL_DIR="${INSTALL_DIR:-/opt/payshield}"
SKIP_OLLAMA="${SKIP_OLLAMA:-0}"
PAYSHIELD_TIER="${PAYSHIELD_TIER:-full}"
BACKEND_DIR="$INSTALL_DIR/payshield-backend"
NGINX_DIR="$INSTALL_DIR/nginx"
INSTALL_SCRIPTS_DIR="$INSTALL_DIR/install"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ "$PAYSHIELD_TIER" != "full" && "$PAYSHIELD_TIER" != "minimal" ]]; then
    echo "ERROR: PAYSHIELD_TIER must be 'full' or 'minimal', got: $PAYSHIELD_TIER" >&2
    exit 1
fi

compose_args() {
    if [[ "$PAYSHIELD_TIER" == "minimal" ]]; then
        echo "-f $INSTALL_SCRIPTS_DIR/docker-compose.minimal.linux.yml --env-file .env"
    else
        echo ""
    fi
}

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo bash $0)"
    exit 1
fi

# =============================================================================
# SECTION 1 — PREREQUISITE CHECK (Docker assumed pre-installed)
# =============================================================================

check_docker() {
    step "Checking Docker..."
    if ! command -v docker &>/dev/null; then
        err "Docker not found. Install Docker Engine + Compose plugin for your"
        err "distro first: https://docs.docker.com/engine/install/"
        exit 1
    fi
    if ! docker compose version &>/dev/null; then
        err "Docker Compose plugin not found. Install it alongside Docker Engine:"
        err "https://docs.docker.com/engine/install/ (includes the compose plugin"
        err "on all supported distros)."
        exit 1
    fi
    ok "Docker found: $(docker --version)"
    ok "docker compose found: $(docker compose version)"
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        warn "Docker service does not appear active — attempting to start it..."
        systemctl enable --now docker 2>/dev/null || \
            warn "Could not start Docker via systemctl — start it manually for your distro/init system."
    fi
}

configure_sysctl() {
    step "Tuning kernel parameters for containers..."
    cat > /etc/sysctl.d/99-payshield.conf << 'EOF'
fs.file-max = 1048576
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
vm.max_map_count = 262144
vm.swappiness = 10
EOF
    sysctl --system -q 2>/dev/null || warn "sysctl --system failed — apply /etc/sysctl.d/99-payshield.conf manually if needed"
    ok "Kernel parameters tuned"
}

configure_ulimits() {
    step "Setting ulimits..."
    cat > /etc/security/limits.d/99-payshield.conf << 'EOF'
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    ok "ulimits configured"
}

# =============================================================================
# SECTION 2 — PROJECT FILES
# =============================================================================

setup_install_dir() {
    step "Setting up install directory $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"

    if [[ -d "$PROJECT_ROOT/payshield-backend" ]]; then
        step "Copying project files from $PROJECT_ROOT..."
        rsync -a --exclude='.git' "$PROJECT_ROOT/" "$INSTALL_DIR/" 2>/dev/null || \
            cp -r "$PROJECT_ROOT/." "$INSTALL_DIR/"
        ok "Project files copied to $INSTALL_DIR"
    else
        err "payshield-backend not found at $PROJECT_ROOT"
        err "Please run this script from the project root directory."
        exit 1
    fi

    step "Normalising shell script line endings..."
    find "$INSTALL_DIR" -name "*.sh" -exec sed -i 's/\r$//' {} \;
    ok "Line endings normalised"

    chmod +x "$BACKEND_DIR/entrypoint.sh" 2>/dev/null || true
    chmod +x "$BACKEND_DIR/infra/postgres/init-multiple-dbs.sh" 2>/dev/null || true
    chmod +x "$BACKEND_DIR/infra/vault/vault-init.sh" 2>/dev/null || true
    ok "Script permissions set"

    DEPLOY_USER="${SUDO_USER:-$(id -un)}"
    chown -R "$DEPLOY_USER:$DEPLOY_USER" "$INSTALL_DIR" 2>/dev/null || true
    ok "Ownership set to $DEPLOY_USER"
}

# =============================================================================
# SECTION 3 — ENVIRONMENT FILE WITH SECURE SECRETS
# =============================================================================

generate_env() {
    local env_file="$BACKEND_DIR/.env"
    step "Checking .env file..."

    if [[ -f "$env_file" ]]; then
        ok ".env already exists — skipping generation"
        return
    fi

    if [[ ! -f "$BACKEND_DIR/.env.example" ]]; then
        err ".env.example not found at $BACKEND_DIR"
        exit 1
    fi

    if ! command -v openssl &>/dev/null; then
        err "openssl not found — install it via your distro's package manager first."
        exit 1
    fi

    step "Generating $env_file with cryptographically-secure secrets..."

    hex32()    { openssl rand -hex 32; }
    hex20()    { openssl rand -hex 20; }
    b64_32()   { openssl rand -base64 32 | tr -d '\n'; }
    fernet()   { python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_'; }

    PG_PASS=$(hex20)
    MINIO_PASS=$(hex20)
    NEO4J_PASS=$(hex20)
    API_KEY=$(hex32)
    JWT_SECRET=$(hex32)
    ADMIN_KEY=$(hex20)
    SIGNING_KEY=$(b64_32)
    FERNET_KEY=$(fernet)
    AIRFLOW_WS=$(hex32)
    GRAFANA_PASS=$(hex20)
    AIRFLOW_ADMIN_PASS=$(openssl rand -hex 16)
    CSRF_SECRET=$(hex32)
    EDGE_INTERNAL_SECRET=$(hex32)
    JWT_PRIVATE_KEY_PEM_FILE=$(mktemp)
    JWT_PUBLIC_KEY_PEM_FILE=$(mktemp)
    openssl genrsa -out "$JWT_PRIVATE_KEY_PEM_FILE" 2048 2>/dev/null
    openssl rsa -in "$JWT_PRIVATE_KEY_PEM_FILE" -pubout -out "$JWT_PUBLIC_KEY_PEM_FILE" 2>/dev/null
    JWT_PRIVATE_KEY_PEM=$(awk 'BEGIN{ORS="\\n"} {print}' "$JWT_PRIVATE_KEY_PEM_FILE")
    JWT_PUBLIC_KEY_PEM=$(awk 'BEGIN{ORS="\\n"} {print}' "$JWT_PUBLIC_KEY_PEM_FILE")
    rm -f "$JWT_PRIVATE_KEY_PEM_FILE" "$JWT_PUBLIC_KEY_PEM_FILE"

    cp "$BACKEND_DIR/.env.example" "$env_file"

    sed -i "s/payshield_secret/${PG_PASS}/g"              "$env_file"
    sed -i "s/payshield_minio_secret/${MINIO_PASS}/g"     "$env_file"
    sed -i "s/payshield_neo4j/${NEO4J_PASS}/g"            "$env_file"
    sed -i "s/change-me-in-production-32-chars!!/${API_KEY}/g"      "$env_file"
    sed -i "s/change-me-jwt-secret-32-chars!!!/${JWT_SECRET}/g"     "$env_file"
    # BUG FIX (2026-07): this pattern never matched anything -- .env.example's
    # actual placeholder is `BACKEND_API_KEY=ABCDEFGHI`, not the literal string
    # "change-me-admin-api-key", so ADMIN_KEY was generated above and silently
    # discarded on every install. Every fresh deployment kept the well-known,
    # publicly-documented demo key (see app/docs/openapi_config.py) sitting in
    # its real .env. Matched by key name (robust to the placeholder value ever
    # changing), mirroring the anchored CSRF_SECRET replacement below.
    sed -i "s/^BACKEND_API_KEY=.*/BACKEND_API_KEY=${ADMIN_KEY}/"     "$env_file"
    sed -i "s|<base64-encoded-32-byte-key>|${SIGNING_KEY}|g"        "$env_file"
    sed -i "s|change-me-fernet-key-base64-encoded=|${FERNET_KEY}|g" "$env_file"
    sed -i "s/change-me-webserver-secret/${AIRFLOW_WS}/g"           "$env_file"
    sed -i "s/payshield_grafana/${GRAFANA_PASS}/g"                   "$env_file"
    sed -i "s/payshield_airflow_admin/${AIRFLOW_ADMIN_PASS}/g"       "$env_file"
    sed -i "s/^CSRF_SECRET=$/CSRF_SECRET=${CSRF_SECRET}/"            "$env_file"
    {
        echo "EDGE_INTERNAL_SECRET=${EDGE_INTERNAL_SECRET}"
        echo "JWT_PRIVATE_KEY_PEM=\"${JWT_PRIVATE_KEY_PEM}\""
        echo "JWT_PUBLIC_KEY_PEM=\"${JWT_PUBLIC_KEY_PEM}\""
    } >> "$env_file"

    sed -i "s/^APP_ENV=.*/APP_ENV=${PAYSHIELD_ENV}/"     "$env_file"
    if [[ "$PAYSHIELD_ENV" == "production" ]]; then
        sed -i "s/^UVICORN_WORKERS=.*/UVICORN_WORKERS=4/"    "$env_file"
        sed -i "s/^LOG_FORMAT=.*/LOG_FORMAT=json/"            "$env_file"
        sed -i "s/^LOG_LEVEL=.*/LOG_LEVEL=INFO/"              "$env_file"
    elif [[ "$PAYSHIELD_ENV" == "uat" ]]; then
        sed -i "s/^UVICORN_WORKERS=.*/UVICORN_WORKERS=2/"    "$env_file"
    fi

    chmod 600 "$env_file"
    chown "${SUDO_USER:-$(id -un)}:${SUDO_USER:-$(id -un)}" "$env_file" 2>/dev/null || true

    ok ".env written with fresh secrets"
    echo ""
    echo -e "${YELLOW}  IMPORTANT — save these values in a secure password manager:${RESET}"
    echo -e "${WHITE}    Postgres password  : $PG_PASS${RESET}"
    echo -e "${WHITE}    MinIO password     : $MINIO_PASS${RESET}"
    echo -e "${WHITE}    Neo4j password     : $NEO4J_PASS${RESET}"
    echo -e "${WHITE}    Grafana password   : $GRAFANA_PASS${RESET}"
    echo -e "${WHITE}    Admin API key      : $ADMIN_KEY${RESET}"
    echo -e "${WHITE}    CSRF secret        : $CSRF_SECRET${RESET}"
    echo -e "${WHITE}    Edge internal key  : $EDGE_INTERNAL_SECRET${RESET}"
    echo -e "${DIM}    JWT RSA key pair generated and written to .env directly${RESET}"
    echo ""
    warn "SSL_DIR and GEOIP_DIR are NOT auto-generated — nginx requires both in"
    warn "every tier. Set them in .env yourself before 'up' — see"
    warn "docker-compose.yml's (or docker-compose.minimal.*.yml's) header comment."
}

# =============================================================================
# SECTION 4 — TLS CERTIFICATE (self-signed placeholder)
# =============================================================================

generate_tls_cert() {
    step "Setting up TLS certificate for $PAYSHIELD_DOMAIN..."
    local cert_dir="$INSTALL_DIR/nginx/certs"
    mkdir -p "$cert_dir"

    # nginx/nginx.conf hard-codes fullchain.pem / privkey.pem exactly.
    if [[ -f "$cert_dir/fullchain.pem" && -f "$cert_dir/privkey.pem" ]]; then
        ok "TLS certificate already exists"
    else
        if [[ "$PAYSHIELD_ENV" == "production" && "$PAYSHIELD_DOMAIN" != "localhost" ]]; then
            warn "For production: obtain a real cert for $PAYSHIELD_DOMAIN (certbot or"
            warn "your CA of choice — package name/steps vary by distro) and copy"
            warn "fullchain.pem + privkey.pem into $cert_dir"
        fi
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$cert_dir/privkey.pem" \
            -out    "$cert_dir/fullchain.pem" \
            -subj   "/C=IN/ST=Maharashtra/L=Mumbai/O=PayShield/CN=$PAYSHIELD_DOMAIN" \
            -addext "subjectAltName=DNS:$PAYSHIELD_DOMAIN,DNS:localhost,IP:127.0.0.1" \
            2>/dev/null
        chmod 600 "$cert_dir/privkey.pem"
        ok "Self-signed TLS certificate created at $cert_dir"
    fi

    if ! grep -q "^SSL_DIR=" "$BACKEND_DIR/.env" 2>/dev/null; then
        echo "SSL_DIR=${cert_dir}" >> "$BACKEND_DIR/.env"
        ok "SSL_DIR set in .env -> $cert_dir"
    fi

    local geoip_dir="$INSTALL_DIR/nginx/geoip"
    mkdir -p "$geoip_dir"
    if ! grep -q "^GEOIP_DIR=" "$BACKEND_DIR/.env" 2>/dev/null; then
        echo "GEOIP_DIR=${geoip_dir}" >> "$BACKEND_DIR/.env"
        warn "GEOIP_DIR set in .env -> $geoip_dir (EMPTY — download GeoLite2-City.mmdb,"
        warn "GeoLite2-ASN.mmdb, GeoLite2-Anonymous-IP.mmdb into it: free account at"
        warn "https://dev.maxmind.com/geoip/geolite2-free-geolocation-data)"
    fi
}

# =============================================================================
# SECTION 5 — SYSTEMD AUTO-START SERVICE (best-effort — not every distro/init)
# =============================================================================

install_systemd_service() {
    if ! command -v systemctl &>/dev/null; then
        warn "systemctl not found — skipping auto-start service (non-systemd init?)."
        warn "Start the stack manually after reboot: sudo bash install/install-linux.sh up"
        return
    fi
    step "Installing systemd service (payshield.service)..."
    local args; args="$(compose_args)"
    cat > /etc/systemd/system/payshield.service << EOF
[Unit]
Description=PayShield Application Stack (${PAYSHIELD_TIER} tier)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${BACKEND_DIR}
ExecStart=/usr/bin/docker compose ${args} up -d --build
ExecStop=/usr/bin/docker compose ${args} down
ExecReload=/usr/bin/docker compose ${args} restart
TimeoutStartSec=300
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal
SyslogIdentifier=payshield

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable payshield.service
    ok "payshield.service installed and enabled (starts on boot)"
}

install_logrotate() {
    step "Configuring log rotation..."
    if [[ ! -d /etc/logrotate.d ]]; then
        warn "logrotate not found — skipping (not fatal, just no log rotation)."
        return
    fi
    cat > /etc/logrotate.d/payshield << 'EOF'
/var/log/payshield/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
}
EOF
    mkdir -p /var/log/payshield
    ok "Log rotation configured (14-day retention)"
}

# =============================================================================
# SECTION 6 — DOCKER COMPOSE ACTIONS
# =============================================================================

compose_up() {
    local args; args="$(compose_args)"
    banner "Starting PayShield Stack (${PAYSHIELD_TIER} tier)"
    cd "$BACKEND_DIR"

    step "Pulling latest base images..."
    docker compose $args pull --ignore-pull-failures 2>&1 | grep -E "(Pulling|Pull complete|up to date|error)" | \
        while IFS= read -r line; do echo -e "${DIM}   $line${RESET}"; done || true

    step "Building and starting all containers..."
    docker compose $args up --build -d

    step "Waiting for infrastructure health checks (up to 3 minutes)..."
    local services
    if [[ "$PAYSHIELD_TIER" == "minimal" ]]; then
        services=("payshield-postgres" "payshield-redis")
    else
        services=("payshield-postgres" "payshield-redis" "payshield-redpanda" "payshield-neo4j" "payshield-minio" "payshield-vault")
    fi
    local deadline=$((SECONDS + 180))
    local all_healthy=false

    while [[ $SECONDS -lt $deadline ]]; do
        all_healthy=true
        for svc in "${services[@]}"; do
            local status
            status=$(docker inspect --format "{{.State.Health.Status}}" "$svc" 2>/dev/null || echo "missing")
            if [[ "$status" != "healthy" ]]; then
                all_healthy=false
            fi
        done
        if $all_healthy; then break; fi
        echo -e "${DIM}   ... still waiting for infrastructure (${SECONDS}s / 180s)${RESET}"
        sleep 5
    done

    if $all_healthy; then
        ok "All infrastructure services healthy"
    else
        warn "Some services may still be initialising"
    fi

    step "Waiting for backend API (up to 2 minutes)..."
    local api_deadline=$((SECONDS + 120))
    while [[ $SECONDS -lt $api_deadline ]]; do
        if curl -sf http://localhost:8000/health > /dev/null 2>&1; then
            ok "Backend API is ready"
            break
        fi
        echo -e "${DIM}   ... waiting for backend${RESET}"
        sleep 5
    done

    if [[ "$PAYSHIELD_TIER" != "minimal" && "$SKIP_OLLAMA" != "1" ]]; then
        step "Pulling LLaMA3 model (this is a one-time ~4 GB download)..."
        docker exec payshield-ollama ollama pull llama3 2>&1 | tail -3 || \
            warn "Ollama pull failed — model will be pulled on first use"
    fi

    print_service_urls
}

print_service_urls() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip="localhost"

    banner "PayShield is READY (${PAYSHIELD_TIER} tier)"
    echo -e "  ${WHITE}Service                  URL${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${CYAN}Backend API (Swagger)    http://${ip}:8000/docs${RESET}"
    echo -e "  ${CYAN}Backend Health           http://${ip}:8000/health${RESET}"
    if [[ "$PAYSHIELD_TIER" == "minimal" ]]; then
        echo -e "  ${CYAN}SOC Dashboard            http://${ip}:8000/dashboard${RESET}"
        echo ""
        echo -e "  ${DIM}Not part of this tier (re-run with PAYSHIELD_TIER=full for these):${RESET}"
        echo -e "  ${DIM}  Neo4j, MinIO, Redpanda/Kafka, AI Fraud Advisory (Ollama),${RESET}"
        echo -e "  ${DIM}  Airflow, Prometheus, Grafana, Vault UI${RESET}"
    else
        echo -e "  ${CYAN}Go Ingest Service        http://${ip}:8080${RESET}"
        echo -e "  ${CYAN}Redpanda Console         http://${ip}:8081${RESET}"
        echo -e "  ${CYAN}Airflow Orchestrator     http://${ip}:8083  (admin / see .env)${RESET}"
        echo -e "  ${CYAN}Grafana Dashboards       http://${ip}:3000  (admin / see .env)${RESET}"
        echo -e "  ${CYAN}MinIO Console            http://${ip}:9001  (payshield / see .env)${RESET}"
        echo -e "  ${CYAN}Neo4j Browser            http://${ip}:7474  (neo4j / see .env)${RESET}"
        echo -e "  ${CYAN}Prometheus               http://${ip}:9090${RESET}"
        echo -e "  ${CYAN}Vault UI                 http://${ip}:8200  (token: root)${RESET}"
    fi
    echo ""
    echo -e "  ${DIM}Management:${RESET}"
    echo -e "  ${DIM}  sudo bash install/install-linux.sh logs     # tail logs${RESET}"
    echo -e "  ${DIM}  sudo bash install/install-linux.sh status   # container status${RESET}"
    echo -e "  ${DIM}  sudo bash install/install-linux.sh health   # HTTP health checks${RESET}"
    echo -e "  ${DIM}  sudo bash install/install-linux.sh down     # stop, keep data${RESET}"
    echo -e "  ${DIM}  sudo bash install/install-linux.sh destroy  # stop + wipe data${RESET}"
    echo ""
    echo -e "  ${DIM}.env file: $BACKEND_DIR/.env  (chmod 600, keep secret)${RESET}"
    echo -e "  ${DIM}Tier: PAYSHIELD_TIER=${PAYSHIELD_TIER}  (export PAYSHIELD_TIER=full|minimal before re-running to switch)${RESET}"
    echo ""
}

compose_down() {
    local args; args="$(compose_args)"
    banner "Stopping PayShield (data preserved)"
    cd "$BACKEND_DIR"
    docker compose $args down
    ok "Containers stopped. Run 'up' to restart."
}

compose_restart() {
    local args; args="$(compose_args)"
    banner "Restarting PayShield"
    cd "$BACKEND_DIR"
    docker compose $args restart
    ok "All containers restarted."
}

compose_destroy() {
    local args; args="$(compose_args)"
    echo ""
    echo -e "${RED}  WARNING: This will DELETE ALL DATA (databases, Kafka topics, Neo4j, MinIO buckets, AI models).${RESET}"
    read -rp "  Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "  Aborted."
        exit 0
    fi
    banner "Destroying PayShield Stack + Volumes"
    cd "$BACKEND_DIR"
    docker compose $args down -v --remove-orphans
    ok "Destroyed. Run 'install' for a clean start."
}

compose_logs() {
    local args; args="$(compose_args)"
    banner "PayShield Logs (Ctrl+C to stop)"
    cd "$BACKEND_DIR"
    docker compose $args logs -f
}

compose_migrate() {
    local args; args="$(compose_args)"
    banner "Running Alembic Migrations"
    cd "$BACKEND_DIR"
    docker compose $args exec backend alembic upgrade head
    ok "Migrations complete."
}

compose_status() {
    local args; args="$(compose_args)"
    banner "PayShield Container Status"
    cd "$BACKEND_DIR"
    docker compose $args ps
}

compose_health() {
    banner "PayShield HTTP Health Checks"
    local services
    if [[ "$PAYSHIELD_TIER" == "minimal" ]]; then
        services=("Backend API|http://localhost:8000/health")
    else
        services=(
            "Backend API|http://localhost:8000/health"
            "Prometheus|http://localhost:9090/-/healthy"
            "Grafana|http://localhost:3000/api/health"
            "MinIO|http://localhost:9000/minio/health/live"
        )
    fi
    for entry in "${services[@]}"; do
        local name="${entry%%|*}"
        local url="${entry##*|}"
        if curl -sf "$url" > /dev/null 2>&1; then
            ok "$name — reachable ($url)"
        else
            warn "$name — NOT reachable ($url)"
        fi
    done
    echo ""
    local args; args="$(compose_args)"
    cd "$BACKEND_DIR"
    docker compose $args ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
}

compose_update() {
    local args; args="$(compose_args)"
    banner "Updating PayShield"
    cd "$BACKEND_DIR"
    docker compose $args pull --ignore-pull-failures
    docker compose $args up --build -d
    ok "Update complete."
}

do_uninstall() {
    echo ""
    echo -e "${RED}  WARNING: This will remove all PayShield containers and volumes.${RESET}"
    read -rp "  Type 'uninstall' to confirm: " confirm
    if [[ "$confirm" != "uninstall" ]]; then
        echo "  Aborted."
        exit 0
    fi
    banner "Uninstalling PayShield"
    cd "$BACKEND_DIR" 2>/dev/null || true
    docker compose down -v --remove-orphans 2>/dev/null || true
    docker compose -f "$INSTALL_SCRIPTS_DIR/docker-compose.minimal.linux.yml" --env-file .env down -v --remove-orphans 2>/dev/null || true
    if command -v systemctl &>/dev/null; then
        systemctl disable --now payshield.service 2>/dev/null || true
        rm -f /etc/systemd/system/payshield.service
        systemctl daemon-reload
    fi
    ok "PayShield uninstalled. Docker itself is NOT removed."
}

# =============================================================================
# SECTION 7 — MAIN ENTRY POINT
# =============================================================================

banner "PayShield — Generic Linux Installer"
echo -e "  Environment : ${CYAN}${PAYSHIELD_ENV}${RESET}"
echo -e "  Domain      : ${CYAN}${PAYSHIELD_DOMAIN}${RESET}"
echo -e "  Install dir : ${CYAN}${INSTALL_DIR}${RESET}"
echo -e "  Tier        : ${CYAN}${PAYSHIELD_TIER}${RESET}"
echo -e "  Action      : ${CYAN}${ACTION}${RESET}"
echo ""

case "$ACTION" in
    install)
        check_docker
        configure_sysctl
        configure_ulimits
        setup_install_dir
        generate_env
        generate_tls_cert
        install_logrotate
        install_systemd_service
        compose_up
        ;;
    up)       compose_up ;;
    down)     compose_down ;;
    restart)  compose_restart ;;
    destroy)  compose_destroy ;;
    logs)     compose_logs ;;
    status)   compose_status ;;
    health)   compose_health ;;
    migrate)  compose_migrate ;;
    update)   compose_update ;;
    urls)     print_service_urls ;;
    uninstall) do_uninstall ;;
    *)
        echo ""
        echo "  Usage: sudo bash install/install-linux.sh [action]"
        echo ""
        echo "  Actions:"
        echo "    install    Full install — check Docker, env setup, stack start (default)"
        echo "    up         Start the stack (Docker already installed)"
        echo "    down       Stop containers (keep data)"
        echo "    restart    Restart all containers"
        echo "    destroy    Stop + delete ALL data (irreversible)"
        echo "    logs       Tail all service logs"
        echo "    status     Show container status table"
        echo "    health     HTTP health-check all services"
        echo "    migrate    Run Alembic DB migrations"
        echo "    update     Pull latest images + rebuild"
        echo "    urls       Print all service URLs"
        echo "    uninstall  Remove containers, volumes, systemd service"
        echo ""
        echo "  Environment variables:"
        echo "    PAYSHIELD_ENV     development | uat | production  (default: development)"
        echo "    PAYSHIELD_DOMAIN  your hostname for TLS cert      (default: localhost)"
        echo "    INSTALL_DIR       installation path               (default: /opt/payshield)"
        echo "    SKIP_OLLAMA       set to 1 to skip LLaMA3 download"
        echo "    PAYSHIELD_TIER    full | minimal                  (default: full)"
        echo ""
        echo "  Example — minimal-tier install:"
        echo "    sudo PAYSHIELD_TIER=minimal bash install/install-linux.sh"
        echo ""
        exit 1
        ;;
esac
