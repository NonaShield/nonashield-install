# =============================================================================
# PayShield — One-Step Windows Installer
# Installs ALL prerequisites, configures environment, and starts the full stack.
#
# Run from PowerShell (Administrator) in the project root:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\install\install-windows.ps1
#
# What this script does:
#   1. Checks Windows version and enables WSL2 if missing
#   2. Installs Docker Desktop via winget (if not present)
#   3. Installs Git for Windows (if not present)
#   4. Fixes shell-script line endings (CRLF → LF)
#   5. Generates a .env with cryptographically-secure secrets
#   6. Pulls all Docker images and starts the 13-layer stack
#   7. Waits for infrastructure health checks to pass
#   8. Prints all service URLs
#
# Actions (pass -Action <name>):
#   up       Build and start all services (default)
#   down     Stop containers (keep data)
#   destroy  Stop containers AND delete all volumes / data
#   restart  Restart all containers
#   logs     Tail all service logs
#   status   Show container status
#   health   Check backend health endpoint
#   migrate  Run Alembic DB migrations inside backend container
#   shell    Open bash shell inside backend container
#   update   Pull latest images and redeploy
# =============================================================================

param(
    [string]$Action = "up",
    [switch]$SkipPrereqs,
    [switch]$NoColor
)

$ErrorActionPreference = "Stop"

# ── Colour helpers ────────────────────────────────────────────────────────────
function Write-Step  ($msg) { if (-not $NoColor) { Write-Host "  ==> $msg" -ForegroundColor Cyan   } else { Write-Host "  ==> $msg" } }
function Write-OK    ($msg) { if (-not $NoColor) { Write-Host "   ok  $msg" -ForegroundColor Green  } else { Write-Host "   ok  $msg" } }
function Write-Warn  ($msg) { if (-not $NoColor) { Write-Host " WARN  $msg" -ForegroundColor Yellow } else { Write-Host " WARN  $msg" } }
function Write-Err   ($msg) { if (-not $NoColor) { Write-Host "ERROR  $msg" -ForegroundColor Red    } else { Write-Host "ERROR  $msg" } }
function Write-Banner($msg) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host "  $msg" -ForegroundColor White
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host ""
}

# ── Locate project root (script lives in install\) ───────────────────────────
$SCRIPT_DIR  = Split-Path -Parent $MyInvocation.MyCommand.Path
$PROJECT_ROOT = Split-Path -Parent $SCRIPT_DIR          # …/Code
# The GitHub repo is "nonashield-backend" (org: NonaShield) -- a plain
# `git clone` produces a folder with that name. Everything inside the repo
# (env vars, docker service/container names, .env.example) still says
# "payshield" from before the rebrand, so this and every other install
# script historically hardcoded "payshield-backend" as the sibling folder
# name. Checking both means a fresh clone of the real repo works with zero
# manual rename step.
if (Test-Path (Join-Path $PROJECT_ROOT "payshield-backend")) {
    $BACKEND_DIR = Join-Path $PROJECT_ROOT "payshield-backend"
} else {
    $BACKEND_DIR = Join-Path $PROJECT_ROOT "nonashield-backend"
}
$NGINX_DIR    = Join-Path $PROJECT_ROOT "nginx"

if (-not (Test-Path (Join-Path $BACKEND_DIR "docker-compose.yml"))) {
    Write-Err "Cannot find docker-compose.yml in payshield-backend\ or nonashield-backend\"
    Write-Err "Expected layout: <root>\payshield-backend\ (or nonashield-backend\)   and  <root>\install\"
    exit 1
}

# docker-compose.full.windows.yml itself hardcodes ~20 relative
# ../payshield-backend/... paths for build context and bind mounts (proven,
# working -- deliberately not rewritten here, since editing that many mount
# paths is a much higher-risk change than this one-time compatibility
# junction). If the real folder is actually named nonashield-backend, make
# those hardcoded paths keep resolving by linking the old name to it.
if ($BACKEND_DIR -eq (Join-Path $PROJECT_ROOT "nonashield-backend")) {
    $CompatLink = Join-Path $PROJECT_ROOT "payshield-backend"
    if (-not (Test-Path $CompatLink)) {
        New-Item -ItemType Junction -Path $CompatLink -Target $BACKEND_DIR | Out-Null
    }
}

