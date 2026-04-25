#!/usr/bin/env bash
# =============================================================================
# Paperclip – Docker Setup
# Mode: authenticated + public (internet-facing, login required)
# =============================================================================
# Yêu cầu: Ubuntu 22.04/24.04, Docker 24+, Docker Compose v2
#
# Có 3 cách chạy:
#
#   1) Tự động hoàn toàn qua env vars (CI/CD, Ansible, cloud-init):
#      DOMAIN=pc.example.com \
#      ADMIN_EMAIL=admin@example.com \
#      PAPERCLIP_PORT=3100 \
#      INSTALL_CERTBOT=true \
#      bash setup-docker.sh --yes
#
#   2) Load từ .env có sẵn (không hỏi gì thêm):
#      cp .env.example .env && vim .env  # chỉnh giá trị
#      bash setup-docker.sh --yes
#
#   3) Interactive wizard (mặc định):
#      bash setup-docker.sh
#
# Flag --yes / -y  →  bỏ qua bước xác nhận cuối
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
divider() { echo -e "${CYAN}────────────────────────────────────────────────${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────────────────────
# Parse flags
# ─────────────────────────────────────────────────────────────
AUTO_YES=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_YES=true ;;
    esac
done

confirm() {
    # Bỏ qua xác nhận nếu --yes hoặc đang pipe (non-interactive)
    if [[ "$AUTO_YES" == "true" ]] || ! tty -s; then
        return 0
    fi
    read -rp "$(echo -e "${CYAN}$1${NC} [Y/n]: ")" _ans
    [[ "${_ans,,}" == "n" ]] && return 1 || return 0
}

# Kiểm tra không phải root
[[ $EUID -eq 0 ]] && error "Không chạy script này bằng root. Dùng user có quyền sudo."

# ─────────────────────────────────────────────────────────────
# 1. Load cấu hình
#    Ưu tiên: env vars > .env file > interactive
# ─────────────────────────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env"
NON_INTERACTIVE=false

# Nếu .env đã tồn tại → load vào shell (chỉ load những biến chưa được set)
if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ ! "$line" =~ ^# ]] && [[ "$line" == *"="* ]]; then
            key=$(echo "$line" | cut -d'=' -f1)
            value=$(echo "$line" | cut -d'=' -f2-)
            # Chỉ set nếu biến chưa tồn tại trong môi trường
            if [[ -z "${!key:-}" ]]; then
                export "$key"="$value"
            fi
        fi
    done < "$ENV_FILE"
    info ".env đã được load (ưu tiên biến môi trường hiện tại)."
    NON_INTERACTIVE=true
fi

# Nếu env vars quan trọng đã set từ shell → coi như non-interactive
if [[ -n "${DOMAIN:-}" && -n "${ADMIN_EMAIL:-}" ]]; then
    NON_INTERACTIVE=true
fi

# ── Hàm normalize domain ──────────────────────────────────────
normalize_domain() {
    local d="$1"
    d="${d#http://}"; d="${d#https://}"; d="${d%/}"
    echo "$d"
}

if [[ "$NON_INTERACTIVE" == "true" ]]; then
    # ── Mode tự động ─────────────────────────────────────────
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Paperclip Docker Setup  [AUTO MODE]        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
    echo ""

    # Validate bắt buộc
    DOMAIN="${DOMAIN:?'Lỗi: DOMAIN chưa được set (trong .env hoặc env var)'}"
    DOMAIN="$(normalize_domain "$DOMAIN")"

    PORT="${PAPERCLIP_PORT:-${PORT:-3100}}"

    # Tự xác định IS_IP
    IS_IP=false
    [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IS_IP=true

    # INSTALL_CERTBOT: default true nếu có domain + email, false nếu là IP
    if [[ "$IS_IP" == "true" ]]; then
        INSTALL_CERTBOT="false"
    else
        INSTALL_CERTBOT="${INSTALL_CERTBOT:-true}"
        if [[ "$INSTALL_CERTBOT" == "true" ]]; then
            ADMIN_EMAIL="${ADMIN_EMAIL:?'Lỗi: ADMIN_EMAIL chưa được set'}"
        fi
    fi

    PAPERCLIP_SECRETS_MASTER_KEY="${PAPERCLIP_SECRETS_MASTER_KEY:-}"
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
    OPENAI_API_KEY="${OPENAI_API_KEY:-}"

else
    # ── Mode interactive (wizard) ─────────────────────────────
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Paperclip Docker Setup Wizard              ║${NC}"
    echo -e "${GREEN}║     Mode: authenticated + public               ║${NC}"
    echo -e "${GREEN}║     Agent: OpenCode (opencode_local)           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
    echo ""
    divider
    echo -e "${CYAN}Nhập các thông tin sau (Enter để dùng giá trị mặc định):${NC}"
    echo ""

    # Domain
    while true; do
        read -rp "$(echo -e "${CYAN}Domain hoặc IP${NC} (VD: paperclip.example.com hoặc 52.188.18.250): ")" DOMAIN
        [[ -n "$DOMAIN" ]] || { warn "Không được để trống."; continue; }
        DOMAIN="$(normalize_domain "$DOMAIN")"
        [[ -n "$DOMAIN" ]] && break
    done

    IS_IP=false
    if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        IS_IP=true
        warn "Phát hiện địa chỉ IP → sẽ dùng HTTP only (Let's Encrypt không hỗ trợ IP)."
    fi

    # Port
    read -rp "$(echo -e "${CYAN}Port${NC} [mặc định: 3100]: ")" PORT
    PORT="${PORT:-3100}"

    # Admin email
    ADMIN_EMAIL=""
    if [[ "$IS_IP" == "false" ]]; then
        while true; do
            read -rp "$(echo -e "${CYAN}Email admin${NC} (dùng cho Let's Encrypt SSL): ")" ADMIN_EMAIL
            [[ -n "$ADMIN_EMAIL" ]] && break
            warn "Email không được để trống."
        done
    fi

    # Secrets key
    echo ""
    warn "PAPERCLIP_SECRETS_MASTER_KEY dùng để mã hoá secrets."
    warn "Để trống → tự sinh ngẫu nhiên."
    read -rp "$(echo -e "${CYAN}Secrets master key${NC} [Enter để tự sinh]: ")" PAPERCLIP_SECRETS_MASTER_KEY || true

    # LLM keys
    echo ""
    echo -e "${CYAN}API keys cho adapter (tuỳ chọn, có thể thêm sau):${NC}"
    read -rp "$(echo -e "${CYAN}ANTHROPIC_API_KEY${NC} [Enter bỏ qua]: ")" ANTHROPIC_API_KEY || true
    read -rp "$(echo -e "${CYAN}OPENAI_API_KEY${NC} [Enter bỏ qua]: ")" OPENAI_API_KEY || true

    # Certbot
    INSTALL_CERTBOT="false"
    if [[ "$IS_IP" == "false" ]]; then
        if confirm "Cài Let's Encrypt SSL tự động?"; then
            INSTALL_CERTBOT="true"
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────
# Xác nhận (có thể bỏ qua bằng --yes)
# ─────────────────────────────────────────────────────────────
echo ""
divider
echo -e "${YELLOW}Cấu hình sẽ được áp dụng:${NC}"
echo "  Domain/IP:       ${DOMAIN}"
echo "  Port:            ${PORT}"
[[ -n "${ADMIN_EMAIL:-}" ]] && echo "  Admin email:     ${ADMIN_EMAIL}"
echo "  Let's Encrypt:   ${INSTALL_CERTBOT}"
divider
confirm "Bắt đầu cài đặt?" || { info "Đã huỷ."; exit 0; }
echo ""

# ─────────────────────────────────────────────────────────────
# 2. Cài Docker nếu chưa có
# ─────────────────────────────────────────────────────────────
install_docker() {
    info "Cài Docker Engine..."
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg lsb-release
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
    warn "Đã thêm '$USER' vào group 'docker'. Cần re-login hoặc chạy: newgrp docker"
}

if ! command -v docker &>/dev/null; then
    install_docker
elif ! docker compose version &>/dev/null 2>&1; then
    info "Cài Docker Compose plugin..."
    sudo apt-get install -y docker-compose-plugin
fi

info "Docker: $(docker --version)"
info "Compose: $(docker compose version)"

# ─────────────────────────────────────────────────────────────
# 3. Sinh secrets key nếu chưa có
# ─────────────────────────────────────────────────────────────
if [[ -z "${PAPERCLIP_SECRETS_MASTER_KEY:-}" ]]; then
    PAPERCLIP_SECRETS_MASTER_KEY=$(openssl rand -hex 32)
    warn "Đã sinh PAPERCLIP_SECRETS_MASTER_KEY tự động."
fi

if [[ -z "${BETTER_AUTH_SECRET:-}" ]]; then
    BETTER_AUTH_SECRET=$(openssl rand -hex 32)
    warn "Đã sinh BETTER_AUTH_SECRET tự động."
fi

# ─────────────────────────────────────────────────────────────
# 4. Tạo / cập nhật file .env
# ─────────────────────────────────────────────────────────────
PROTO="http"
[[ "$INSTALL_CERTBOT" == "true" ]] && PROTO="https"

info "Ghi file .env..."
cat > "$ENV_FILE" <<ENVEOF
# ── Server ───────────────────────────────────────────────────
HOST=0.0.0.0
PAPERCLIP_PORT=${PORT}

# ── Deployment Mode ──────────────────────────────────────────
PAPERCLIP_DEPLOYMENT_MODE=authenticated
PAPERCLIP_PUBLIC_URL=${PROTO}://${DOMAIN}

# ── Instance ─────────────────────────────────────────────────
PAPERCLIP_INSTANCE_ID=default

# ── Secrets ──────────────────────────────────────────────────
PAPERCLIP_SECRETS_MASTER_KEY=${PAPERCLIP_SECRETS_MASTER_KEY}
PAPERCLIP_SECRETS_STRICT_MODE=true
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
PAPERCLIP_AGENT_JWT_SECRET=${BETTER_AUTH_SECRET}

# ── Telemetry ────────────────────────────────────────────────
PAPERCLIP_TELEMETRY_DISABLED=1

# ── LLM API Keys ─────────────────────────────────────────────
OPENAI_API_KEY=${OPENAI_API_KEY:-}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}

# ── Meta (dùng bởi setup-docker.sh) ─────────────────────────
DOMAIN=${DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL:-}
INSTALL_CERTBOT=${INSTALL_CERTBOT}
ENVEOF

chmod 600 "$ENV_FILE"
info ".env đã được ghi."

# ─────────────────────────────────────────────────────────────
# 5. Khởi tạo thư mục Data và quyền truy cập
# ─────────────────────────────────────────────────────────────
info "Khởi tạo thư mục data và cấp quyền..."
mkdir -p "$SCRIPT_DIR/data/instances/default/db"
mkdir -p "$SCRIPT_DIR/nginx/certbot/www"
mkdir -p "$SCRIPT_DIR/nginx/certbot/conf"

# Cấp quyền ghi cho thư mục cha
sudo chmod 777 "$SCRIPT_DIR/data"
sudo chmod -R 777 "$SCRIPT_DIR/nginx/certbot"

# ĐẶC BIỆT: PostgreSQL yêu cầu thư mục db phải là 700
info "Thiết lập quyền 700 cho thư mục database..."
sudo chmod 700 "$SCRIPT_DIR/data/instances/default/db"

# ─────────────────────────────────────────────────────────────
# 6. Tạo Nginx config
# ─────────────────────────────────────────────────────────────
info "Tạo Nginx config..."
mkdir -p "$SCRIPT_DIR/nginx/conf.d"

if [[ "$IS_IP" == "true" ]]; then
    sed \
        -e "s/IP_PLACEHOLDER/${DOMAIN}/g" \
        -e "s/PORT_PLACEHOLDER/${PORT}/g" \
        "$SCRIPT_DIR/nginx/conf.d/paperclip-http.conf.template" \
        > "$SCRIPT_DIR/nginx/conf.d/paperclip.conf"
elif [[ "$INSTALL_CERTBOT" == "true" ]]; then
    # HTTP stub trước – certbot sẽ verify qua đây
    cat > "$SCRIPT_DIR/nginx/conf.d/paperclip.conf" <<NGINXHTTP
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://paperclip:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        client_max_body_size 100M;
    }
}
NGINXHTTP
else
    sed \
        -e "s/IP_PLACEHOLDER/${DOMAIN}/g" \
        -e "s/PORT_PLACEHOLDER/${PORT}/g" \
        "$SCRIPT_DIR/nginx/conf.d/paperclip-http.conf.template" \
        > "$SCRIPT_DIR/nginx/conf.d/paperclip.conf"
