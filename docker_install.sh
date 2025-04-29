#!/bin/bash

set -e

# Установка Docker
curl -sSL https://get.docker.com | sh

# Добавление текущего пользователя в группу docker
sudo usermod -aG docker "$USER"

echo "Docker установлен, пользователь $USER добавлен в группу docker."
echo "Перезагрузите терминал или выполните 'newgrp docker' для применения."
