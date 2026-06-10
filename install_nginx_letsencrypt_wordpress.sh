#!/usr/bin/env bash
#
# Nginx + Let's Encrypt (Certbot) как reverse-proxy для WordPress в Docker.
# Ubuntu 24.04 LTS. Идемпотентно: повторный запуск безопасен.
#
# Использование:
#   sudo ./install_nginx_letsencrypt_wordpress.sh <домен> <email> [порт_контейнера]
# или через переменные окружения:
#   sudo DOMAIN=example.com EMAIL=admin@example.com ./install_nginx_letsencrypt_wordpress.sh

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ======== ПАРАМЕТРЫ (env или аргументы) ========
DOMAIN="${1:-${DOMAIN:-}}"
EMAIL="${2:-${EMAIL:-}}"
WP_CONTAINER_PORT="${3:-${WP_CONTAINER_PORT:-8080}}"  # порт WordPress-контейнера на localhost
WP_CONTAINER_NAME="${WP_CONTAINER_NAME:-wordpress}"
INCLUDE_WWW="${INCLUDE_WWW:-1}"   # 1 = выпускать сертификат и на www.<домен>

# Цвета
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()     { echo -e "${GREEN}[INFO]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# ======== ПРОВЕРКИ ========
[[ "$(id -u)" -eq 0 ]] || error "Запустите с правами root: sudo $0 <домен> <email>"

[[ -n "$DOMAIN" ]] || error "Не задан домен. Пример: sudo $0 example.com admin@example.com"
[[ "$DOMAIN" != "domain.ru" ]] || error "Замените домен-заглушку 'domain.ru' на реальный."
[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || error "Некорректный домен: $DOMAIN"

[[ -n "$EMAIL" ]] || error "Не задан email для Let's Encrypt."
[[ "$EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] || error "Некорректный email: $EMAIL"

# Сертификат запрашиваем на домен и (опц.) www — только если для www есть DNS-запись
CERT_DOMAINS=(-d "$DOMAIN")
if [[ "$INCLUDE_WWW" -eq 1 ]]; then
    if getent hosts "www.$DOMAIN" &>/dev/null || host "www.$DOMAIN" &>/dev/null; then
        CERT_DOMAINS+=(-d "www.$DOMAIN")
    else
        warning "DNS-запись для www.$DOMAIN не найдена — сертификат будет только для $DOMAIN."
    fi
fi

log "Настройка Nginx + Let's Encrypt для домена $DOMAIN..."

# ======== УСТАНОВКА ПАКЕТОВ ========
log "Обновление списка пакетов..."
apt-get update -y || error "apt-get update не удался."

log "Установка Nginx и Certbot..."
apt-get install -y --no-install-recommends \
    nginx curl ca-certificates certbot python3-certbot-nginx bind9-host \
    || error "Не удалось установить пакеты."

# ======== БАЗОВАЯ HTTP-КОНФИГУРАЦИЯ ========
log "Создание HTTP-конфигурации Nginx..."
cat > "/etc/nginx/sites-available/${DOMAIN}" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    client_max_body_size 64M;

    location / {
        proxy_pass http://127.0.0.1:${WP_CONTAINER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_connect_timeout 300;
        proxy_send_timeout 300;
        proxy_read_timeout 300;
        send_timeout 300;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)\$ {
        proxy_pass http://127.0.0.1:${WP_CONTAINER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        access_log off;
        expires max;
        log_not_found off;
    }
}
EOF

ln -sf "/etc/nginx/sites-available/${DOMAIN}" /etc/nginx/sites-enabled/
[[ -e /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default

log "Проверка конфигурации Nginx..."
nginx -t || error "Ошибка в конфигурации Nginx."
systemctl reload nginx || systemctl restart nginx || error "Не удалось перезапустить Nginx."

# ======== ПОЛУЧЕНИЕ СЕРТИФИКАТА ========
log "Запрос SSL-сертификата у Let's Encrypt..."
if certbot --nginx "${CERT_DOMAINS[@]}" --non-interactive --agree-tos \
        --email "$EMAIL" --redirect; then
    log "Сертификат получен и HTTP->HTTPS редирект настроен certbot'ом."
else
    warning "Не удалось получить сертификат. Проверьте DNS ($DOMAIN -> IP сервера), порт 80 и логи /var/log/letsencrypt/."
fi

# ======== ХАРДНЕНИНГ HTTPS ========
if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    log "Добавление заголовков безопасности..."
    # Только то, что НЕ дублирует certbot options-ssl-nginx.conf (ssl_protocols/ciphers и т.п.)
    cat > /etc/nginx/conf.d/security-headers.conf << 'EOF'
# Заголовки безопасности (HSTS включаем после проверки, что HTTPS стабилен)
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
EOF

    if nginx -t; then
        systemctl reload nginx
        log "Заголовки безопасности применены."
    else
        warning "Ошибка конфигурации — откатываю заголовки безопасности."
        rm -f /etc/nginx/conf.d/security-headers.conf
        nginx -t && systemctl reload nginx || true
    fi

    cat << EOF

${YELLOW}=== Настройте WordPress для HTTPS ===${NC}
1. Админка -> Настройки -> Общие
2. 'Адрес WordPress' и 'Адрес сайта' -> https://${DOMAIN}
3. В wp-config.php при работе за прокси добавьте:
   if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO']==='https') \$_SERVER['HTTPS']='on';
EOF
else
    warning "Каталог сертификата не найден — пропускаю HTTPS-хардненинг."
fi

# ======== АВТООБНОВЛЕНИЕ СЕРТИФИКАТОВ ========
# Certbot из apt уже ставит systemd-таймер (certbot.timer) — отдельный cron не нужен.
# Добавляем только deploy-hook для перезагрузки Nginx после обновления.
log "Настройка перезагрузки Nginx после обновления сертификата..."
install -d /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'EOF'
#!/usr/bin/env bash
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
# На случай ручного cron-задания из старых версий — убираем дубль
rm -f /etc/cron.d/certbot-renew
systemctl enable --now certbot.timer 2>/dev/null || true

# ======== ФАЙРВОЛ ========
if command -v ufw &>/dev/null; then
    log "Открываю порты Nginx в UFW..."
    ufw allow 'Nginx Full' || warning "Не удалось настроить UFW для Nginx."
else
    warning "UFW не установлен — настройте файрвол отдельно."
fi

# ======== ПРОВЕРКА КОНТЕЙНЕРА ========
if command -v docker &>/dev/null && docker ps --format '{{.Names}}' | grep -qx "${WP_CONTAINER_NAME}"; then
    log "Контейнер ${WP_CONTAINER_NAME} запущен."
else
    warning "Контейнер ${WP_CONTAINER_NAME} не найден. Убедитесь, что WordPress слушает 127.0.0.1:${WP_CONTAINER_PORT}."
fi

log "Готово! Сайт: https://${DOMAIN}"
cat << EOF

${GREEN}=== Полезные команды ===${NC}
  certbot certificates              # статус сертификатов
  certbot renew --dry-run           # тест автообновления
  systemctl status certbot.timer    # таймер автообновления
  tail -f /var/log/nginx/error.log  # логи Nginx
EOF
