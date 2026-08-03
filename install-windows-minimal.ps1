# =============================================================================
# PayShield -- One-Step Windows Installer (MINIMAL tier)
# Installs ALL prerequisites, configures environment, and starts the minimal
# stack: nginx + backend + ingestion + processor + postgres + redis +
# redpanda + neo4j + minio + mqtt. Omits Ollama, Vault, Airflow, Prometheus,
# and Grafana -- see docker-compose.minimal.windows.yml's own header comment
# for exactly why each is confirmed safe to skip (advisory-only / no
# depends_on anywhere in the stack / documented nginx-upstream incident for
# Grafana specifically).
#
# This is install-windows.ps1 (the proven, working FULL-tier installer) used
# as the base, with every `docker compose` call pointed at
# docker-compose.minimal.windows.yml instead of the default docker-compose.yml,
# and the health-check/printed-URL lists trimmed to services that actually
# exist in this tier. Use install-windows.ps1 unchanged for the full stack.
#
# Run from PowerShell (Administrator) in the project root:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\install\install-windows-minimal.ps1
#
# What this script does:
#   1. Checks Windows version and enables WSL2 if missing
#   2. Installs Docker Desktop via winget (if not present)
#   3. Installs Git for Windows (if not present)
#   4. Fixes shell-script line endings (CRLF -> LF)
#   5. Generates a .env with cryptographically-secure secrets
#   6. Pulls all Docker images and starts the minimal-tier stack
#   7. Waits for infrastructure health checks to pass
#   8. Prints all service URLs
#
# Prerequisites this cannot skip (same as the full stack -- see
# docker-compose.minimal.windows.yml's header for details):
#   SSL_DIR, GEOIP_DIR must be set in .env / your environment before "up".
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

# -- Colour helpers ------------------------------------------------------------
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

# -- Locate project root (script lives in install\) ---------------------------
$SCRIPT_DIR   = Split-Path -Parent $MyInvocation.MyCommand.Path
$PROJECT_ROOT = Split-Path -Parent $SCRIPT_DIR          # .../Code
$BACKEND_DIR  = Join-Path $PROJECT_ROOT "payshield-backend"
$NGINX_DIR    = Join-Path $PROJECT_ROOT "nginx"
$ComposeFile  = Join-Path $SCRIPT_DIR "docker-compose.minimal.windows.yml"

if (-not (Test-Path $ComposeFile)) {
    Write-Err "Cannot find install\docker-compose.minimal.windows.yml"
    exit 1
}
if (-not (Test-Path (Join-Path $BACKEND_DIR ".env.example"))) {
    Write-Err "Cannot find payshield-backend\.env.example"
    Write-Err "Expected layout: <root>\payshield-backend\   and  <root>\install\"
    exit 1
}

# Compose runs with cwd = BACKEND_DIR (where .env lives and every relative
# path in the compose file resolves via ../payshield-backend/... from
# install/) but points at the compose file over in install/ via -f.
Set-Location $BACKEND_DIR

function Invoke-Compose {
    param([Parameter(ValueFromRemainingArguments = $true)] $ComposeArgs)
    docker compose -f $ComposeFile --env-file .env @ComposeArgs
}

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
    Write-Warn "WSL2 not enabled -- enabling now (may require reboot)"
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart | Out-Null
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart | Out-Null
    wsl --set-default-version 2 2>&1 | Out-Null
    Write-OK "WSL2 enabled"
}

function Ensure-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return }
    Write-Warn "winget not found -- downloading App Installer..."
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
    Write-Warn "Docker Desktop not found -- installing via winget..."
    Ensure-Winget
    winget install --id Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Err "winget install failed. Download manually: https://docs.docker.com/desktop/windows/"
        exit 1
    }
    Write-OK "Docker Desktop installed -- please start Docker Desktop and re-run this script"
    Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe" -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "  Docker Desktop is starting. Wait until the whale icon appears in the system tray," -ForegroundColor Yellow
    Write-Host "  then re-run:  .\install\install-windows-minimal.ps1" -ForegroundColor Yellow
    exit 0
}

