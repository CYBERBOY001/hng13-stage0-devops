#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE=""
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EXIT_CODE=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    case $level in
        ERROR) echo -e "${RED}ERROR: $message${NC}" >&2 ;;
        WARN)  echo -e "${YELLOW}WARN: $message${NC}" >&2 ;;
        INFO)  echo -e "${GREEN}INFO: $message${NC}" ;;
    esac
}

error_handler() {
    local exit_code=$?
    log ERROR "Script failed at line $1 with exit code $exit_code"
    cleanup_on_error
    exit $exit_code
}

cleanup_on_error() {
    log WARN "Performing cleanup on error..."
    exit 1
}

trap 'error_handler ${LINENO}' ERR

prompt_input() {
    local var_name=$1
    local prompt_msg=$2
    local default=${3:-}
    local regex=${4:-}
    local value

    if [[ -n "$default" ]]; then
        prompt_msg="$prompt_msg (default: $default): "
    else
        prompt_msg="$prompt_msg: "
    fi

    read -r -p "$prompt_msg" value
    value=${value:-$default}

    if [[ -n "$regex" && ! "$value" =~ $regex ]]; then
        log ERROR "Invalid input for $var_name. Must match pattern: $regex"
        exit 1
    fi

    printf -v "$var_name" %s "$value"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

ssh_check() {
    local user=$1
    local host=$2
    local key=$3
    log INFO "Checking SSH connectivity to $user@$host..."
    if ping -c 1 -W 5 "$host" >/dev/null 2>&1; then
        log INFO "Ping to $host successful."
    else
        log ERROR "Ping to $host failed."
        exit 1
    fi
    if [[ -n "$key" && -f "$key" ]]; then
        ssh -i "$key" -o ConnectTimeout=10 -o BatchMode=yes "$user@$host" "echo 'SSH connection successful'" >/dev/null 2>&1
    else
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$user@$host" "echo 'SSH connection successful'" >/dev/null 2>&1
    fi
    if [[ $? -eq 0 ]]; then
        log INFO "SSH dry-run to $user@$host successful."
    else
        log ERROR "SSH connection to $user@$host failed."
        exit 1
    fi
}

ssh_exec() {
    local user=$1
    local host=$2
    local key=$3
    shift 3
    local cmd="$*"
    log INFO "Executing remotely: $cmd"
    if [[ -n "$key" && -f "$key" ]]; then
        ssh -i "$key" "$user@$host" "$cmd"
    else
        ssh "$user@$host" "$cmd"
    fi
    local ret=$?
    if [[ $ret -ne 0 ]]; then
        log ERROR "Remote command failed with exit code $ret"
        return $ret
    fi
    return 0
}

log_file="deploy_$TIMESTAMP.log"
LOG_FILE="$SCRIPT_DIR/$log_file"
log INFO "Starting deployment script. Log file: $LOG_FILE"

prompt_input GIT_REPO "Git Repository URL" "" "^https?://github\.com/.+\.git$"
prompt_input GIT_PAT "Personal Access Token (PAT)" ""
prompt_input GIT_BRANCH "Branch name" "main" "^[a-zA-Z0-9_-]+$"
prompt_input SSH_USER "SSH Username" ""
prompt_input SSH_HOST "Server IP Address" "" "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
prompt_input SSH_KEY "SSH Key Path" "" "^~/.ssh/id_rsa$"
prompt_input APP_PORT "Application Port (internal container port)" "3000" "^[0-9]{1,5}$"

export GIT_PAT

log INFO "Cloning repository: $GIT_REPO (branch: $GIT_BRANCH)"
REPO_DIR=$(basename "$GIT_REPO" .git)

if [[ -d "$REPO_DIR" ]]; then
    log INFO "Repository exists, pulling latest changes..."
    cd "$REPO_DIR" || { log ERROR "Failed to cd into $REPO_DIR"; exit 1; }
    git pull origin "$GIT_BRANCH"
else
    git clone "https://x-access-token:$GIT_PAT@github.com/$(echo $GIT_REPO | sed 's|https\?://github\.com/||')" || { log ERROR "Failed to clone repository"; exit 1; }
    cd "$REPO_DIR" || { log ERROR "Failed to cd into $REPO_DIR"; exit 1; }
fi

git checkout "$GIT_BRANCH" || { log ERROR "Failed to checkout branch $GIT_BRANCH"; exit 1; }
log INFO "Repository cloned/updated successfully."

log INFO "Verifying project structure..."
if [[ ! -f "Dockerfile" && ! -f "docker-compose.yml" ]]; then
    log ERROR "No Dockerfile or docker-compose.yml found in $PWD"
    exit 1
fi
log INFO "Docker files verified."

ssh_check "$SSH_USER" "$SSH_HOST" "$SSH_KEY"

log INFO "Transferring project files to remote server..."
rsync -avz -e "ssh -i $SSH_KEY" "$PWD/" "$SSH_USER@$SSH_HOST:/tmp/deploy_app/" || {
    log ERROR "Failed to transfer files"
    exit 1
}
REMOTE_DIR="/tmp/deploy_app"

log INFO "Preparing remote environment..."

ssh_exec "$SSH_USER" "$SSH_HOST" "$SSH_KEY" "
    sudo apt update && sudo apt upgrade -y

    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo rm get-docker.sh
    fi

    if ! command -v docker-compose >/dev/null 2>&1; then
        sudo curl -L 'https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)' -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi

    if ! command -v nginx >/dev/null 2>&1; then
        sudo apt install nginx -y
    fi

    if ! groups \$USER | grep -q docker; then
        sudo usermod -aG docker \$USER
        newgrp docker
    fi

    sudo systemctl enable docker nginx
    sudo systemctl start docker nginx

    docker --version
    docker-compose --version
    nginx -v
"

log INFO "Deploying application on remote..."

ssh_exec "$SSH_USER" "$SSH_HOST" "$SSH_KEY" "
    cd $REMOTE_DIR

    docker-compose down || true
    docker system prune -f || true

    if [[ -f docker-compose.yml ]]; then
        docker-compose up -d --build
    else
        docker build -t app .
        docker run -d -p $APP_PORT:$APP_PORT --name app app
    fi

    sleep 10
    if docker ps | grep -q app; then
        echo 'Container is running.'
        docker logs app
    else
        echo 'Container failed to start.'
        exit 1
    fi

    curl -f http://localhost:$APP_PORT || exit 1
    echo 'App accessible on port $APP_PORT.'
"

log INFO "Configuring Nginx..."

NGINX_CONF="/etc/nginx/sites-available/default"
ssh_exec "$SSH_USER" "$SSH_HOST" "$SSH_KEY" "
    cd $REMOTE_DIR

    cat > nginx_proxy.conf << EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

    sudo cp nginx_proxy.conf $NGINX_CONF
    sudo nginx -t && sudo systemctl reload nginx || exit 1

    echo 'SSL placeholder: Configure Certbot or self-signed cert as needed.'
"

log INFO "Validating deployment..."

ssh_exec "$SSH_USER" "$SSH_HOST" "$SSH_KEY" "
    systemctl is-active docker
    systemctl is-active nginx

    docker ps | grep app

    curl -f http://localhost || exit 1
    echo 'Deployment validated locally.'

    wget -qO- http://$SSH_HOST || exit 1
    echo 'Remote endpoint test successful.'
"

CLEANUP_FLAG=${1:-}
if [[ "$CLEANUP_FLAG" == "--cleanup" ]]; then
    log INFO "Cleanup mode: Removing all deployed resources..."
    ssh_exec "$SSH_USER" "$SSH_HOST" "$SSH_KEY" "
        cd $REMOTE_DIR
        docker-compose down -v
        docker system prune -a -f
        sudo rm -rf $REMOTE_DIR
        sudo rm $NGINX_CONF
        sudo nginx -s reload
    "
fi

log INFO "Deployment completed successfully. Exit code: $EXIT_CODE"
exit $EXIT_CODE