Set-Location $BACKEND_DIR

# =============================================================================
# PREREQUISITE CHECKS & INSTALLATION
# =============================================================================

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-WSL2 {
    Write-Step "Checking WSL2..."
    $wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
    if ($wsl -and $wsl.State -eq "Enabled") {
        Write-OK "WSL2 already enabled"
        return
    }
    Write-Warn "WSL2 not enabled — enabling now (may require reboot)"
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart | Out-Null
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart | Out-Null
    wsl --set-default-version 2 2>&1 | Out-Null
    Write-OK "WSL2 enabled"
}

function Ensure-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return }
    Write-Warn "winget not found — downloading App Installer..."
    $url  = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    $dest = "$env:TEMP\AppInstaller.msixbundle"
    Invoke-WebRequest $url -OutFile $dest -UseBasicParsing
    Add-AppxPackage $dest
    Write-OK "winget installed"
}

function Ensure-DockerDesktop {
    Write-Step "Checking Docker Desktop..."
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $v = docker --version 2>&1
        Write-OK "Docker found: $v"
        return
    }
    Write-Warn "Docker Desktop not found — installing via winget..."
    Ensure-Winget
    winget install --id Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Err "winget install failed. Download manually: https://docs.docker.com/desktop/windows/"
        exit 1
    }
    Write-OK "Docker Desktop installed — please start Docker Desktop and re-run this script"
    Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe" -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "  Docker Desktop is starting. Wait until the whale icon appears in the system tray," -ForegroundColor Yellow
    Write-Host "  then re-run:  .\install\install-windows.ps1" -ForegroundColor Yellow
    exit 0
}

function Ensure-Git {
    Write-Step "Checking Git..."
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $v = git --version 2>&1
        Write-OK "Git found: $v"
        return
    }
    Write-Warn "Git not found — installing via winget..."
    Ensure-Winget
    winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements
    $env:PATH += ";C:\Program Files\Git\cmd"
    Write-OK "Git installed"
}

function Wait-DockerDaemon {
    Write-Step "Waiting for Docker daemon..."
    $retries = 0
    while ($retries -lt 30) {
        $info = docker info 2>&1
        if ($LASTEXITCODE -eq 0) { Write-OK "Docker daemon ready"; return }
        $retries++
        Write-Host "   ... waiting ($retries/30)" -ForegroundColor DarkGray
        Start-Sleep 5
    }
    Write-Err "Docker daemon did not start in 150 seconds."
    Write-Err "Open Docker Desktop manually and wait for it to initialise, then re-run."
    exit 1
}

# =============================================================================
# ENV FILE GENERATION WITH SECURE SECRETS
# =============================================================================

function New-SecureHex([int]$bytes = 32) {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] $bytes
    $rng.GetBytes($buf)
    return ([BitConverter]::ToString($buf) -replace "-","").ToLower()
}

function New-SecureBase64([int]$bytes = 32) {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] $bytes
    $rng.GetBytes($buf)
    return [Convert]::ToBase64String($buf)
}

function New-FernetKey {
    # Fernet key = 32 random bytes, url-safe base64 + "=" padding
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] 32
    $rng.GetBytes($buf)
    $b64 = [Convert]::ToBase64String($buf)
    return $b64 -replace "\+","-" -replace "/","_"
}

