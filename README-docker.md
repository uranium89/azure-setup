# Paperclip – Docker Deployment

Bộ cài đặt Docker thay thế cách deploy bằng `systemd` truyền thống, giúp dễ dàng scale và quản lý hơn.

## Cấu trúc file

```
.
├── docker-compose.yml                    # Compose chính (production)
├── setup-docker.sh                       # Wizard tự động cài đặt
├── .env.example                          # Template biến môi trường
└── nginx/
    └── conf.d/
        ├── paperclip.conf.template       # Template Nginx HTTPS
        └── paperclip-http.conf.template  # Template Nginx HTTP (IP)
```

## Cách sử dụng

### Option A – Wizard tự động (khuyến nghị)

```bash
bash setup-docker.sh
```

Wizard sẽ hỏi các thông số và tự:
- Cài Docker nếu chưa có
- Sinh `PAPERCLIP_SECRETS_MASTER_KEY`
- Tạo `.env` và Nginx config
- Khởi động `docker compose`
- Xin SSL certificate (Let's Encrypt) nếu chọn

### Option C – Tự động hoàn toàn (CI/CD / Automation)

Nếu bạn muốn chạy script mà không cần nhập liệu thủ công (ví dụ trong script automation hoặc cloud-init), bạn có thể truyền các biến môi trường và flag `--yes`:

```bash
DOMAIN=pc.example.com \
ADMIN_EMAIL=admin@example.com \
PAPERCLIP_PORT=3100 \
INSTALL_CERTBOT=true \
bash setup-docker.sh --yes
```

Script sẽ tự động nhận diện các biến này và bỏ qua các bước hỏi đáp.

### Option B – Thủ công

```bash
# 1. Tạo .env từ template
cp .env.example .env
# Sửa .env: điền DOMAIN, PAPERCLIP_SECRETS_MASTER_KEY, PAPERCLIP_PUBLIC_URL

# 2. Sinh secrets key
openssl rand -hex 32   # paste vào PAPERCLIP_SECRETS_MASTER_KEY

# 3. Tạo Nginx config
cp nginx/conf.d/paperclip-http.conf.template nginx/conf.d/paperclip.conf
# Sửa placeholder DOMAIN_PLACEHOLDER / PORT_PLACEHOLDER

# 4. Khởi động
docker compose up -d
```

## Các lệnh hữu ích

| Lệnh | Mô tả |
|------|--------|
| `docker compose up -d` | Khởi động tất cả services |
| `docker compose down` | Dừng và xóa containers |
| `docker compose logs -f paperclip` | Xem log realtime |
| `docker compose restart paperclip` | Restart Paperclip |
| `docker compose pull && docker compose up -d` | Update lên phiên bản mới |
| `docker compose exec paperclip opencode auth login` | Đăng nhập OpenCode trong container |

## Data Persistence

Data được lưu trong Docker volume `paperclip_data` (persistent, không mất khi restart):
- Embedded PostgreSQL
- Uploaded assets
- Secrets key
- Agent workspace

Backup volume:
```bash
docker run --rm -v paperclip_data:/data -v $(pwd):/backup alpine \
  tar czf /backup/paperclip-data-$(date +%Y%m%d).tar.gz -C /data .
```

## Scale (nâng cao)

Để scale Paperclip với load balancer:
```bash
docker compose up -d --scale paperclip=3
```

> ⚠️ Cần cấu hình external database (PostgreSQL) và shared storage khi scale > 1 instance.
