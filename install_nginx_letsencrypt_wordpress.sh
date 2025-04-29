#!/bin/bash

# Скрипт установки Nginx и Let's Encrypt для WordPress в Docker
# Для домена: domain.ru

set -e

# Параметры
DOMAIN="domain.ru"
EMAIL="admin@${DOMAIN}" # Измените на свой реальный email
WP_CONTAINER_NAME="wordpress"
WP_CONTAINER_PORT="80"  # Порт, на котором работает WordPress в Docker

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Функция логирования
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then
    error "Скрипт должен быть запущен с правами суперпользователя (sudo)."
fi

log "Начинаем настройку Nginx и Let's Encrypt для домена $DOMAIN..."

# Обновление системы
log "Обновление пакетов..."
apt update && apt upgrade -y || error "Не удалось обновить пакеты."

# Установка Nginx и зависимостей для Let's Encrypt
log "Установка Nginx и необходимых пакетов..."
apt install -y nginx curl software-properties-common gnupg2 ca-certificates lsb-release debian-archive-keyring || error "Не удалось установить необходимые пакеты."

# Настройка базовой конфигурации Nginx (только HTTP)
log "Настройка базовой HTTP конфигурации Nginx..."
cat > /etc/nginx/sites-available/${DOMAIN} << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    location / {
        proxy_pass http://localhost:${WP_CONTAINER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        # Настройки для больших файлов WordPress
        client_max_body_size 50M;
        
        # Настройки таймаутов
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
        proxy_read_timeout 300;
        send_timeout 300;
    }
    
    # Дополнительные настройки для WordPress
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        proxy_pass http://localhost:${WP_CONTAINER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        access_log off;
        expires max;
        log_not_found off;
    }
}
EOF

# Создание символической ссылки для активации конфигурации
ln -sf /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/ || error "Не удалось создать символическую ссылку."

# Удаление дефолтного конфига, если он существует
if [ -f /etc/nginx/sites-enabled/default ]; then
    log "Удаление дефолтной конфигурации Nginx..."
    rm /etc/nginx/sites-enabled/default
fi

# Проверка конфигурации Nginx
log "Проверка конфигурации Nginx..."
nginx -t || error "Ошибка в конфигурации Nginx."

# Перезапуск Nginx
log "Перезапуск Nginx..."
systemctl restart nginx || error "Не удалось перезапустить Nginx."

# Установка Certbot для Let's Encrypt
log "Установка Certbot для Let's Encrypt..."
apt install -y certbot python3-certbot-nginx || error "Не удалось установить Certbot."

# Получение SSL сертификата
log "Получение SSL сертификата от Let's Encrypt..."
certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --non-interactive --agree-tos --email ${EMAIL} --redirect || warning "Не удалось получить SSL сертификат. Возможно, проблемы с DNS или доступом к домену."

# Проверяем успешность установки сертификата
if [ -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
    log "SSL-сертификат успешно установлен."
    
    # Добавляем улучшенные настройки HTTPS
    log "Настройка оптимизированной HTTPS конфигурации..."
    
    # Создаем файл с оптимизированными параметрами SSL
    cat > /etc/nginx/conf.d/ssl-params.conf << EOF
# Оптимизированные параметры SSL
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;

# Современные настройки безопасности
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;

# OCSP stapling
ssl_stapling on;
ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;

# Заголовки безопасности
add_header Strict-Transport-Security "max-age=63072000" always;
add_header X-Content-Type-Options nosniff;
add_header X-Frame-Options SAMEORIGIN;
add_header X-XSS-Protection "1; mode=block";
EOF

    log "Проверка обновленной конфигурации Nginx..."
    nginx -t || warning "Ошибка в обновленной конфигурации Nginx. Откатываемся к базовой конфигурации."
    
    log "Перезагрузка Nginx с новыми параметрами..."
    systemctl restart nginx || warning "Не удалось перезапустить Nginx с новыми параметрами."
    
    # Добавляем настройки для WordPress в контейнере для работы с HTTPS
    log "Проверка настроек WordPress для HTTPS..."
    echo ""
    log "ВАЖНО: После настройки Nginx и Let's Encrypt, не забудьте настроить WordPress для корректной работы с HTTPS:"
    echo "1. Войдите в админ-панель WordPress"
    echo "2. Перейдите в 'Настройки' -> 'Общие'"
    echo "3. Измените 'Адрес WordPress (URL)' и 'Адрес сайта (URL)' на https://${DOMAIN}"
    echo "4. Сохраните изменения"
else
    warning "SSL-сертификат не был установлен. Проверьте логи и DNS-настройки."
fi

# Настройка автообновления сертификатов
log "Настройка автоматического обновления сертификатов..."
echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" > /etc/cron.d/certbot-renew
chmod 644 /etc/cron.d/certbot-renew

# Настройка брандмауэра
log "Настройка брандмауэра..."
if command -v ufw &>/dev/null; then
    ufw allow 'Nginx Full' || warning "Не удалось настроить UFW."
    ufw allow ssh || warning "Не удалось открыть SSH порт в UFW."
    # Включаем UFW, если он еще не включен
    if ! ufw status | grep -q "Status: active"; then
        ufw --force enable || warning "Не удалось включить UFW."
    fi
else
    warning "UFW не установлен. Рекомендуется установить и настроить брандмауэр."
fi

log "Установка и настройка завершена!"
log "WordPress доступен по адресу: https://${DOMAIN}"

# Проверка WordPress-контейнера
if docker ps | grep -q "${WP_CONTAINER_NAME}"; then
    log "WordPress контейнер ${WP_CONTAINER_NAME} запущен и готов к работе."
else
    warning "WordPress контейнер ${WP_CONTAINER_NAME} не найден или не запущен."
    log "Убедитесь, что Docker-контейнер с WordPress запущен и работает на порту ${WP_CONTAINER_PORT}."
fi

cat << EOF

${GREEN}=== Дополнительная информация ===${NC}
1. Убедитесь, что DNS записи для ${DOMAIN} и www.${DOMAIN} корректно настроены и указывают на IP адрес вашего сервера
2. Проверьте, что WordPress контейнер запущен и доступен по адресу localhost:${WP_CONTAINER_PORT}
3. Если есть проблемы с доступом к WordPress, проверьте логи:
   - Nginx: /var/log/nginx/error.log
   - Let's Encrypt: /var/log/letsencrypt/letsencrypt.log

${YELLOW}=== Важно ===${NC}
Чтобы проверить SSL сертификаты:
  certbot certificates

Для обновления сертификатов вручную:
  certbot renew --dry-run

Для просмотра логов Nginx:
  tail -f /var/log/nginx/access.log
  tail -f /var/log/nginx/error.log

EOF