function Ensure-EnvFile {
    Write-Step "Checking .env file..."
    if (Test-Path ".env") {
        Write-OK ".env already exists — skipping generation"
        return
    }
    if (-not (Test-Path ".env.example")) {
        Write-Err ".env.example not found in $BACKEND_DIR"
        exit 1
    }

    Write-Step "Generating .env with secure random secrets..."

    $pgPass     = New-SecureHex 20
    $redisPass  = New-SecureHex 20
    $apiKey     = New-SecureHex 32
    $jwtSecret  = New-SecureHex 32
    $adminKey   = New-SecureHex 24
    $signingKey = New-SecureBase64 32
    $minioPass  = New-SecureHex 20
    # MINIO_KMS_SECRET_KEY: without this, MinIO has no encryption backend at
    # all and rejects every evidence upload with "NotImplemented ... KMS not
    # configured" -- storage_client.py sends a mandatory ServerSideEncryption
    # header on every PutObject regardless of tier. Confirmed live: this
    # silently broke evidence storage AND meant Object Lock retention never
    # got a chance to apply, since the upload itself never succeeded.
    # .env.example's placeholder keeps the required "name:key" MinIO format
    # intact -- only the base64 portion is replaced below.
    $minioKmsKey = New-SecureBase64 32
    $neo4jPass  = New-SecureHex 20
    $fernetKey  = New-FernetKey
    $airflowWS  = New-SecureHex 24
    $grafanaPass= New-SecureHex 16
    # Both nginx and backend hard-require these (":?must be set") in every
    # tier's compose file -- .env.example has no placeholder for
    # EDGE_INTERNAL_SECRET at all (appended below), and an empty
    # EDGE_CONTEXT_HMAC_KEY= placeholder (left blank for local dev, replaced
    # in-place here).
    $edgeInternalSecret = New-SecureHex 32
    $edgeContextHmacKey = New-SecureHex 32
    # DASHBOARD_SUPER_ADMIN_PASSWORD has a non-empty placeholder in
    # .env.example ("change_me_on_first_login_min8chars"), which satisfies
    # this compose file's ":?must be set" check without ever being replaced --
    # every fresh install was shipping the same publicly-documented default
    # super-admin password. Matched by literal placeholder value and replaced.
    $dashboardAdminPass = New-SecureHex 16
    $airflowAdminPass   = New-SecureHex 12
    # docker-compose.full.windows.yml reads AIRFLOW_FERNET_KEY / AIRFLOW_SECRET_KEY /
    # AIRFLOW_ADMIN_PASSWORD / VAULT_DEV_TOKEN (":?must be set") to feed the
    # container's actual AIRFLOW__CORE__FERNET_KEY / AIRFLOW__WEBSERVER__SECRET_KEY /
    # _AIRFLOW_WWW_USER_PASSWORD / VAULT_TOKEN env vars via interpolation. Those are
    # DIFFERENT names than the ones .env.example defines and this function replaces
    # in-place below (AIRFLOW__CORE__FERNET_KEY etc., which compose never reads
    # directly) -- so without these, every fresh full-tier install fails at
    # "AIRFLOW_FERNET_KEY must be set" / "VAULT_DEV_TOKEN must be set" even after
    # .env is generated. Appended below under the names compose actually looks up.
    $vaultDevToken = New-SecureHex 24

    $content = Get-Content ".env.example" -Raw

    # Replace placeholder values with generated secrets
    $content = $content -replace "payshield_secret",           $pgPass
    $content = $content -replace "payshield_minio_secret",     $minioPass
    $content = $content -replace "REPLACE_WITH_OPENSSL_RAND_BASE64_32", $minioKmsKey
    $content = $content -replace "payshield_neo4j",            $neo4jPass
    $content = $content -replace "change-me-in-production-32-chars!!", $apiKey
    $content = $content -replace "change-me-jwt-secret-32-chars!!!",   $jwtSecret
    # BUG FIX (2026-07): this pattern never matched anything -- .env.example's
    # actual placeholder is `BACKEND_API_KEY=ABCDEFGHI`, not the literal string
    # "change-me-admin-api-key", so $adminKey was generated above and silently
    # discarded on every install. Every fresh deployment kept the well-known,
    # publicly-documented demo key (see app/docs/openapi_config.py) sitting in
    # its real .env.example-derived .env. Matched by key name instead (robust
    # to the placeholder value ever changing).
    $content = $content -replace "(?m)^BACKEND_API_KEY=.*", "BACKEND_API_KEY=$adminKey"
    $content = $content -replace "<base64-encoded-32-byte-key>",       $signingKey
    $content = $content -replace "change-me-fernet-key-base64-encoded=", $fernetKey
    $content = $content -replace "change-me-webserver-secret",          $airflowWS
    $content = $content -replace "payshield_grafana",                   $grafanaPass
    $content = $content -replace "payshield_airflow_admin",             $airflowAdminPass
    $content = $content -replace "(?m)^EDGE_CONTEXT_HMAC_KEY=$", "EDGE_CONTEXT_HMAC_KEY=$edgeContextHmacKey"
    $content = $content -replace "change_me_on_first_login_min8chars", $dashboardAdminPass

    # Update connection URLs that embed the password
    $content = $content -replace "payshield:payshield_secret@postgres", "payshield:${pgPass}@postgres"
    $content = $content -replace "redis://redis:6379",                  "redis://redis:6379"

    # EDGE_INTERNAL_SECRET has no placeholder in .env.example at all -- appended.
    $content += "`nEDGE_INTERNAL_SECRET=$edgeInternalSecret`n"
    # REDIS_PASSWORD has no placeholder in .env.example either. This full-tier
    # compose file defaults it to empty (`${REDIS_PASSWORD:-}`, unauthenticated
    # redis) rather than requiring it, but redis is still started with
    # `--requirepass "$REDIS_PASSWORD"` -- setting a real value here is safer
    # than leaving redis open with no password.
    $content += "REDIS_PASSWORD=$redisPass`n"
    # Compose looks these four up under different names than .env.example uses
    # -- see the comment above where $airflowAdminPass/$vaultDevToken are
    # generated. Appended under the names docker-compose.full.windows.yml's
    # ":?must be set" interpolations actually reference.
    $content += "AIRFLOW_FERNET_KEY=$fernetKey`n"
    $content += "AIRFLOW_SECRET_KEY=$airflowWS`n"
    $content += "AIRFLOW_ADMIN_PASSWORD=$airflowAdminPass`n"
    $content += "VAULT_DEV_TOKEN=$vaultDevToken`n"

    $content | Set-Content ".env" -Encoding UTF8 -NoNewline

    Write-OK ".env written with fresh secrets"
    Write-Host ""
    Write-Host "  IMPORTANT — save these generated values somewhere safe:" -ForegroundColor Yellow
    Write-Host "    Postgres password : $pgPass"       -ForegroundColor White
    Write-Host "    MinIO password    : $minioPass"    -ForegroundColor White
    Write-Host "    MinIO KMS key     : $minioKmsKey"  -ForegroundColor White
    Write-Host "    Grafana password  : $grafanaPass"  -ForegroundColor White
    Write-Host "    Admin API key     : $adminKey"     -ForegroundColor White
    Write-Host "    Edge internal key : $edgeInternalSecret" -ForegroundColor White
    Write-Host "    Edge HMAC key     : $edgeContextHmacKey" -ForegroundColor White
    Write-Host "    Redis password    : $redisPass" -ForegroundColor White
    Write-Host "    Dashboard admin   : super_admin / $dashboardAdminPass" -ForegroundColor White
    Write-Host "    Vault dev token   : $vaultDevToken" -ForegroundColor White
    Write-Host ""
}

