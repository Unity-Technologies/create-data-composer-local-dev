#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup.sh — One-command local Airflow environment setup
#
# Usage:
#   ./setup.sh
#   ./setup.sh --dags-path /path/to/create-data-workflows --port 8081
#
# =============================================================================

# Hardcoded team defaults
SOURCE_ENV="create-data-composer-test"
GCP_PROJECT="unity-create-data-test"
GCP_LOCATION="us-central1"
DATABASE="postgresql"

# Configurable defaults
DEFAULT_ENV_NAME="create-data-composer-test-local"
ENV_NAME="$DEFAULT_ENV_NAME"
ENV_NAME_PROVIDED=false
DAGS_PATH=""
PORT="8081"
PORT_PROVIDED=false
PARALLELISM="4"
DAG_FILE_PROCESSOR_TIMEOUT="600"

# Cache uname once
OS="$(uname)"

# Helpers

info()  { printf "\n\033[1;34m==>\033[0m %s\n" "$1"; }
ok()    { printf "\033[1;32m  ✓\033[0m %s\n" "$1"; }
warn()  { printf "\033[1;33m  !\033[0m %s\n" "$1"; }
fail()  { printf "\033[1;31m  ✗\033[0m %s\n" "$1"; exit 1; }

# Parse arguments

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dags-path)                  DAGS_PATH="$2";                                  shift 2 ;;
        --port)                       PORT="$2"; PORT_PROVIDED=true;                   shift 2 ;;
        --env-name)                   ENV_NAME="$2"; ENV_NAME_PROVIDED=true;           shift 2 ;;
        --parallelism)                PARALLELISM="$2";                                shift 2 ;;
        --dag-file-processor-timeout) DAG_FILE_PROCESSOR_TIMEOUT="$2";                 shift 2 ;;
        -h|--help)
            echo "Usage: ./setup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dags-path PATH                 Absolute path to create-data-workflows repo (required)"
            echo "  --port PORT                      Airflow webserver port (default: 8081)"
            echo "  --env-name NAME                  Environment name (default: ${DEFAULT_ENV_NAME})"
            echo "  --parallelism N                  Airflow parallelism (default: 4)"
            echo "  --dag-file-processor-timeout N   DAG file processor timeout in seconds (default: 600)"
            echo "  -h, --help                       Show this help message"
            exit 0
            ;;
        *) fail "Unknown option: $1. Use --help for usage." ;;
    esac
done

# Phase 1: Preflight Checks

info "Checking prerequisites..."

# Docker
if ! command -v docker &> /dev/null; then
    fail "Docker is not installed. Install it from https://docs.docker.com/get-docker/"
fi
if ! docker info &> /dev/null; then
    echo ""
    warn "Docker is installed but not responding. Make sure Docker Desktop is running."
    warn "If you see a docker.sock error, try:"
    warn "  ln -s -f \$HOME/.docker/run/docker.sock /var/run/docker.sock"
    exit 1
fi
ok "Docker"

# gcloud
if ! command -v gcloud &> /dev/null; then
    fail "gcloud is not installed. Install it from https://cloud.google.com/sdk/docs/install"
fi
ok "gcloud"

# Python
if ! command -v python3 &> /dev/null; then
    fail "Python 3 is not installed. Install Python 3.8-3.11 (https://github.com/pyenv/pyenv)"
fi
PY_MAJOR=$(python3 -c 'import sys; print(sys.version_info.major)')
PY_MINOR=$(python3 -c 'import sys; print(sys.version_info.minor)')
if [[ "$PY_MAJOR" -ne 3 || "$PY_MINOR" -lt 8 || "$PY_MINOR" -gt 11 ]]; then
    fail "Python ${PY_MAJOR}.${PY_MINOR} detected. This tool requires Python 3.8-3.11."
fi
ok "Python ${PY_MAJOR}.${PY_MINOR}"

# Phase 2: GCP Authentication

info "Checking GCP authentication..."

if gcloud auth application-default print-access-token &> /dev/null; then
    ok "Application Default Credentials found"
else
    warn "No valid GCP credentials found. You need to authenticate."
    warn "This will open TWO browser windows in sequence:"
    warn "  1. Application Default Credentials (used by client libraries)"
    warn "  2. User credentials (used by the gcloud CLI)"
    read -rp "    Continue? [Y/n] " confirm
    if [[ "${confirm:-Y}" =~ ^[Yy]$ ]]; then
        gcloud auth application-default login
        gcloud auth login
    else
        fail "GCP authentication is required to continue."
    fi
fi

gcloud config set project "$GCP_PROJECT" --quiet
ok "GCP project set to $GCP_PROJECT"