fi

# ─────────────────────────────────────────────────────────────
# 6. Khởi động Docker Compose
# ─────────────────────────────────────────────────────────────
info "Pull images và khởi động containers..."
cd "$SCRIPT_DIR"

DOCKER_CMD="docker"
if ! docker info &>/dev/null 2>&1; then
    warn "Chạy docker bằng sudo."
    DOCKER_CMD="sudo docker"
fi

$DOCKER_CMD compose up -d --pull always

sleep 10

# ─────────────────────────────────────────────────────────────
# 7. SSL certificate
# ─────────────────────────────────────────────────────────────
if [[ "$INSTALL_CERTBOT" == "true" ]]; then
    info "Xin SSL certificate cho ${DOMAIN}..."
    $DOCKER_CMD compose run --rm certbot certonly \
        --webroot -w /var/www/certbot \
        --non-interactive \
        --agree-tos \
        --email "$ADMIN_EMAIL" \
        -d "$DOMAIN"

    # Thay bằng full HTTPS config
    sed \
        -e "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" \
        -e "s/PORT_PLACEHOLDER/${PORT}/g" \
        "$SCRIPT_DIR/nginx/conf.d/paperclip.conf.template" \
        > "$SCRIPT_DIR/nginx/conf.d/paperclip.conf"

    $DOCKER_CMD compose exec nginx nginx -s reload
    info "SSL đã được cài đặt và Nginx đã reload."
