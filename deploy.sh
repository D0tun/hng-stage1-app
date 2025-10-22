#!/bin/bash
# deploy.sh - Automated deployment script for Dockerized app
# HNG Stage 1 DevOps Task
# Author: Anjorin Adedotun Opeyemi

LOG_FILE="deploy_$(date +%Y%m%d).log"
echo "Deployment started at $(date)" > "$LOG_FILE"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >> "$LOG_FILE"; exit 1; }


# --- Step 10: Idempotency and Cleanup Mode ---

# If user runs ./deploy.sh --cleanup

if [ "${1:-}" = "--cleanup" ]; then
    echo "[CLEANUP] Running in cleanup mode..."
    read -p "Enter remote SSH username: " SSH_USER
    read -p "Enter remote server IP address: " SSH_HOST
    read -p "Enter path to your SSH private key: " SSH_KEY

    SSH_CONNECT="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${SSH_USER}@${SSH_HOST}"

    echo "[CLEANUP] Connecting to ${SSH_USER}@${SSH_HOST}..."
    ${SSH_CONNECT} "sudo docker compose down --remove-orphans 2>/dev/null || true; \
        sudo docker ps -aq | xargs -r sudo docker rm -f 2>/dev/null || true; \
        sudo docker images -aq | xargs -r sudo docker rmi -f 2>/dev/null || true; \
        sudo rm -f /etc/nginx/sites-enabled/deployed_app.conf /etc/nginx/sites-available/deployed_app.conf || true; \
        sudo systemctl reload nginx 2>/dev/null || true"

    echo "[CLEANUP] All containers, images, and Nginx configs removed from remote host."
    exit 0
fi

