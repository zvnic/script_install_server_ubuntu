#!/usr/bin/env bash
#
# Установка Docker CE на Ubuntu 24.04 LTS из официального apt-репозитория Docker.
# Идемпотентно: повторный запуск не ломает систему.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Целевой пользователь для группы docker (под sudo $USER = root, поэтому берём вызвавшего)
TARGET_USER="${SUDO_USER:-$USER}"

# Проверка root
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Запустите с правами root: sudo $0" >&2
    exit 1
fi

# Если Docker уже установлен — выходим
if command -v docker &>/dev/null; then
    echo "Docker уже установлен: $(docker --version)"
    exit 0
fi

echo "Удаление возможных старых/конфликтующих пакетов..."
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y "$pkg" 2>/dev/null || true
done

echo "Установка зависимостей..."
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl

echo "Добавление GPG-ключа Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "Подключение репозитория Docker..."
ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
cat > /etc/apt/sources.list.d/docker.list << EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF

echo "Установка Docker Engine + плагинов..."
apt-get update -y
apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "Включение и запуск службы Docker..."
systemctl enable --now docker

# Добавление пользователя в группу docker (если это не root)
if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
    usermod -aG docker "$TARGET_USER"
    echo "Пользователь $TARGET_USER добавлен в группу docker."
    echo "Перезайдите в сессию или выполните 'newgrp docker' для применения."
fi

echo "✅ Docker установлен: $(docker --version)"
echo "✅ Compose: $(docker compose version)"