# =============================================================================
# SHELL SCRIPT LINE-ENDING FIX (CRLF → LF)
# =============================================================================

function Fix-LineEndings {
    Write-Step "Normalising shell script line endings (CRLF -> LF)..."
    $scripts = @(
        "entrypoint.sh",
        "infra/postgres/init-multiple-dbs.sh",
        "infra/vault/vault-init.sh"
    )
    foreach ($s in $scripts) {
        if (Test-Path $s) {
            $raw = [System.IO.File]::ReadAllText($s) -replace "`r`n", "`n" -replace "`r", "`n"
            [System.IO.File]::WriteAllText($s, $raw, [System.Text.UTF8Encoding]::new($false))
            Write-OK "Fixed: $s"
        }
    }
}

# =============================================================================
# DOCKER COMPOSE ACTIONS
# =============================================================================

function Invoke-Up {
    Write-Banner "Starting PayShield 13-Layer Stack"

    Fix-LineEndings

    Write-Step "Pulling latest base images..."
    docker compose pull --ignore-pull-failures 2>&1 | Where-Object { $_ -match "(Pulling|Pull complete|up to date|error)" } | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }

    Write-Step "Building and starting all containers..."
    docker compose up --build -d

    if ($LASTEXITCODE -ne 0) {
        Write-Err "docker compose up failed — check logs: docker compose logs"
        exit 1
    }

    Write-Step "Waiting for infrastructure health checks (up to 3 minutes)..."
    $services   = @("payshield-postgres","payshield-redis","payshield-redpanda","payshield-neo4j","payshield-minio","payshield-vault")
    $deadline   = (Get-Date).AddSeconds(180)
    $allHealthy = $false

    while ((Get-Date) -lt $deadline) {
        $allHealthy = $true
        foreach ($svc in $services) {
            $state = docker inspect --format "{{.State.Health.Status}}" $svc 2>$null
            if ($state -ne "healthy") { $allHealthy = $false }
        }
        if ($allHealthy) { break }
        Start-Sleep 5
        Write-Host "   ... still waiting" -ForegroundColor DarkGray
    }

    if ($allHealthy) { Write-OK "All infrastructure services healthy" }
    else             { Write-Warn "Some services may still be initialising — check with: docker compose ps" }

    Write-Step "Waiting for backend API to come up (up to 2 minutes)..."
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest "http://localhost:8000/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { Write-OK "Backend API is ready"; break }
        } catch {}
        Start-Sleep 5
        Write-Host "   ... waiting for backend" -ForegroundColor DarkGray
    }

    Write-Banner "PayShield is READY"
    Write-Host "  Service                  URL" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Backend API (Swagger)    http://localhost:8000/docs" -ForegroundColor Cyan
    Write-Host "  Backend Health           http://localhost:8000/health" -ForegroundColor Cyan
    Write-Host "  Go Ingest Service        http://localhost:8080" -ForegroundColor Cyan
    Write-Host "  Airflow Orchestrator     http://localhost:8083  (admin / see .env)" -ForegroundColor Cyan
    Write-Host "  Grafana Dashboards       http://localhost:3000  (admin / see .env)" -ForegroundColor Cyan
    Write-Host "  MinIO Console            http://localhost:9001  (payshield / see .env)" -ForegroundColor Cyan
    Write-Host "  Neo4j Browser            http://localhost:7474  (neo4j / see .env)" -ForegroundColor Cyan
    Write-Host "  Prometheus               http://localhost:9090" -ForegroundColor Cyan
    Write-Host "  Vault UI                 http://localhost:8200  (token: root)" -ForegroundColor Cyan
    Write-Host "  Redpanda Console         http://localhost:8081" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Management commands:" -ForegroundColor DarkGray
    Write-Host "    .\install\install-windows.ps1 -Action logs     (tail logs)" -ForegroundColor DarkGray
    Write-Host "    .\install\install-windows.ps1 -Action status   (container status)" -ForegroundColor DarkGray
    Write-Host "    .\install\install-windows.ps1 -Action down     (stop, keep data)" -ForegroundColor DarkGray
    Write-Host "    .\install\install-windows.ps1 -Action destroy  (stop + wipe data)" -ForegroundColor DarkGray
    Write-Host ""
}