fi

# ─────────────────────────────────────────────────────────────
# 8. Firewall UFW
# ─────────────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
    info "Cấu hình firewall (UFW)..."
    sudo ufw --force reset
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow ssh
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw --force enable
fi

# ─────────────────────────────────────────────────────────────
# 9. Tổng kết
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        ✅  Cài đặt hoàn tất!                   ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""

if $DOCKER_CMD compose ps paperclip | grep -q "running\|Up"; then
    echo -e "  ${GREEN}● Paperclip đang chạy${NC}"
else
    echo -e "  ${RED}● Paperclip chưa chạy – xem log bên dưới${NC}"
    $DOCKER_CMD compose logs paperclip --tail 20
fi

echo ""
echo "  🌐 URL:     ${PROTO}://${DOMAIN}"
echo "  📂 Data:    Docker volume 'paperclip_data'"
echo "  📋 Log:     docker compose logs -f paperclip"
echo "  🔁 Restart: docker compose restart paperclip"
echo "  🔄 Update:  docker compose pull && docker compose up -d"
echo ""
echo -e "${YELLOW}BƯỚC TIẾP THEO:${NC}"
echo "  1. Mở ${PROTO}://${DOMAIN} → Claim Board Admin
  2. Tạo link đăng ký Admin (CEO) bằng lệnh:
     docker compose exec paperclip pnpm paperclipai auth bootstrap-ceo
  3. Vào Settings → Agents → New Agent → Adapter: opencode_local
  4. (Tuỳ chọn) Đăng nhập OpenCode:
     docker compose exec paperclip opencode auth login
"
echo ""
echo -e "${RED}⚠  LƯU LẠI KEY NÀY (cần để restore):${NC}"
echo "   PAPERCLIP_SECRETS_MASTER_KEY=${PAPERCLIP_SECRETS_MASTER_KEY}"
echo ""
