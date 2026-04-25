#!/usr/bin/env bash
# =============================================================================
# Paperclip Production Setup Script
# Mode: authenticated + public (internet-facing, login required)
# Code Provider: OpenCode (opencode_local adapter)
# =============================================================================
# Yêu cầu: Ubuntu 22.04/24.04, chạy với user có quyền sudo
# Sử dụng: bash setup-paperclip.sh
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# 0. Cấu hình – Sửa các biến này trước khi chạy
# ─────────────────────────────────────────────────────────────
DOMAIN=""                   # VD: paperclip.example.com  (bắt buộc cho public mode)
PORT="3100"                 # Port mà Paperclip lắng nghe
PAPERCLIP_HOME="/opt/paperclip-data"
PAPERCLIP_USER="paperclip"  # System user chạy service

# OpenCode / LLM provider key (ít nhất 1 cái)
OPENAI_API_KEY=""           # OpenAI key (dùng với opencode_local)
ANTHROPIC_API_KEY=""        # Anthropic key (tuỳ chọn)

# Email admin đầu tiên (dùng để claim board sau khi cài)
ADMIN_EMAIL=""

# Secrets master key (để trống → tự sinh, nhưng nên set cứng để restore được)
PAPERCLIP_SECRETS_MASTER_KEY=""

# Nginx + SSL
INSTALL_NGINX=true          # true = cài Nginx reverse proxy
INSTALL_CERTBOT=true        # true = cài Let's Encrypt SSL (cần DOMAIN đã trỏ về VM)

# ─────────────────────────────────────────────────────────────
# 1. Validation
# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

info "=== Paperclip Production Setup ==="

[[ $EUID -eq 0 ]] && error "Không chạy script này bằng root. Dùng user có quyền sudo."
[[ -z "$DOMAIN" ]] && error "Chưa đặt DOMAIN. Mở script và sửa biến DOMAIN."
[[ -z "$OPENAI_API_KEY" && -z "$ANTHROPIC_API_KEY" ]] && \
    error "Cần ít nhất một API key: OPENAI_API_KEY hoặc ANTHROPIC_API_KEY."
[[ -z "$ADMIN_EMAIL" ]] && error "Chưa đặt ADMIN_EMAIL."

# ─────────────────────────────────────────────────────────────
# 2. Cập nhật hệ thống
# ─────────────────────────────────────────────────────────────
info "Cập nhật hệ thống..."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y curl git build-essential ca-certificates gnupg lsb-release

# ─────────────────────────────────────────────────────────────
# 3. Cài Node.js 22 (LTS) qua NodeSource
# ─────────────────────────────────────────────────────────────
if ! command -v node &>/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d 'v')" -lt 20 ]]; then
    info "Cài Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
node --version
npm --version

# ─────────────────────────────────────────────────────────────
# 4. Cài pnpm >= 9.15
# ─────────────────────────────────────────────────────────────
if ! command -v pnpm &>/dev/null; then
    info "Cài pnpm..."
    npm install -g pnpm@latest
fi
pnpm --version

# ─────────────────────────────────────────────────────────────
# 5. Cài OpenCode CLI
# ─────────────────────────────────────────────────────────────
if ! command -v opencode &>/dev/null; then
    info "Cài OpenCode CLI..."
    curl -fsSL https://opencode.ai/install | bash
    # Thêm vào PATH nếu cần
    export PATH="$HOME/.local/bin:$PATH"
    grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc || \
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi
opencode --version || warn "opencode chưa có trong PATH, kiểm tra lại sau khi login lại."

# ─────────────────────────────────────────────────────────────
# 6. Tạo system user và thư mục data
# ─────────────────────────────────────────────────────────────
info "Tạo user '$PAPERCLIP_USER' và thư mục data..."
if ! id -u "$PAPERCLIP_USER" &>/dev/null; then
    sudo useradd --system --shell /bin/bash --create-home "$PAPERCLIP_USER"
fi
sudo mkdir -p "$PAPERCLIP_HOME"
sudo chown -R "$PAPERCLIP_USER:$PAPERCLIP_USER" "$PAPERCLIP_HOME"