function Ensure-Git {
    Write-Step "Checking Git..."
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $v = git --version 2>&1
        Write-OK "Git found: $v"
        return
    }
    Write-Warn "Git not found -- installing via winget..."
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
        Write-OK ".env already exists -- skipping generation"
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
    $neo4jPass  = New-SecureHex 20
    $fernetKey  = New-FernetKey
    $airflowWS  = New-SecureHex 24
    $grafanaPass= New-SecureHex 16
    # This minimal-tier compose file requires these two (":?must be set") where
    # the full stack only defaults them -- .env.example has no placeholder for
    # either, so they're generated here and appended below rather than
    # replaced in-place.
    $csrfSecret       = New-SecureHex 32
    $edgeInternalSecret = New-SecureHex 32

    $content = Get-Content ".env.example" -Raw

    # Replace placeholder values with generated secrets
    $content = $content -replace "payshield_secret",           $pgPass
    $content = $content -replace "payshield_minio_secret",     $minioPass
    $content = $content -replace "payshield_neo4j",            $neo4jPass
    $content = $content -replace "change-me-in-production-32-chars!!", $apiKey
    $content = $content -replace "(?m)^CSRF_SECRET=$", "CSRF_SECRET=$csrfSecret"
    $content = $content -replace "change-me-jwt-secret-32-chars!!!",   $jwtSecret
    # BUG FIX (2026-07): this pattern never matched anything -- .env.example's
    # actual placeholder is `BACKEND_API_KEY=ABCDEFGHI`, not the literal string
    # "change-me-admin-api-key", so $adminKey was generated above and silently
    # discarded on every install. Matched by key name instead (robust to the
    # placeholder value ever changing), mirroring the CSRF_SECRET pattern above.
    $content = $content -replace "(?m)^BACKEND_API_KEY=.*", "BACKEND_API_KEY=$adminKey"
    $content = $content -replace "<base64-encoded-32-byte-key>",       $signingKey
    $content = $content -replace "change-me-fernet-key-base64-encoded=", $fernetKey
    $content = $content -replace "change-me-webserver-secret",          $airflowWS
    $content = $content -replace "payshield_grafana",                   $grafanaPass
    $content = $content -replace "payshield_airflow_admin",             (New-SecureHex 12)

    # Update connection URLs that embed the password
    $content = $content -replace "payshield:payshield_secret@postgres", "payshield:${pgPass}@postgres"
    $content = $content -replace "redis://redis:6379",                  "redis://redis:6379"

    # EDGE_INTERNAL_SECRET and the JWT RSA key pair have no placeholder in
    # .env.example at all (only the full stack's JWT_PRIVATE_KEY_PEM/
    # JWT_PUBLIC_KEY_PEM default to "" there, letting the app generate an
    # ephemeral session-only pair -- this minimal file requires real,
    # persistent ones via ":?must be set"). Appended here instead of replaced.
    $jwtKeysOk = $false
    if (Get-Command openssl -ErrorAction SilentlyContinue) {
        $privPath = Join-Path $env:TEMP "payshield_jwt_private_$([guid]::NewGuid()).pem"
        $pubPath  = Join-Path $env:TEMP "payshield_jwt_public_$([guid]::NewGuid()).pem"
        try {
            openssl genrsa -out $privPath 2048 2>$null
            openssl rsa -in $privPath -pubout -out $pubPath 2>$null
            if ((Test-Path $privPath) -and (Test-Path $pubPath)) {
                # Single-line env-var form: literal newlines escaped to \n.
                $jwtPrivate = ((Get-Content $privPath -Raw) -replace "`r`n", "`n").TrimEnd("`n") -replace "`n", '\n'
                $jwtPublic  = ((Get-Content $pubPath  -Raw) -replace "`r`n", "`n").TrimEnd("`n") -replace "`n", '\n'
                $content += "`nJWT_PRIVATE_KEY_PEM=`"$jwtPrivate`"`nJWT_PUBLIC_KEY_PEM=`"$jwtPublic`"`n"
                $jwtKeysOk = $true
            }
        } finally {
            Remove-Item $privPath, $pubPath -ErrorAction SilentlyContinue
        }
    }
    $content += "EDGE_INTERNAL_SECRET=$edgeInternalSecret`n"

    $content | Set-Content ".env" -Encoding UTF8 -NoNewline

    Write-OK ".env written with fresh secrets"
    Write-Host ""
    Write-Host "  IMPORTANT -- save these generated values somewhere safe:" -ForegroundColor Yellow
    Write-Host "    Postgres password : $pgPass"       -ForegroundColor White
    Write-Host "    MinIO password    : $minioPass"    -ForegroundColor White
    Write-Host "    Admin API key     : $adminKey"     -ForegroundColor White
    Write-Host ""
    if (-not $jwtKeysOk) {
        Write-Warn "openssl not found (Git for Windows provides it) -- JWT_PRIVATE_KEY_PEM /"
        Write-Warn "JWT_PUBLIC_KEY_PEM were NOT generated. Generate manually and add to .env:"
        Write-Warn "  openssl genrsa -out jwt_private.pem 2048"
        Write-Warn "  openssl rsa -in jwt_private.pem -pubout -out jwt_public.pem"
    }
    Write-Warn "SSL_DIR and GEOIP_DIR are NOT auto-generated -- set them in .env"
    Write-Warn "yourself before 'up'. See docker-compose.minimal.windows.yml's"
    Write-Warn "header comment for how to generate a self-signed cert and where"
    Write-Warn "to get a free MaxMind GeoLite2 license."
    Write-Host ""
}

