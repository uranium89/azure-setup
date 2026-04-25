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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
prompt()  { echo -e "${CYAN}$*${NC}"; }
divider() { echo -e "${CYAN}────────────────────────────────────────────────${NC}"; }

# ─────────────────────────────────────────────────────────────
# 1. Thu thập thông tin cấu hình
# ─────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Paperclip Production Setup Wizard          ║${NC}"
echo -e "${GREEN}║     Mode: authenticated + public               ║${NC}"
echo -e "${GREEN}║     Agent: OpenCode (opencode_local)           ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""

# Kiểm tra không phải root
[[ $EUID -eq 0 ]] && error "Không chạy script này bằng root. Dùng user có quyền sudo."

divider
prompt "Nhập các thông tin sau (Enter để dùng giá trị mặc định):"
echo ""

# Domain
while true; do
    read -rp "$(echo -e "${CYAN}Domain hoặc IP${NC} (VD: paperclip.example.com hoặc 52.188.18.250): ")" DOMAIN
    [[ -n "$DOMAIN" ]] || { warn "Không được để trống."; continue; }

    # Tự strip http:// https:// và trailing slash
    DOMAIN="${DOMAIN#http://}"
    DOMAIN="${DOMAIN#https://}"
    DOMAIN="${DOMAIN%/}"

    [[ -n "$DOMAIN" ]] && break
done

# Kiểm tra có phải IP không (Certbot không hỗ trợ IP)
IS_IP=false
if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IS_IP=true
    warn "Phát hiện địa chỉ IP: $DOMAIN"
    warn "Let's Encrypt không cấp SSL cho IP. INSTALL_CERTBOT sẽ tự tắt."
    warn "Nếu muốn HTTPS, trỏ domain về IP này rồi chạy lại script."
fi


# Port
read -rp "$(echo -e "${CYAN}Port${NC} [mặc định: 3100]: ")" PORT
PORT="${PORT:-3100}"