# Collect and validate Git Repository URL
read -p "Enter Git Repository URL: " GIT_URL
if [[ ! $GIT_URL =~ ^https://github\.com/.*\.git$ ]]; then
    error "Invalid Git URL. Must be a GitHub URL ending in .git"
fi
log "Git URL set to $GIT_URL"

# Collect and validate Personal Access Token
read -p "Enter Personal Access Token: " PAT
if [[ -z $PAT ]]; then
    error "Personal Access Token cannot be empty"
fi
log "PAT received"

# Collect and validate Branch name (default to main)
read -p "Enter Branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}
log "Branch set to $BRANCH"

# Collect and validate SSH details
read -p "Enter SSH Username: " SSH_USER
if [[ -z $SSH_USER ]]; then
    error "SSH Username cannot be empty"
fi
log "SSH Username set to $SSH_USER"

read -p "Enter Server IP address: " SERVER_IP
if [[ ! $SERVER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Invalid Server IP address"
fi
log "Server IP set to $SERVER_IP"

read -p "Enter SSH Key Path: " SSH_KEY
if [[ ! -f $SSH_KEY ]]; then
    error "SSH Key file does not exist at $SSH_KEY"
fi
log "SSH Key path set to $SSH_KEY"

# Collect and validate Application port
read -p "Enter Application Port: " APP_PORT
if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]] || [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; then
    error "Invalid port number. Must be between 1 and 65535"
fi
log "Application port set to $APP_PORT"

# Clone or pull the repository
REPO_PATH=$(echo "$GIT_URL" | sed 's|https://||; s|.git$||')
REPO_DIR=$(basename "$GIT_URL" .git)
if [ -d "$REPO_DIR" ]; then
    log "Repository directory $REPO_DIR exists, pulling latest changes"
    git pull origin "$BRANCH" || error "Failed to pull latest changes"
else
    log "Cloning repository $GIT_URL"
    git clone "https://$PAT@$REPO_PATH.git" "$REPO_DIR" || error "Failed to clone repository"
fi
log "Repository operations completed for $REPO_DIR"

# Navigate into the cloned directory and verify Docker files
log "Current directory is $(pwd)"
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
    log "Found Dockerfile or docker-compose.yml, proceeding with deployment"
else
    error "No Dockerfile or docker-compose.yml found in $(pwd)"
fi

# SSH into Remote Server and Deploy
log "Testing connectivity to $SERVER_IP"

# Ping test (optional connectivity check)
log "Testing connectivity to $SERVER_IP"
if ! ping -c 3 "$SERVER_IP" > /dev/null 2>&1; then
    log "Warning: Cannot ping $SERVER_IP (common on AWS), but proceeding with SSH test"
else
    log "Ping successful"
fi

# SSH dry-run
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$SERVER_IP" true || error "SSH connection failed"
log "SSH connection test successful"

# Create remote app directory
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "mkdir -p /home/$SSH_USER/app" || error "Failed to create remote app directory"
log "Remote app directory created"

# Copy only necessary files (skip nested hng-stage1-app folder)
log "Copying app files to remote server (excluding nested folder)"
for item in Dockerfile index.html README.md deploy.sh; do
    if [ -f "$item" ] || [ -d "$item" ]; then
        scp -i "$SSH_KEY" -r "$item" "$SSH_USER@$SERVER_IP:/home/$SSH_USER/app/" || log "Warning: Failed to copy $item"
    fi
done
log "File copy completed"

# Deploy via SSH
log "Deploying application on remote server"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" \
    REMOTE_USER="ubuntu" << 'EOF'
#!/bin/bash
set -x  # Enable debugging output

# Set log file with sudo for write access
REMOTE_LOG="/home/\$REMOTE_USER/deploy_$(date +%Y%m%d).log"
# Create log directory and file with sudo
sudo mkdir -p "$(dirname \$REMOTE_LOG)" 2>/dev/null
sudo touch "\$REMOTE_LOG" 2>/dev/null && sudo chmod 664 "\$REMOTE_LOG" 2>/dev/null
# Set up log function with sudo tee for writing
log() { 
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] \$*"
    sudo tee -a "\$REMOTE_LOG" <<< "\$msg" 2>/dev/null || { echo "Log failed: \$msg" >&2; return 1; }
}

log "=== Remote Deployment Started ==="

# Install dependencies
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker"
    sudo apt update -y
    sudo apt install -y docker.io
    sudo systemctl start docker
    sudo systemctl enable docker
fi

if ! command -v nginx >/dev/null 2>&1; then
    log "Installing Nginx"
    sudo apt install -y nginx
    sudo systemctl start nginx
    sudo systemctl enable nginx
fi

# Create app directory with sudo
sudo mkdir -p "/home/\$REMOTE_USER/app" || { log "Failed to create app directory"; exit 1; }
log "Created app directory"

# Clean up ALL old containers
log "Cleaning up old containers"
for cid in $(sudo docker ps -a -q); do
    sudo docker stop \$cid || true
    sudo docker rm \$cid || true
done

# Build and run container on port 8080
cd "/home/\$REMOTE_USER/app" || { log "Failed to change to app directory"; exit 1; }
if [ -d "hng-stage1-app" ]; then
    cd "hng-stage1-app" || { log "Failed to change to hng-stage1-app directory"; exit 1; }
fi
if [ -f "./Dockerfile" ]; then

# --- Step 10.2: Idempotency (Safe Redeploy) ---
log "Checking for existing container and image before redeploying"

# If old container exists, stop and remove it
if sudo docker ps -a --format '{{.Names}}' | grep -q '^hng-stage1-app$'; then
    log "Old container 'hng-stage1-app' found. Removing it before redeployment..."
    sudo docker stop hng-stage1-app >/dev/null 2>&1 || true
    sudo docker rm hng-stage1-app >/dev/null 2>&1 || true
fi

# If old image exists, remove it
if sudo docker images --format '{{.Repository}}' | grep -q '^hng-stage1-app$'; then
    log "Old image 'hng-stage1-app' found. Removing it..."
    sudo docker rmi hng-stage1-app >/dev/null 2>&1 || true
fi

    log "Building Docker image"
    sudo docker build -t hng-stage1-app .
else
    log "Warning: Dockerfile not found in /home/\$REMOTE_USER/app/hng-stage1-app"
    ls -la  # Debug: list all directory contents
    exit 1
fi

log "Running container on port 8080"
sudo docker run -d --name hng-stage1-app -p 8080:80 hng-stage1-app

# Configure Nginx
log "Configuring Nginx reverse proxy"
sudo tee "/etc/nginx/sites-available/hng-app" > /dev/null << 'NGINX_EOF'
server {
    listen 80 default_server;
    server_name _;
    
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX_EOF

sudo ln -sf "/etc/nginx/sites-available/hng-app" "/etc/nginx/sites-enabled/"
sudo rm -f "/etc/nginx/sites-enabled/default"
if sudo nginx -t; then
    sudo systemctl reload nginx || sudo systemctl restart nginx
    log "Nginx reloaded successfully"
else
    log "Nginx configuration test failed"
    exit 1
fi

log "=== Deployment COMPLETED SUCCESSFULLY ==="
EOF

log "Remote deployment executed"