# ─────────────────────────────────────────────────────────────
# 7. Cài Paperclip bằng npx onboard (non-interactive)
# ─────────────────────────────────────────────────────────────
info "Cài Paperclip vào /opt/paperclip..."
sudo mkdir -p /opt/paperclip
sudo chown -R "$PAPERCLIP_USER:$PAPERCLIP_USER" /opt/paperclip

# Chạy onboard dưới user paperclip
sudo -u "$PAPERCLIP_USER" bash -c "
    export HOME=/home/$PAPERCLIP_USER
    export PATH=\"\$HOME/.local/bin:\$PATH:/usr/local/bin\"
    cd /opt/paperclip

    # Clone repo mới nhất
    if [ ! -d .git ]; then
        git clone https://github.com/paperclipai/paperclip.git .
    else
        git pull origin master
    fi

    # Cài dependencies
    pnpm install --frozen-lockfile

    # Build production
    pnpm build
"

# ─────────────────────────────────────────────────────────────
# 8. Tạo file .env cho production
# ─────────────────────────────────────────────────────────────
info "Tạo file cấu hình .env..."

# Sinh master key nếu chưa có
if [[ -z "$PAPERCLIP_SECRETS_MASTER_KEY" ]]; then
    PAPERCLIP_SECRETS_MASTER_KEY=$(openssl rand -hex 32)
    warn "Đã sinh PAPERCLIP_SECRETS_MASTER_KEY tự động. Lưu key này lại để restore:"
    warn "  $PAPERCLIP_SECRETS_MASTER_KEY"
fi

sudo -u "$PAPERCLIP_USER" bash -c "cat > /opt/paperclip/.env << 'ENVEOF'
# ── Server ──────────────────────────────────────────
PORT=${PORT}
HOST=0.0.0.0

# ── Deployment Mode ──────────────────────────────────
# authenticated + public: yêu cầu login, cần URL public
PAPERCLIP_DEPLOYMENT_MODE=authenticated
PAPERCLIP_PUBLIC_URL=https://${DOMAIN}

# ── Data & Storage ────────────────────────────────────
PAPERCLIP_HOME=${PAPERCLIP_HOME}
PAPERCLIP_INSTANCE_ID=production

# ── Secrets ──────────────────────────────────────────
PAPERCLIP_SECRETS_MASTER_KEY=${PAPERCLIP_SECRETS_MASTER_KEY}
PAPERCLIP_SECRETS_STRICT_MODE=true

# ── LLM Provider Keys ────────────────────────────────
OPENAI_API_KEY=${OPENAI_API_KEY}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}

# ── Telemetry (tắt trong production) ─────────────────
PAPERCLIP_TELEMETRY_DISABLED=1

# ── Node ─────────────────────────────────────────────
NODE_ENV=production
ENVEOF
"

sudo chmod 600 /opt/paperclip/.env
sudo chown "$PAPERCLIP_USER:$PAPERCLIP_USER" /opt/paperclip/.env

# ─────────────────────────────────────────────────────────────
# 9. Tạo systemd service
# ─────────────────────────────────────────────────────────────
info "Tạo systemd service..."
sudo bash -c "cat > /etc/systemd/system/paperclip.service << SVCEOF
[Unit]
Description=Paperclip AI Orchestration Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PAPERCLIP_USER}
WorkingDirectory=/opt/paperclip
EnvironmentFile=/opt/paperclip/.env
Environment=PATH=/home/${PAPERCLIP_USER}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/local/bin/pnpm paperclipai run
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=paperclip

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${PAPERCLIP_HOME} /opt/paperclip /tmp

[Install]
WantedBy=multi-user.target
SVCEOF
"

sudo systemctl daemon-reload
sudo systemctl enable paperclip

# ─────────────────────────────────────────────────────────────
# 10. Cài Nginx (reverse proxy)
# ─────────────────────────────────────────────────────────────
if [[ "$INSTALL_NGINX" == "true" ]]; then
    info "Cài và cấu hình Nginx..."
    sudo apt-get install -y nginx

    sudo bash -c "cat > /etc/nginx/sites-available/paperclip << NGINXEOF
