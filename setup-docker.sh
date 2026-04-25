#!/bin/bash

# ==============================================================================
# PAPERCLIP DOCKER SETUP (AZURE VM OPTIMIZED)
# ==============================================================================
# Hỗ trợ tự động hóa hoàn toàn và cấu hình OpenCode ổn định.

set -e

# Màu sắc hiển thị
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Thư mục hiện tại
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────────────────────
# 1. Kiểm tra tham số và quyền
# ─────────────────────────────────────────────────────────────
AUTO_YES=false
if [[ "$*" == *"--yes"* ]]; then
    AUTO_YES=true
fi

# ─────────────────────────────────────────────────────────────
# 2. Thu thập thông tin cấu hình
# ─────────────────────────────────────────────────────────────
# Load existing .env if it exists to preserve secrets
if [ -f "$SCRIPT_DIR/.env" ]; then
    info "Phát hiện file .env cũ, đang tải cấu hình..."
    # Đọc file .env nhưng không export để tránh lỗi với các ký tự đặc biệt
    DOMAIN_EXISTING=$(grep '^DOMAIN=' "$SCRIPT_DIR/.env" | cut -d'=' -f2)
    INSTALL_CERTBOT_EXISTING=$(grep '^INSTALL_CERTBOT=' "$SCRIPT_DIR/.env" | cut -d'=' -f2)
    MASTER_KEY_EXISTING=$(grep '^PAPERCLIP_SECRETS_MASTER_KEY=' "$SCRIPT_DIR/.env" | cut -d'=' -f2)
    BETTER_AUTH_EXISTING=$(grep '^BETTER_AUTH_SECRET=' "$SCRIPT_DIR/.env" | cut -d'=' -f2)
    JWT_SECRET_EXISTING=$(grep '^PAPERCLIP_AGENT_JWT_SECRET=' "$SCRIPT_DIR/.env" | cut -d'=' -f2)
    INSTANCE_ID_EXISTING=$(grep '^PAPERCLIP_INSTANCE_ID=' "$SCRIPT_DIR/.env" | cut -d'=' -f2)
fi

# Ưu tiên lấy từ biến môi trường, sau đó đến file .env cũ, nếu không có mới hỏi
DOMAIN=${DOMAIN:-${DOMAIN_EXISTING}}
[[ -z "${DOMAIN}" ]] && read -p "Nhập domain của bạn (ví dụ: vinhpham.eastus.cloudapp.azure.com): " DOMAIN

INSTALL_CERTBOT=${INSTALL_CERTBOT:-${INSTALL_CERTBOT_EXISTING}}
[[ -z "${INSTALL_CERTBOT}" ]] && read -p "Bạn có muốn cài đặt SSL Certbot không? (true/false): " INSTALL_CERTBOT

# Bảo tồn Secret cũ hoặc tạo mới
PAPERCLIP_SECRETS_MASTER_KEY=${MASTER_KEY_EXISTING:-$(openssl rand -hex 32)}
BETTER_AUTH_SECRET=${BETTER_AUTH_EXISTING:-$(openssl rand -hex 32)}
PAPERCLIP_AGENT_JWT_SECRET=${JWT_SECRET_EXISTING:-$(openssl rand -hex 32)}

PROTO="http"
[[ "${INSTALL_CERTBOT}" == "true" ]] && PROTO="https"
PAPERCLIP_PUBLIC_URL=${PROTO}://${DOMAIN}

# ── Instance ─────────────────────────────────────────────────
PAPERCLIP_INSTANCE_ID=${INSTANCE_ID_EXISTING:-default}

# ─────────────────────────────────────────────────────────────
# 3. Kiểm tra Docker & Compose
# ─────────────────────────────────────────────────────────────
if ! command -v docker &> /dev/null; then
    info "Đang cài đặt Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
fi

# ─────────────────────────────────────────────────────────────
# 4. Ghi file .env
# ─────────────────────────────────────────────────────────────
info "Ghi file .env..."
cat <<EOF > "$SCRIPT_DIR/.env"
DOMAIN=${DOMAIN}
INSTALL_CERTBOT=${INSTALL_CERTBOT}
PAPERCLIP_PUBLIC_URL=${PAPERCLIP_PUBLIC_URL}
PAPERCLIP_INSTANCE_ID=${PAPERCLIP_INSTANCE_ID}
PAPERCLIP_SECRETS_MASTER_KEY=${PAPERCLIP_SECRETS_MASTER_KEY}
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
PAPERCLIP_AGENT_JWT_SECRET=${PAPERCLIP_AGENT_JWT_SECRET}
PAPERCLIP_TELEMETRY_DISABLED=1

