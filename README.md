# Скрипты настройки Ubuntu 24.04 LTS Server

Набор bash-скриптов для быстрой и безопасной настройки Ubuntu 24.04 LTS серверов:

| Скрипт | Назначение |
|--------|------------|
| [`start_server.sh`](start_server.sh) | Модульная первоначальная настройка и хардненинг сервера |
| [`docker_install.sh`](docker_install.sh) | Установка Docker CE из официального репозитория |
| [`install_nginx_letsencrypt_wordpress.sh`](install_nginx_letsencrypt_wordpress.sh) | Nginx + Let's Encrypt как reverse-proxy для WordPress в Docker |

Основной скрипт `start_server.sh` — модульный, с возможностью выборочной установки компонентов.

## Возможности

- 🔄 **Модульная структура** — включайте только нужные компоненты 
- 🔒 **Безопасность** — настройка SSH, брандмауэра, Fail2Ban и других средств защиты
- 📊 **Мониторинг** — установка систем аудита и отслеживания безопасности
- 🔄 **Автоматизация** — настройка автообновлений и резервного копирования
- 📝 **Детальное логирование** — все операции записываются в лог

## Быстрый старт

```bash
# 1. Загрузка скрипта (raw-ссылка на сырой файл, не на страницу GitHub)
curl -fsSLO https://raw.githubusercontent.com/zvnic/script_install_server_ubuntu/main/start_server.sh
# или через wget:
# wget https://raw.githubusercontent.com/zvnic/script_install_server_ubuntu/main/start_server.sh

# 2. Настройка прав на выполнение
chmod +x start_server.sh

# 3. (опционально) Отредактируйте флаги модулей и параметры в начале файла
nano start_server.sh

# 4. Запуск с правами администратора
sudo ./start_server.sh
```

> ⚠️ Старая ссылка вида `github.com/.../blob/main/...` отдаёт HTML-страницу, а не сам скрипт — используйте `raw.githubusercontent.com`.

## Настройка модулей

Откройте скрипт любым текстовым редактором и в начале файла измените настройки модулей:

```bash
# Включение (1) или отключение (0) модулей
ENABLE_UPDATE=1             # Обновление системы
ENABLE_CREATE_USER=1        # Создание пользователя
ENABLE_SSH_CONFIG=1         # Настройка SSH
ENABLE_BACKUP=0             # Настройка резервного копирования
# ... и другие модули
```

## Доступные модули

| Модуль | Описание |
|--------|----------|
| `UPDATE` | Обновление пакетов системы |
| `CREATE_USER` | Создание нового пользователя с правами sudo |
| `SSH_CONFIG` | Защищенная настройка SSH |
| `FIREWALL` | Настройка файрвола UFW |
| `FAIL2BAN` | Fail2Ban на systemd-backend (взаимоисключаемо с CrowdSec) |
| `CROWDSEC` | Установка CrowdSec (альтернатива Fail2Ban) |
| `SYSCTL_HARDENING` | Хардненинг ядра через `/etc/sysctl.d/` |
| `LYNIS` | Установка Lynis для аудита безопасности |
| `AUTO_UPDATES` | Автоматические обновления безопасности + авто-reboot 02:00 |
| `LOGWATCH` | Мониторинг логов (требует настроенного MTA) |
| `BACKUP` | Резервное копирование через restic + systemd timer |
| `TIMEZONE` | Часовой пояс и NTP (systemd-timesyncd или chrony) |
| `AUDIT` | Установка auditd для аудита системы |
| `RKHUNTER` | Установка rootkit hunter |
| `APPARMOR` | Проверка статуса AppArmor (в 24.04 включён по умолчанию) |

## Настройка параметров

Вы можете настроить основные параметры в начале скрипта:

```bash
SSH_PORT=2222                       # Порт SSH
NEW_USER="master"                   # Имя нового пользователя
TIMEZONE="Europe/Moscow"            # Часовой пояс
USE_CHRONY=0                        # 1 = chrony, 0 = встроенный systemd-timesyncd
ALLOW_HTTP=1                        # Открыть порты 80/443 в файрволе
BACKUP_REPO="/var/backups/restic"   # Репозиторий restic для бэкапов
NONINTERACTIVE=0                    # 1 = без вопросов (CI/автоматизация)

# SSH-ключ нового пользователя (любой непустой вариант):
PUBKEY=""                           # содержимое ключа напрямую
PUBKEY_SRC=""                       # путь/URL до файла, напр. https://github.com/USER.keys
```

> 🔑 **Защита от блокировки:** если ключ не задан (`PUBKEY`/`PUBKEY_SRC`) и `authorized_keys` пуст, скрипт НЕ отключит парольный вход, чтобы вы не потеряли доступ к серверу.

## Логирование

Все действия скрипта записываются в файл `/var/log/server_setup.log`, что позволяет отслеживать процесс настройки и диагностировать возможные проблемы.

## После настройки

После завершения работы скрипта рекомендуется перезагрузить сервер и проверить работоспособность всех настроенных компонентов:

```bash
# Проверка статуса файрвола
sudo ufw status

# Проверка статуса Fail2Ban
sudo fail2ban-client status

# Проверка службы автообновлений
systemctl status unattended-upgrades
```

## Безопасность

- Убедитесь, что вы добавили SSH-ключи перед отключением аутентификации по паролю
- После настройки SSH проверьте доступ через новый порт перед закрытием текущей сессии
- Сохраните настройки доступа в надежном месте

## Дополнительные скрипты

### Docker (`docker_install.sh`)

Устанавливает Docker CE из официального apt-репозитория (Engine, CLI, containerd, buildx и compose-plugin). Идемпотентен — повторный запуск ничего не ломает.

```bash
curl -fsSLO https://raw.githubusercontent.com/zvnic/script_install_server_ubuntu/main/docker_install.sh
chmod +x docker_install.sh
sudo ./docker_install.sh
```

После установки перезайдите в сессию (или `newgrp docker`), чтобы применить членство в группе `docker`. Команда Compose — `docker compose` (v2).

### Nginx + Let's Encrypt для WordPress (`install_nginx_letsencrypt_wordpress.sh`)

Настраивает Nginx как reverse-proxy с TLS-сертификатом Let's Encrypt для WordPress, запущенного в Docker-контейнере. Домен и email задаются аргументами или переменными окружения (без правки файла).

```bash
curl -fsSLO https://raw.githubusercontent.com/zvnic/script_install_server_ubuntu/main/install_nginx_letsencrypt_wordpress.sh
chmod +x install_nginx_letsencrypt_wordpress.sh

# аргументами: <домен> <email> [порт_контейнера]
sudo ./install_nginx_letsencrypt_wordpress.sh example.com admin@example.com 8080

# или через переменные окружения:
sudo DOMAIN=example.com EMAIL=admin@example.com WP_CONTAINER_PORT=8080 \
    ./install_nginx_letsencrypt_wordpress.sh
```

Параметры:

| Параметр | По умолчанию | Описание |
|----------|--------------|----------|
| `DOMAIN` | — (обязателен) | Домен сайта |
| `EMAIL` | — (обязателен) | Email для Let's Encrypt |
| `WP_CONTAINER_PORT` | `8080` | Порт WordPress-контейнера на `127.0.0.1` |
| `WP_CONTAINER_NAME` | `wordpress` | Имя Docker-контейнера для проверки |
| `INCLUDE_WWW` | `1` | Выпускать сертификат и на `www.<домен>` (если есть DNS) |

**Перед запуском** убедитесь, что DNS-запись домена указывает на IP сервера, а WordPress-контейнер слушает `127.0.0.1:<порт>`. Автообновление сертификатов работает через штатный `certbot.timer` (отдельный cron не создаётся).