# Phase 3: Python Environment

info "Setting up Python environment..."

if [ ! -d ".venv" ]; then
    python3 -m venv .venv
    ok "Created virtual environment (.venv)"
else
    ok "Virtual environment already exists (.venv)"
fi

# shellcheck disable=SC1091
source .venv/bin/activate

pip install --quiet . > /dev/null
ok "Installed package"

if ! command -v composer-dev &> /dev/null; then
    fail "composer-dev installation failed. Check the output above for errors."
fi
ok "composer-dev is on PATH"

# Phase 4: Collect Configuration

info "Configuring environment..."

# DAGs path (required)
if [ -z "$DAGS_PATH" ]; then
    read -rp "    Absolute path to create-data-workflows repo: " DAGS_PATH
fi

# Expand ~ if present
DAGS_PATH="${DAGS_PATH/#\~/$HOME}"

if [ ! -d "$DAGS_PATH" ]; then
    fail "Directory does not exist: $DAGS_PATH"
fi
if [ ! -d "$DAGS_PATH/data_analytics_workflows/create/dags" ]; then
    fail "Directory $DAGS_PATH does not contain data_analytics_workflows/create/dags/. Point to the repo root."
fi
ok "DAGs path: $DAGS_PATH"

# Environment name
if [ "$ENV_NAME_PROVIDED" = "false" ]; then
    read -rp "    Environment name [${ENV_NAME}]: " input
    ENV_NAME="${input:-$ENV_NAME}"
fi
ok "Environment name: $ENV_NAME"

# Port
if [ "$PORT_PROVIDED" = "false" ]; then
    read -rp "    Airflow webserver port [${PORT}]: " input
    PORT="${input:-$PORT}"
fi
ok "Port: $PORT"

# Verify the port is free before doing any heavy work. Skip if env exists
# already (we may be reusing it, so its own listener may legitimately occupy
# the port — handled in Phase 5).
if [ ! -d "./composer/$ENV_NAME" ]; then
    if command -v lsof &> /dev/null && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN &> /dev/null; then
        OFFENDER=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" (PID "$2")"}')
        fail "Port $PORT is already in use by ${OFFENDER:-another process}. Pick a different port with --port, or free it up. (Tip: 'sudo lsof -nP -iTCP:$PORT -sTCP:LISTEN' shows listeners owned by other users.)"
    fi
fi

# Phase 5: Create Environment

info "Creating Composer environment..."

ENV_DIR="./composer/$ENV_NAME"
SKIP_CREATE=false

if [ -d "$ENV_DIR" ]; then
    warn "Environment '$ENV_NAME' already exists at $ENV_DIR."
    echo "    [r] Recreate (remove existing and create fresh)"
    echo "    [s] Skip create (reuse existing environment)"
    echo "    [a] Abort"
    read -rp "    Choose [r/s/a]: " choice
    case "${choice:-a}" in
        r|R)
            info "Removing existing environment..."
            composer-dev remove "$ENV_NAME" --skip-confirmation --force || \
                fail "Failed to remove existing environment. Remove it manually and re-run."
            ok "Existing environment removed"
            ;;
        s|S)
            SKIP_CREATE=true
            ok "Reusing existing environment"
            ;;
        *)
            fail "Aborted by user."
            ;;
    esac
fi

if [ "$SKIP_CREATE" = "false" ]; then
    # Clean up partial env dir if create fails (but only during create — not later)
    cleanup_partial_env() {
        if [ -d "$ENV_DIR" ]; then
            warn "Cleaning up partial environment at $ENV_DIR"
            rm -rf "$ENV_DIR"
        fi
    }
    trap cleanup_partial_env ERR

    composer-dev create "$ENV_NAME" \
        --from-source-environment "$SOURCE_ENV" \
        --location "$GCP_LOCATION" \
        --project "$GCP_PROJECT" \
        --port "$PORT" \
        --database "$DATABASE" \
        --dags-path "$DAGS_PATH"

    trap - ERR
    ok "Environment created"
fi

# Phase 6: Write variables.env

info "Writing variables.env..."

VARIABLES_ENV="$ENV_DIR/variables.env"
WRITE_VARIABLES=true

if [ "$SKIP_CREATE" = "true" ] && [ -f "$VARIABLES_ENV" ]; then
    warn "variables.env already exists at $VARIABLES_ENV."
    warn "Overwriting will lose any local customisations (e.g. NAVBAR_COLOR, INSTANCE_NAME)."
    read -rp "    Overwrite? [y/N] " confirm
    if [[ ! "${confirm:-N}" =~ ^[Yy]$ ]]; then
        WRITE_VARIABLES=false
        ok "Keeping existing variables.env"
    fi