function Invoke-Down {
    Write-Banner "Stopping PayShield (data preserved)"
    docker compose down
    Write-OK "Containers stopped. Run -Action up to restart."
}

function Invoke-Restart {
    Write-Banner "Restarting PayShield"
    docker compose restart
    Write-OK "All containers restarted."
}

function Invoke-Destroy {
    Write-Host ""
    Write-Host "  WARNING: This will DELETE ALL DATA (databases, Kafka, Neo4j, MinIO, models)." -ForegroundColor Red
    $confirm = Read-Host "  Type 'yes' to confirm"
    if ($confirm -ne "yes") { Write-Host "  Aborted." -ForegroundColor DarkGray; exit 0 }
    Write-Banner "Destroying PayShield stack + volumes"
    docker compose down -v --remove-orphans
    Write-OK "Destroyed. Run -Action up for a clean start."
}

function Invoke-Logs {
    Write-Banner "PayShield Logs (Ctrl+C to stop)"
    docker compose logs -f
}

function Invoke-Migrate {
    Write-Banner "Running Alembic Migrations"
    docker compose exec backend alembic upgrade head
    Write-OK "Migrations complete."
}

function Invoke-Status {
    Write-Banner "PayShield Container Status"
    docker compose ps
}

function Invoke-Shell {
    Write-Banner "Opening Backend Shell"
    docker compose exec backend bash
}