upstream paperclip_backend {
    server 127.0.0.1:${PORT};
    keepalive 32;
}

# Redirect HTTP → HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\\\$host\\\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    # SSL – sẽ được Certbot điền vào
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection \"1; mode=block\";
    add_header Referrer-Policy \"strict-origin-when-cross-origin\";
    add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains\" always;

    # WebSocket support (Paperclip dùng live updates)
    proxy_http_version 1.1;
    proxy_set_header Upgrade \\\$http_upgrade;
    proxy_set_header Connection \"upgrade\";

    proxy_set_header Host \\\$host;
    proxy_set_header X-Real-IP \\\$remote_addr;
    proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \\\$scheme;

    proxy_read_timeout 300s;
    proxy_connect_timeout 10s;
    client_max_body_size 100M;

    location / {
        proxy_pass http://paperclip_backend;
    }
}
NGINXEOF
"

    sudo ln -sf /etc/nginx/sites-available/paperclip /etc/nginx/sites-enabled/paperclip
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t
    sudo systemctl enable nginx
    sudo systemctl restart nginx
fi

# ─────────────────────────────────────────────────────────────
# 11. Cài Let's Encrypt SSL
# ─────────────────────────────────────────────────────────────
if [[ "$INSTALL_CERTBOT" == "true" && "$INSTALL_NGINX" == "true" ]]; then
    info "Cài Let's Encrypt SSL cho $DOMAIN..."
    sudo apt-get install -y certbot python3-certbot-nginx

    # Tạm thời cài cert với Nginx đang chạy HTTP trước
    # (Nginx config trên sẽ lỗi nếu cert chưa tồn tại – dùng --standalone lần đầu)
    sudo systemctl stop nginx
    sudo certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --email "$ADMIN_EMAIL" \
        -d "$DOMAIN"
    sudo systemctl start nginx

    # Auto-renew
    sudo systemctl enable certbot.timer 2>/dev/null || \
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --nginx") | crontab -
fi

# ─────────────────────────────────────────────────────────────
# 12. Cấu hình UFW firewall
# ─────────────────────────────────────────────────────────────
info "Cấu hình firewall..."
sudo apt-get install -y ufw
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
# Port 3100 CHỈ mở nội bộ (Nginx proxy), KHÔNG expose ra ngoài
sudo ufw --force enable

# ─────────────────────────────────────────────────────────────
# 13. Khởi động Paperclip
# ─────────────────────────────────────────────────────────────
info "Khởi động Paperclip service..."
sudo systemctl start paperclip

sleep 5
if sudo systemctl is-active --quiet paperclip; then
    info "✅ Paperclip đang chạy!"
else
    warn "Paperclip chưa start được. Kiểm tra log: journalctl -u paperclip -n 50"
fi

# ─────────────────────────────────────────────────────────────
# 14. Hướng dẫn sau cài
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Paperclip đã cài xong!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo "  🌐 URL:      https://${DOMAIN}"
echo "  📂 Data:     ${PAPERCLIP_HOME}"
echo "  📋 Log:      journalctl -u paperclip -f"
echo "  🔁 Restart:  sudo systemctl restart paperclip"
echo ""
echo -e "${YELLOW}BƯỚC TIẾP THEO:${NC}"
echo "  1. Mở https://${DOMAIN} trong trình duyệt"
echo "  2. Claim board admin theo link trong màn hình đầu tiên"
echo "  3. Vào Settings → Agents → Thêm agent mới với adapter: opencode_local"
echo "     - Model: openai/gpt-4o  (hoặc anthropic/claude-opus-4-5)"
echo "     - OpenCode sẽ dùng OPENAI_API_KEY đã cài trong .env"
echo "  4. Tạo Company → Assign agent → Add goals → Agent bắt đầu làm việc"
echo ""
echo -e "${YELLOW}LƯU LẠI KEY NÀY (cần để restore):${NC}"
echo "  PAPERCLIP_SECRETS_MASTER_KEY=${PAPERCLIP_SECRETS_MASTER_KEY}"
echo ""