# Admin email
while true; do
    read -rp "$(echo -e "${CYAN}Email admin${NC} (dùng cho Let's Encrypt SSL): ")" ADMIN_EMAIL
    [[ -n "$ADMIN_EMAIL" ]] && break
    warn "Email không được để trống."
done

# Secrets master key
echo ""
warn "PAPERCLIP_SECRETS_MASTER_KEY dùng để mã hoá secrets."
warn "Để trống → tự sinh ngẫu nhiên (nhớ lưu lại key sau khi cài)."
read -rp "$(echo -e "${CYAN}Secrets master key${NC} [Enter để tự sinh]: ")" PAPERCLIP_SECRETS_MASTER_KEY

# Nginx
read -rp "$(echo -e "${CYAN}Cài Nginx reverse proxy?${NC} [Y/n]: ")" _NGINX
INSTALL_NGINX="true"
[[ "${_NGINX,,}" == "n" ]] && INSTALL_NGINX="false"

# Certbot
if [[ "$IS_IP" == "true" ]]; then
    # IP address → không thể dùng Let's Encrypt
    INSTALL_CERTBOT="false"
elif [[ "$INSTALL_NGINX" == "true" ]]; then
    read -rp "$(echo -e "${CYAN}Cài Let's Encrypt SSL tự động?${NC} [Y/n]: ")" _CERT
    INSTALL_CERTBOT="true"
    [[ "${_CERT,,}" == "n" ]] && INSTALL_CERTBOT="false"
else
    INSTALL_CERTBOT="false"
fi

# Các giá trị cố định
PAPERCLIP_HOME="/opt/paperclip-data"
PAPERCLIP_USER="paperclip"

# Xác nhận
echo ""
divider
echo -e "${YELLOW}Xác nhận cấu hình:${NC}"
echo "  Domain:          https://${DOMAIN}"
echo "  Port:            ${PORT}"
echo "  Admin email:     ${ADMIN_EMAIL}"
echo "  Data dir:        ${PAPERCLIP_HOME}"
echo "  Nginx:           ${INSTALL_NGINX}"
echo "  Let's Encrypt:   ${INSTALL_CERTBOT}"
divider
read -rp "$(echo -e "${CYAN}Bắt đầu cài đặt?${NC} [Y/n]: ")" _CONFIRM
[[ "${_CONFIRM,,}" == "n" ]] && { info "Đã huỷ."; exit 0; }
echo ""

# ─────────────────────────────────────────────────────────────
# 2. Cập nhật hệ thống
# ─────────────────────────────────────────────────────────────
info "Cập nhật hệ thống..."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y curl git build-essential ca-certificates gnupg lsb-release openssl

# ─────────────────────────────────────────────────────────────
# 3. Node.js 22 (LTS)
# ─────────────────────────────────────────────────────────────
NODE_MAJOR=$(node -v 2>/dev/null | cut -d. -f1 | tr -d 'v' || echo 0)
if ! command -v node &>/dev/null || [[ "$NODE_MAJOR" -lt 20 ]]; then
    info "Cài Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
info "Node.js: $(node --version)"

# ─────────────────────────────────────────────────────────────
# 4. pnpm >= 9.15
# ─────────────────────────────────────────────────────────────
if ! command -v pnpm &>/dev/null; then
    info "Cài pnpm..."
    sudo npm install -g pnpm@latest
fi
info "pnpm: $(pnpm --version)"

# ─────────────────────────────────────────────────────────────
# 5. OpenCode CLI
# ─────────────────────────────────────────────────────────────
if ! command -v opencode &>/dev/null; then
    info "Cài OpenCode CLI..."
    curl -fsSL https://opencode.ai/install | bash
    export PATH="$HOME/.local/bin:$PATH"
    grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc || \
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi
opencode --version && info "OpenCode: $(opencode --version)" || \
    warn "opencode chưa có trong PATH, kiểm tra sau khi re-login."

# ─────────────────────────────────────────────────────────────
# 6. System user & thư mục data
# ─────────────────────────────────────────────────────────────
info "Tạo user '$PAPERCLIP_USER' và thư mục data..."
if ! id -u "$PAPERCLIP_USER" &>/dev/null; then
    sudo useradd --system --shell /bin/bash --create-home "$PAPERCLIP_USER"
fi
sudo mkdir -p "$PAPERCLIP_HOME"
sudo chown -R "$PAPERCLIP_USER:$PAPERCLIP_USER" "$PAPERCLIP_HOME"

# ─────────────────────────────────────────────────────────────
# 7. Clone & build Paperclip
# ─────────────────────────────────────────────────────────────
info "Clone và build Paperclip..."
sudo mkdir -p /opt/paperclip
sudo chown -R "$PAPERCLIP_USER:$PAPERCLIP_USER" /opt/paperclip

sudo -u "$PAPERCLIP_USER" bash -c "
    export HOME=/home/$PAPERCLIP_USER
    export PATH=\"\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin\"
    cd /opt/paperclip

    if [ ! -d .git ]; then
        git clone https://github.com/paperclipai/paperclip.git .
    else
        git pull origin master
    fi

    pnpm install --frozen-lockfile
    pnpm build
"

# ─────────────────────────────────────────────────────────────
# 8. Sinh secrets key nếu chưa có
# ─────────────────────────────────────────────────────────────
if [[ -z "$PAPERCLIP_SECRETS_MASTER_KEY" ]]; then
    PAPERCLIP_SECRETS_MASTER_KEY=$(openssl rand -hex 32)
    warn "Đã sinh PAPERCLIP_SECRETS_MASTER_KEY tự động."
fi

# ─────────────────────────────────────────────────────────────
# 9. Tạo .env
# ─────────────────────────────────────────────────────────────
info "Tạo file /opt/paperclip/.env..."

sudo -u "$PAPERCLIP_USER" tee /opt/paperclip/.env > /dev/null << ENVEOF
# ── Server ───────────────────────────────────────────────────
PORT=${PORT}
HOST=0.0.0.0

# ── Deployment Mode ──────────────────────────────────────────
# authenticated + public: yêu cầu login, cần URL public tường minh
PAPERCLIP_DEPLOYMENT_MODE=authenticated
PAPERCLIP_PUBLIC_URL=https://${DOMAIN}

# ── Data & Storage ───────────────────────────────────────────
PAPERCLIP_HOME=${PAPERCLIP_HOME}
PAPERCLIP_INSTANCE_ID=production

# ── Secrets ──────────────────────────────────────────────────
PAPERCLIP_SECRETS_MASTER_KEY=${PAPERCLIP_SECRETS_MASTER_KEY}
PAPERCLIP_SECRETS_STRICT_MODE=true

# ── LLM Provider Keys ────────────────────────────────────────
# OpenCode dùng session auth riêng (chạy: opencode auth login)
# Không cần API key ở đây.
# Nếu muốn dùng Claude/OpenAI trực tiếp, thêm key vào
# Paperclip Secrets Manager sau khi cài xong.
# OPENAI_API_KEY=
# ANTHROPIC_API_KEY=

# ── Telemetry ────────────────────────────────────────────────
PAPERCLIP_TELEMETRY_DISABLED=1

# ── Node ─────────────────────────────────────────────────────
NODE_ENV=production
ENVEOF

sudo chmod 600 /opt/paperclip/.env

# ─────────────────────────────────────────────────────────────
# 10. systemd service
# ─────────────────────────────────────────────────────────────
info "Tạo systemd service..."
sudo tee /etc/systemd/system/paperclip.service > /dev/null << SVCEOF
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

sudo systemctl daemon-reload
sudo systemctl enable paperclip

# ─────────────────────────────────────────────────────────────
# 11. Nginx reverse proxy
# ─────────────────────────────────────────────────────────────
if [[ "$INSTALL_NGINX" == "true" ]]; then
    info "Cài và cấu hình Nginx..."
    sudo apt-get install -y nginx
    sudo ln -sf /etc/nginx/sites-available/paperclip /etc/nginx/sites-enabled/paperclip
    sudo rm -f /etc/nginx/sites-enabled/default
fi

# ─────────────────────────────────────────────────────────────
# 12. Let's Encrypt SSL + Nginx config
# ─────────────────────────────────────────────────────────────
if [[ "$INSTALL_CERTBOT" == "true" ]]; then
    info "Cài Let's Encrypt SSL cho ${DOMAIN}..."
    sudo apt-get install -y certbot python3-certbot-nginx

    # Lấy cert trước khi viết Nginx HTTPS config
    sudo systemctl stop nginx 2>/dev/null || true
    sudo certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --email "$ADMIN_EMAIL" \
        -d "$DOMAIN"

    # Cert đã có → viết HTTPS config
    sudo tee /etc/nginx/sites-available/paperclip > /dev/null << NGINXHTTPS
upstream paperclip_backend {
    server 127.0.0.1:${PORT};
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 300s;
    proxy_connect_timeout 10s;
    client_max_body_size 100M;

    location / {
        proxy_pass http://paperclip_backend;
    }
}
NGINXHTTPS

    sudo nginx -t
    sudo systemctl start nginx
    sudo systemctl enable nginx

    # Auto-renew
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --nginx") | \
        sort -u | crontab -

elif [[ "$INSTALL_NGINX" == "true" ]]; then
    # Không có cert (IP hoặc người dùng chọn không) → HTTP only
    warn "Không cài SSL. Nginx chỉ chạy HTTP (port 80)."
    sudo tee /etc/nginx/sites-available/paperclip > /dev/null << NGINXHTTP
upstream paperclip_backend {
    server 127.0.0.1:${PORT};
    keepalive 32;
}
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 300s;
    client_max_body_size 100M;

    location / {
        proxy_pass http://paperclip_backend;
    }
}
NGINXHTTP
    sudo nginx -t
    sudo systemctl enable nginx
    sudo systemctl restart nginx