function Invoke-Health {
    Write-Banner "PayShield Health Check"
    $services = @(
        @{name="Backend API";  url="http://localhost:8000/health"},
        @{name="Prometheus";   url="http://localhost:9090/-/healthy"},
        @{name="Grafana";      url="http://localhost:3000/api/health"},
        @{name="MinIO";        url="http://localhost:9000/minio/health/live"}
    )
    foreach ($s in $services) {
        try {
            $r = Invoke-WebRequest $s.url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            Write-OK "$($s.name) — HTTP $($r.StatusCode)"
        } catch {
            Write-Warn "$($s.name) — NOT reachable ($($s.url))"
        }
    }
    Write-Host ""
    docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
}

function Invoke-Update {
    Write-Banner "Updating PayShield (pull + rebuild)"
    docker compose pull --ignore-pull-failures
    docker compose up --build -d
    Write-OK "Update complete."
}

# =============================================================================
# MAIN
# =============================================================================

Write-Banner "PayShield — One-Step Windows Installer"

if (-not $SkipPrereqs -and $Action -in @("up","deploy")) {
    if (-not (Test-Administrator)) {
        Write-Warn "Not running as Administrator — prerequisite installation may be skipped."
        Write-Warn "Re-run as Administrator for automatic Docker / Git installation."
    }
    Ensure-WSL2
    Ensure-DockerDesktop
    Ensure-Git
    Wait-DockerDaemon
}

switch ($Action.ToLower()) {
    { $_ -in "up","deploy" } { Ensure-EnvFile; Invoke-Up }
    "down"                   { Invoke-Down }
    "restart"                { Invoke-Restart }
    "destroy"                { Invoke-Destroy }
    "logs"                   { Invoke-Logs }
    "migrate"                { Invoke-Migrate }
    "status"                 { Invoke-Status }
    "shell"                  { Invoke-Shell }
    "health"                 { Invoke-Health }
    "update"                 { Ensure-EnvFile; Invoke-Update }
    default {
        Write-Host ""
        Write-Host "  Usage:  .\install\install-windows.ps1 [-Action <action>]"
        Write-Host ""
        Write-Host "  Actions:"
        Write-Host "    up        Install prereqs, generate .env, start all services (default)"
        Write-Host "    down      Stop containers (keep data)"
        Write-Host "    restart   Restart all containers"
        Write-Host "    destroy   Stop + delete ALL data (irreversible)"
        Write-Host "    logs      Tail all service logs"
        Write-Host "    status    Show container status table"
        Write-Host "    health    HTTP health-check all services"
        Write-Host "    migrate   Run Alembic DB migrations"
        Write-Host "    shell     Open bash in backend container"
        Write-Host "    update    Pull latest images + rebuild"
        Write-Host ""
        Write-Host "  Flags:"
        Write-Host "    -SkipPrereqs   Skip Docker/Git/WSL checks (faster re-runs)"
        Write-Host "    -NoColor       Disable coloured output"
        Write-Host ""
    }
}
