# PayShield — Step-by-Step Setup (New Machine)

This is the exact command sequence to run when installing on a **new machine**
for the first time, or re-running on a machine where a previous attempt left
a broken/incomplete `.env` behind. See [README.md](README.md) for the tier
overview and platform matrix — this file is just the operational checklist.

## Why these specific steps

- **Path verification (step 2)** exists because every install script
  self-locates relative to its own file — `install\` and the backend folder
  must be direct siblings. The backend GitHub repo is named
  `nonashield-backend` (a plain `git clone` produces that folder name), but
  the code inside it still says `payshield-backend` everywhere from before
  the org's rebrand (env vars, docker service/container names,
  `.env.example`) — a leftover from before NonaShield was the org name. All
  four install scripts detect **either** `payshield-backend\` or
  `nonashield-backend\` automatically, and set up a compatibility
  junction/symlink so the ~8-20 paths hardcoded inside each
  `docker-compose.*.yml` keep resolving either way. If neither folder is
  found next to `install\`, the script fails fast here with a clear error
  instead of a confusing Docker Compose one.
- **Removing a stale `.env` (step 3)** exists because every install script
  skips secret generation entirely if `.env` already exists
  (`.env already exists — skipping generation`). A `.env` copied over from
  another machine, left over from a previous failed attempt, or copied from
  a different tier will silently keep the script from ever generating the
  secrets this tier actually needs — producing errors like
  `required variable EDGE_CONTEXT_HMAC_KEY is missing a value` deep inside
  `docker compose up`, long after the script reported success on the `.env`
  step.

## Windows (PowerShell, as Administrator)

```powershell
# 1. Point at wherever the project was copied on THIS machine
#    (only this line changes per machine)
$ProjectRoot = "D:\nonashield"
Set-Location $ProjectRoot

# 2. Verify the folder layout is intact before doing anything else --
#    the first line must print True. The second checks whichever backend
#    folder name is actually present (a fresh `git clone` of
#    nonashield-backend produces that name; older checkouts may have it
#    renamed to payshield-backend -- both work, see SETUP.md above).
Test-Path "$ProjectRoot\install\install-windows-minimal.ps1"
Test-Path "$ProjectRoot\payshield-backend\.env.example"; Test-Path "$ProjectRoot\nonashield-backend\.env.example"

# 3. Remove any stale/incompatible .env so generation actually runs
#    (a leftover .env from a copy/previous failed attempt is skipped
#    silently otherwise, and that's what causes the error above).
#    Only one of these two paths will actually exist -- that's fine.
Remove-Item "$ProjectRoot\payshield-backend\.env" -ErrorAction SilentlyContinue
Remove-Item "$ProjectRoot\nonashield-backend\.env" -ErrorAction SilentlyContinue

# 4. Allow the script to run for this session only
Set-ExecutionPolicy Bypass -Scope Process -Force

# 5. Run it
.\install\install-windows-minimal.ps1      # minimal tier
# .\install\install-windows.ps1            # full tier
```

## Linux / Ubuntu

```bash
# 1. Point at wherever the project was copied on THIS machine
PROJECT_ROOT=/home/user/nonashield
cd "$PROJECT_ROOT"

# 2. Verify folder layout -- either backend folder name is accepted
test -f "$PROJECT_ROOT/install/install-linux.sh" && echo "install script: OK"
test -f "$PROJECT_ROOT/payshield-backend/.env.example" -o -f "$PROJECT_ROOT/nonashield-backend/.env.example" && echo "backend dir: OK"

# 3. Remove stale .env (path depends on where the tier's deploy target is --
#    default INSTALL_DIR is /opt/payshield unless overridden, see step 4;
#    only one of these two paths will actually exist)
sudo rm -f /opt/payshield/payshield-backend/.env /opt/payshield/nonashield-backend/.env

# 4. Run
sudo PAYSHIELD_TIER=minimal bash install/install-linux.sh    # minimal tier
# sudo bash install/install-linux.sh                         # full tier (default)
```

Swap `install-linux.sh` → `install-ubuntu.sh` for Ubuntu; same flags apply.
Add `INSTALL_DIR=/your/path` before `PAYSHIELD_TIER=...` on either script if
you don't want the default `/opt/payshield` deploy target — and remove the
`.env` under that path instead in step 3.

## After a successful run

Save the secrets printed at the end of the `.env` generation step (Postgres
password, Redis password, dashboard super-admin password, etc.) somewhere
safe — they are not shown again, and `.env` is git-ignored by design.

| Action | Windows | Linux/Ubuntu |
|---|---|---|
| Check status | `.\install\install-windows-minimal.ps1 -Action status` | `sudo bash install/install-linux.sh status` |
| Tail logs | `.\install\install-windows-minimal.ps1 -Action logs` | `sudo bash install/install-linux.sh logs` |
| Health check | `.\install\install-windows-minimal.ps1 -Action health` | `sudo bash install/install-linux.sh health` |
| Stop (keep data) | `.\install\install-windows-minimal.ps1 -Action down` | `sudo bash install/install-linux.sh down` |