fi

if [ "$WRITE_VARIABLES" = "true" ]; then
    cat > "$VARIABLES_ENV" << EOF
AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION=true
AIRFLOW__CORE__EXECUTOR=LocalExecutor
AIRFLOW__CORE__DAG_IGNORE_FILE_SYNTAX=glob
AIRFLOW__CORE__DAG_FILE_PROCESSOR_TIMEOUT=${DAG_FILE_PROCESSOR_TIMEOUT}
AIRFLOW__CORE__PARALLELISM=${PARALLELISM}
AIRFLOW__SCHEDULER__CATCHUP_BY_DEFAULT=false
AIRFLOW__SECRETS__BACKEND=airflow.providers.google.cloud.secrets.secret_manager.CloudSecretManagerBackend
AIRFLOW__WEBSERVER__DAG_DEFAULT_VIEW=graph
AIRFLOW__WEBSERVER__INSTANCE_NAME=Local development
AIRFLOW__WEBSERVER__INSTANCE_NAME_HAS_MARKUP=true
AIRFLOW__WEBSERVER__NAVBAR_COLOR=#748ffc
AIRFLOW__WEBSERVER__WEB_SERVER_MASTER_TIMEOUT=300
AIRFLOW__WEBSERVER__WEB_SERVER_WORKER_TIMEOUT=300
AIRFLOW__CORE__DAGBAG_IMPORT_TIMEOUT=300
AIRFLOW__WEBSERVER__WORKER_REFRESH_INTERVAL=3600
AIRFLOW__WEBSERVER__WORKERS=2
AIRFLOW__WEBSERVER__WORKER_CLASS=sync
AIRFLOW__WEBSERVER__SHOW_TRIGGER_FORM_IF_NO_PARAMS=true
GOOGLE_CLOUD_PROJECT=${GCP_PROJECT}
EOF

    # On Linux (incl. WSL2), Docker bind-mounts use real UIDs with no translation,
    # so files the container writes (pgdata, logs, etc.) end up owned by in-container
    # UIDs that the host user can't manage (cleanup needs sudo). Enabling this makes
    # the container run as the host user, sidestepping the issue. macOS Docker Desktop
    # already does UID translation on bind mounts, so we skip it there.
    if [[ "$OS" == "Linux" ]]; then
        echo "COMPOSER_CONTAINER_RUN_AS_HOST_USER=True" >> "$VARIABLES_ENV"
    fi

    ok "variables.env written"
fi

# Phase 7: Generate .airflowignore

info "Generating .airflowignore..."

AIRFLOW_IGNORE="$DAGS_PATH/.airflowignore"

if [ -f "$AIRFLOW_IGNORE" ]; then
    ok ".airflowignore already exists, skipping (delete it to regenerate)"
else
    cat > "$AIRFLOW_IGNORE" << 'IGNORE_EOF'
# Generated by setup.sh — re-runs of setup.sh will NOT overwrite this file.
# Delete it and re-run setup.sh if you want to regenerate from the template.
#
# Ignore everything by default
*

# Re-include parent folders so leaf-level !patterns below can take effect
!data_analytics_workflows/
!data_analytics_workflows/create/
!data_analytics_workflows/create/dags/

# Exclude all files and sub-folders inside dags/ (re-include selectively below)
data_analytics_workflows/create/dags/*
data_analytics_workflows/create/dags/*/

# Add the DAGs you want to allow:
# !data_analytics_workflows/create/dags/my_dag.py
IGNORE_EOF

    ok ".airflowignore written to $AIRFLOW_IGNORE"
fi

# Phase 8: Summary (printed BEFORE start, since start blocks)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "\033[1;32m  Setup complete!\033[0m\n"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Environment:   $ENV_NAME"
echo "  DAGs path:     $DAGS_PATH"
echo "  Port:          $PORT"
echo "  Parallelism:   $PARALLELISM"
echo "  DAG timeout:   ${DAG_FILE_PROCESSOR_TIMEOUT}s"
echo ""
echo "  Once started, Airflow will be available at http://localhost:$PORT"
echo ""
echo "  To add DAGs, edit:"
echo "     $AIRFLOW_IGNORE"
echo ""
echo "     Add a line like this for each DAG you want to load:"
echo "       !data_analytics_workflows/create/dags/my_dag.py"
echo ""
echo "  Starting environment now (Ctrl+C to stop)..."
echo ""

# Phase 9: Start Environment (foreground, streams logs until Ctrl+C)

exec composer-dev start "$ENV_NAME"