# ── n8n Configuration ─────────────────────────────────────────
N8N_PROTOCOL=${PROTO}
N8N_WEBHOOK_URL=${PROTO}://n8n.${DOMAIN}/
EOF

# ─────────────────────────────────────────────────────────────
# 5. Khởi tạo thư mục Data và quyền truy cập (FIXED FOR OPENCODE)
# ─────────────────────────────────────────────────────────────
info "Khởi tạo thư mục data và cấu trúc OpenCode..."
# Thư mục database bắt buộc
mkdir -p "$SCRIPT_DIR/data/instances/default/db"
# Thư mục config/cache cho OpenCode
mkdir -p "$SCRIPT_DIR/data/.local"
mkdir -p "$SCRIPT_DIR/data/.cache"
mkdir -p "$SCRIPT_DIR/data/.config"
# Thư mục Nginx
mkdir -p "$SCRIPT_DIR/nginx/certbot/www"
mkdir -p "$SCRIPT_DIR/nginx/certbot/conf"

# Thư mục n8n
mkdir -p "$SCRIPT_DIR/n8n_data"
chmod -R 777 "$SCRIPT_DIR/n8n_data"

# Cấp quyền thoáng để Docker không bị lỗi EACCES
info "Cấp quyền 777 cho thư mục data..."
sudo chmod -R 777 "$SCRIPT_DIR/data"

# ĐẶC BIỆT: PostgreSQL yêu cầu thư mục db phải là 700
info "Thiết lập quyền 700 riêng cho thư mục database..."
sudo chmod 700 "$SCRIPT_DIR/data/instances/default/db"

# ─────────────────────────────────────────────────────────────
# 6. Tạo Nginx config
# ─────────────────────────────────────────────────────────────
mkdir -p "$SCRIPT_DIR/nginx/conf.d"
if [[ "${INSTALL_CERTBOT}" == "true" ]]; then
    info "Sử dụng cấu hình Nginx SSL (Certbot)..."
    # Paperclip & n8n (merged)
    cp "$SCRIPT_DIR/nginx/conf.d/paperclip.conf.template" "$SCRIPT_DIR/nginx/conf.d/paperclip.conf"
    sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" "$SCRIPT_DIR/nginx/conf.d/paperclip.conf"
    sed -i "s/PORT_PLACEHOLDER/3100/g" "$SCRIPT_DIR/nginx/conf.d/paperclip.conf"
else
    info "Sử dụng cấu hình Nginx HTTP thường..."
    # Paperclip & n8n (merged)
    cp "$SCRIPT_DIR/nginx/conf.d/paperclip-http.conf.template" "$SCRIPT_DIR/nginx/conf.d/paperclip.conf"
    sed -i "s/IP_PLACEHOLDER/${DOMAIN}/g" "$SCRIPT_DIR/nginx/conf.d/paperclip.conf"
    sed -i "s/PORT_PLACEHOLDER/3100/g" "$SCRIPT_DIR/nginx/conf.d/paperclip.conf"
fi

# ─────────────────────────────────────────────────────────────
# 7. Khởi động hệ thống
# ─────────────────────────────────────────────────────────────
info "Khởi động Containers..."
docker compose pull
docker compose up -d

# ─────────────────────────────────────────────────────────────
# 8. Hoàn tất
# ─────────────────────────────────────────────────────────────
echo -e "\n${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          ✅  CÀI ĐẶT HOÀN TẤT!                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}\n"

echo "  🌐 Paperclip: ${PAPERCLIP_PUBLIC_URL}"
echo "  🌐 n8n:       ${PROTO}://${DOMAIN}/n8n/"
echo "  📋 Log:       docker compose logs -f paperclip"
echo "  🔁 Restart:   docker compose restart paperclip"
echo ""
echo -e "${YELLOW}CÁC BƯỚC CẦN LÀM TIẾP THEO:${NC}"
echo "  1. Thiết lập Instance (chọn Advanced Setup):"
echo "     docker compose exec paperclip paperclipai onboard"
echo ""
echo "  2. Tạo link Admin CEO:"
echo "     docker compose exec paperclip paperclipai auth bootstrap-ceo"
echo ""
echo "  3. Cập nhật Model cho OpenCode (nếu chưa thấy):"
echo "     docker compose exec paperclip opencode models --refresh"
echo ""
echo -e "${RED}⚠  LƯU LẠI MASTER KEY (Cần để khôi phục dữ liệu):${NC}"
echo "   PAPERCLIP_SECRETS_MASTER_KEY=${PAPERCLIP_SECRETS_MASTER_KEY}"
echo ""

if [[ -n "${MASTER_KEY_EXISTING}" ]]; then
    warn "Lưu ý: Bạn đang sử dụng Master Key cũ từ file .env. Không cần thay đổi gì thêm."
fi