fi

# ─────────────────────────────────────────────────────────────
# 13. UFW Firewall
# ─────────────────────────────────────────────────────────────
info "Cấu hình firewall (UFW)..."
sudo apt-get install -y ufw
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
# Port 3100 chỉ nội bộ (Nginx proxy), không expose ra internet
sudo ufw --force enable

# ─────────────────────────────────────────────────────────────
# 14. Khởi động Paperclip
# ─────────────────────────────────────────────────────────────
info "Khởi động Paperclip..."
sudo systemctl start paperclip
sleep 5

# ─────────────────────────────────────────────────────────────
# 15. Tổng kết
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        ✅  Cài đặt hoàn tất!                   ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""

PROTO="https"
[[ "$INSTALL_CERTBOT" != "true" ]] && PROTO="http"

if sudo systemctl is-active --quiet paperclip; then
    echo -e "  ${GREEN}● Paperclip đang chạy${NC}"
else
    echo -e "  ${RED}● Paperclip chưa chạy – xem log bên dưới${NC}"
    sudo journalctl -u paperclip -n 20 --no-pager
fi

echo ""
echo "  🌐 URL:     ${PROTO}://${DOMAIN}"
echo "  📂 Data:    ${PAPERCLIP_HOME}"
echo "  📋 Log:     journalctl -u paperclip -f"
echo "  🔁 Restart: sudo systemctl restart paperclip"
echo ""
echo -e "${YELLOW}BƯỚC TIẾP THEO:${NC}"
echo "  1. Mở ${PROTO}://${DOMAIN} → Claim Board Admin"
echo "  2. Vào Settings → Agents → New Agent"
echo "     Adapter: opencode_local"
echo "  3. Đăng nhập OpenCode trên server:"
echo "     sudo -u ${PAPERCLIP_USER} bash -c 'opencode auth login'"
echo ""
echo -e "${RED}⚠  LƯU LẠI KEY NÀY (cần để restore):${NC}"
echo "   PAPERCLIP_SECRETS_MASTER_KEY=${PAPERCLIP_SECRETS_MASTER_KEY}"
echo ""