# =============================================================================
# SHELL SCRIPT LINE-ENDING FIX (CRLF -> LF)
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
    Write-Banner "Starting PayShield Minimal Stack"

    Fix-LineEndings

    Write-Step "Pulling latest base images..."
    Invoke-Compose pull --ignore-pull-failures 2>&1 | Where-Object { $_ -match "(Pulling|Pull complete|up to date|error)" } | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }

    Write-Step "Building and starting all containers..."
    Invoke-Compose up --build -d

    if ($LASTEXITCODE -ne 0) {
        Write-Err "docker compose up failed -- check logs: .\install\install-windows-minimal.ps1 -Action logs"
        exit 1
    }

    Write-Step "Waiting for infrastructure health checks (up to 3 minutes)..."
    # Just postgres + redis -- this is the 4-service tier (nginx, backend,
    # postgres, redis). No redpanda/neo4j/minio/vault/ollama here at all.
    $services   = @("payshield-postgres","payshield-redis")
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
    else             { Write-Warn "Some services may still be initialising -- check with: .\install\install-windows-minimal.ps1 -Action status" }

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

    Write-Banner "PayShield (minimal tier) is READY"
    Write-Host "  Service                  URL" -ForegroundColor White
    Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  Backend API (Swagger)    https://localhost/docs" -ForegroundColor Cyan
    Write-Host "  Backend Health           https://localhost/health" -ForegroundColor Cyan
    Write-Host "  SOC Dashboard            https://localhost/dashboard" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Not part of this tier -- nginx, backend, postgres, redis only" -ForegroundColor DarkGray
    Write-Host "  (use .\install\install-windows.ps1 for the full stack):" -ForegroundColor DarkGray
    Write-Host "    Neo4j, MinIO, Redpanda/Kafka, AI Fraud Advisory (Ollama)," -ForegroundColor DarkGray
    Write-Host "    Airflow, Prometheus, Grafana, Vault UI" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Management commands:" -ForegroundColor DarkGray
    Write-Host "    .\install\install-windows-minimal.ps1 -Action logs     (tail logs)" -ForegroundColor DarkGray
    Write-Host "    .\install\install-windows-minimal.ps1 -Action status   (container status)" -ForegroundColor DarkGray
    Write-Host "    .\install\install-windows-minimal.ps1 -Action down     (stop, keep data)" -ForegroundColor DarkGray
    Write-Host "    .\install\install-windows-minimal.ps1 -Action destroy  (stop + wipe data)" -ForegroundColor DarkGray
    Write-Host ""
}

function Invoke-Down {
    Write-Banner "Stopping PayShield (data preserved)"
    Invoke-Compose down
    Write-OK "Containers stopped. Run -Action up to restart."
}

function Invoke-Restart {
    Write-Banner "Restarting PayShield"
    Invoke-Compose restart
    Write-OK "All containers restarted."
}

function Invoke-Destroy {
    Write-Host ""
    Write-Host "  WARNING: This will DELETE ALL DATA (databases, Kafka, Neo4j, MinIO, models)." -ForegroundColor Red
    $confirm = Read-Host "  Type 'yes' to confirm"
    if ($confirm -ne "yes") { Write-Host "  Aborted." -ForegroundColor DarkGray; exit 0 }
    Write-Banner "Destroying PayShield stack + volumes"
    Invoke-Compose down -v --remove-orphans
    Write-OK "Destroyed. Run -Action up for a clean start."
}

function Invoke-Logs {
    Write-Banner "PayShield Logs (Ctrl+C to stop)"
    Invoke-Compose logs -f
}

function Invoke-Migrate {
    Write-Banner "Running Alembic Migrations"
    Invoke-Compose exec backend alembic upgrade head
    Write-OK "Migrations complete."
}

function Invoke-Status {
    Write-Banner "PayShield Container Status"
    Invoke-Compose ps
}

function Invoke-Shell {
    Write-Banner "Opening Backend Shell"
    Invoke-Compose exec backend bash
}

function Invoke-Health {
    Write-Banner "PayShield Health Check"
    # Just the backend -- postgres/redis have no HTTP health endpoint of their
    # own, and MinIO/Neo4j/etc. aren't part of this tier.
    $services = @(
        @{name="Backend API";  url="http://localhost:8000/health"}
    )
    foreach ($s in $services) {
        try {
            $r = Invoke-WebRequest $s.url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            Write-OK "$($s.name) -- HTTP $($r.StatusCode)"
        } catch {
            Write-Warn "$($s.name) -- NOT reachable ($($s.url))"
        }
    }
    Write-Host ""
    Invoke-Compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
}

function Invoke-Update {
    Write-Banner "Updating PayShield (pull + rebuild)"
    Invoke-Compose pull --ignore-pull-failures
    Invoke-Compose up --build -d
    Write-OK "Update complete."
}

# =============================================================================
# MAIN
# =============================================================================

Write-Banner "PayShield -- One-Step Windows Installer (MINIMAL tier)"

if (-not $SkipPrereqs -and $Action -in @("up","deploy")) {
    if (-not (Test-Administrator)) {
        Write-Warn "Not running as Administrator -- prerequisite installation may be skipped."
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
        Write-Host "  Usage:  .\install\install-windows-minimal.ps1 [-Action <action>]"
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
        Write-Host "  For the FULL stack (adds Ollama/Vault/Airflow/Prometheus/Grafana):"
        Write-Host "    .\install\install-windows.ps1"
        Write-Host ""
    }
}
