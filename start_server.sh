#!/usr/bin/env bash
#
# Модульный скрипт первоначальной настройки Ubuntu 24.04 LTS Server.
# Каждый модуль включается (1) / отключается (0) флагом ниже.
#
# Особенности (под Ubuntu 24.04):
#   * SSH настраивается через drop-in /etc/ssh/sshd_config.d/ + корректная
#     обработка ssh.socket (socket-activation), иначе смена порта не работает;
#   * защита от блокировки: пароль не отключается, пока нет SSH-ключа;
#   * set -euo pipefail + trap, DEBIAN_FRONTEND, needrestart в авто-режиме;
#   * fail2ban на systemd-backend;
#   * sysctl-хардненинг ядра;
#   * идемпотентность (повторный запуск безопасен);
#   * опционально restic вместо tar для бэкапов.

set -euo pipefail

# ======== НАСТРОЙКИ МОДУЛЕЙ ========
ENABLE_UPDATE=1             # Обновление системы
ENABLE_CREATE_USER=1        # Создание пользователя
ENABLE_SSH_CONFIG=1         # Настройка/хардненинг SSH
ENABLE_FIREWALL=1           # Настройка UFW (файрвол)
ENABLE_FAIL2BAN=1           # Установка и настройка Fail2Ban
ENABLE_CROWDSEC=0           # CrowdSec (взаимоисключающе с Fail2Ban)
ENABLE_SYSCTL_HARDENING=1   # Хардненинг ядра через sysctl
ENABLE_LYNIS=1              # Lynis (аудит безопасности)
ENABLE_AUTO_UPDATES=1       # Автоматические обновления безопасности
ENABLE_LOGWATCH=0           # Logwatch (требует настроенного MTA)
ENABLE_BACKUP=0             # Резервное копирование (restic)
ENABLE_TIMEZONE=1           # Часовой пояс и NTP
ENABLE_AUDIT=0              # auditd (аудит системы)
ENABLE_RKHUNTER=0           # rootkit hunter
ENABLE_APPARMOR=1           # Проверка статуса AppArmor (в 24.04 включён по умолч.)

# ======== НАСТРАИВАЕМЫЕ ПАРАМЕТРЫ ========
SSH_PORT=2222                       # Порт SSH
NEW_USER="master"                   # Имя нового пользователя
TIMEZONE="Europe/Moscow"            # Часовой пояс
USE_CHRONY=0                        # 1 = chrony, 0 = встроенный systemd-timesyncd
ALLOW_HTTP=1                        # Открыть 80/443 в файрволе
BACKUP_REPO="/var/backups/restic"   # Репозиторий restic (локальный путь или удалённый)
NONINTERACTIVE=0                    # 1 = не задавать вопросов (CI/автоматизация)

# Источник публичного SSH-ключа для нового пользователя (любой непустой):
#   * прямое содержимое ключа в PUBKEY, или
#   * путь/URL до файла с ключами в PUBKEY_SRC (например, https://github.com/USER.keys)
PUBKEY=""
PUBKEY_SRC=""

# ======== СЛУЖЕБНОЕ ========
export DEBIAN_FRONTEND=noninteractive
# needrestart в неинтерактивный режим, чтобы apt не подвисал на диалогах (24.04)
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

LOG_FILE="/var/log/server_setup.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Глобальный обработчик ошибок: фиксируем строку и команду, но не валимся молча
trap 'log "❌ ОШИБКА на строке $LINENO (команда: ${BASH_COMMAND}). Выход."' ERR

# Запрос подтверждения с учётом неинтерактивного режима
confirm() {
    # $1 — текст вопроса, $2 — действие по умолчанию в NONINTERACTIVE (y/n)
    local prompt="$1" default="${2:-n}"
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        [[ "$default" == "y" ]]
        return
    fi
    local choice
    read -rp "$prompt (y/n): " choice
    [[ "$choice" == "y" ]]
}

apt_install() {
    apt-get install -y --no-install-recommends "$@"
}

# Проверка root
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Этот скрипт должен быть запущен с правами root. Используйте: sudo $0" >&2
    exit 1
fi

# Проверка версии ОС (мягкая)
if ! grep -q 'VERSION_ID="24.04"' /etc/os-release 2>/dev/null; then
    log "⚠️ Скрипт рассчитан на Ubuntu 24.04. Текущая версия отличается — продолжаем с осторожностью."
fi

touch "$LOG_FILE"
log "=== Начало настройки сервера Ubuntu 24.04 LTS ==="

# ======== МОДУЛЬ 1: ОБНОВЛЕНИЕ СИСТЕМЫ ========
if [[ "$ENABLE_UPDATE" -eq 1 ]]; then
    log "МОДУЛЬ 1: Обновление системы..."
    apt-get update -y
    apt-get upgrade -y
    apt-get autoremove -y
    apt-get autoclean -y
    log "✅ Система обновлена"
fi

# ======== МОДУЛЬ 2: СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ========
if [[ "$ENABLE_CREATE_USER" -eq 1 ]]; then
    log "МОДУЛЬ 2: Создание пользователя $NEW_USER..."

    if id "$NEW_USER" &>/dev/null; then
        log "Пользователь $NEW_USER уже существует — пропускаем создание"
    else
        # --disabled-password: вход только по ключу; пароль при необходимости задайте позже
        adduser --disabled-password --gecos "" "$NEW_USER"
        usermod -aG sudo "$NEW_USER"
        log "✅ Пользователь $NEW_USER создан и добавлен в sudo"
    fi

    USER_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
    install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$USER_HOME/.ssh"
    AUTH_KEYS="$USER_HOME/.ssh/authorized_keys"
    touch "$AUTH_KEYS"

    # Установка ключа из PUBKEY / PUBKEY_SRC, если задан и его ещё нет
    install_key() {
        local key="$1"
        [[ -z "$key" ]] && return 0
        grep -qF "$key" "$AUTH_KEYS" 2>/dev/null || echo "$key" >> "$AUTH_KEYS"
    }
    if [[ -n "$PUBKEY" ]]; then
        install_key "$PUBKEY"
        log "✅ SSH-ключ из PUBKEY добавлен"
    fi
    if [[ -n "$PUBKEY_SRC" ]]; then
        if [[ "$PUBKEY_SRC" =~ ^https?:// ]]; then
            apt_install curl
            while IFS= read -r k; do install_key "$k"; done < <(curl -fsSL "$PUBKEY_SRC")
        elif [[ -f "$PUBKEY_SRC" ]]; then
            while IFS= read -r k; do install_key "$k"; done < "$PUBKEY_SRC"
        fi
        log "✅ SSH-ключи из PUBKEY_SRC добавлены"
    fi

    chmod 600 "$AUTH_KEYS"
    chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"

    if [[ ! -s "$AUTH_KEYS" ]]; then
        log "📝 ВАЖНО: в $AUTH_KEYS нет ключей. Добавьте их до отключения парольного входа."
    fi
fi

# ======== МОДУЛЬ 3: НАСТРОЙКА И ХАРДНЕНИНГ SSH ========
if [[ "$ENABLE_SSH_CONFIG" -eq 1 ]]; then
    log "МОДУЛЬ 3: Настройка SSH..."

    # --- Защита от блокировки: проверяем наличие ключа у целевого пользователя ---
    KEY_PRESENT=0
    for h in "/home/$NEW_USER/.ssh/authorized_keys" "/root/.ssh/authorized_keys"; do
        [[ -s "$h" ]] && KEY_PRESENT=1
    done

    DISABLE_PASSWORD="yes"
    if [[ "$KEY_PRESENT" -eq 0 ]]; then
        log "⚠️ SSH-ключи не найдены ни у $NEW_USER, ни у root."
        if confirm "Отключить парольный вход всё равно? (РИСК БЛОКИРОВКИ)" "n"; then
            DISABLE_PASSWORD="yes"
        else
            DISABLE_PASSWORD="no"
            log "Парольная аутентификация ОСТАВЛЕНА включённой во избежание блокировки."
        fi
    fi

    # --- Drop-in конфиг (modern way, Ubuntu подключает sshd_config.d/*.conf) ---
    SSHD_DROPIN="/etc/ssh/sshd_config.d/99-hardening.conf"
    {
        echo "# Создано start_server_v2.sh — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Port ${SSH_PORT}"
        echo "PermitRootLogin no"
        echo "PubkeyAuthentication yes"
        echo "PasswordAuthentication ${DISABLE_PASSWORD/yes/no}"
        # для DISABLE_PASSWORD=no выводим yes
        echo "KbdInteractiveAuthentication ${DISABLE_PASSWORD/yes/no}"
        echo "MaxAuthTries 4"
        echo "LoginGraceTime 30"
        echo "X11Forwarding no"
        echo "AllowAgentForwarding no"
        echo "ClientAliveInterval 300"
        echo "ClientAliveCountMax 2"
    } > "$SSHD_DROPIN"
    # Корректируем PasswordAuthentication/KbdInteractive при DISABLE_PASSWORD=no
    if [[ "$DISABLE_PASSWORD" == "no" ]]; then
        sed -i 's/^PasswordAuthentication .*/PasswordAuthentication yes/' "$SSHD_DROPIN"
        sed -i 's/^KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/' "$SSHD_DROPIN"
    fi

    # Проверка синтаксиса до применения
    if ! sshd -t; then
        log "❌ sshd -t выявил ошибку конфигурации. Drop-in удаляем, SSH не трогаем."
        rm -f "$SSHD_DROPIN"
    else
        # --- Socket-activation: на 24.04 порт задаёт ssh.socket, а не sshd_config ---
        if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
            log "Обнаружен ssh.socket — отключаем socket-activation, чтобы порт из конфига применился"
            systemctl disable --now ssh.socket || true
            systemctl enable ssh.service
        fi

        log "⚠️ SSH будет слушать порт $SSH_PORT; root-вход запрещён; пароль: ${DISABLE_PASSWORD/yes/откл}"
        if confirm "Перезапустить SSH сейчас?" "y"; then
            systemctl restart ssh
            log "✅ SSH перезапущен на порту $SSH_PORT"
        else
            log "Перезапуск SSH отложен. Выполните вручную: sudo systemctl restart ssh"
        fi
    fi
fi

# ======== МОДУЛЬ 4: ФАЙРВОЛ UFW ========
if [[ "$ENABLE_FIREWALL" -eq 1 ]]; then
    log "МОДУЛЬ 4: Настройка файрвола UFW..."
    apt_install ufw

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT/tcp" comment 'SSH'
    if [[ "$ALLOW_HTTP" -eq 1 ]]; then
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
    fi

    log "⚠️ Будут открыты: $SSH_PORT (SSH)$([[ $ALLOW_HTTP -eq 1 ]] && echo ', 80, 443')"
    if confirm "Включить UFW сейчас?" "y"; then
        ufw --force enable
        ufw status verbose | tee -a "$LOG_FILE"
        log "✅ UFW включён"
    else
        log "Активация UFW отложена. Выполните вручную: sudo ufw enable"
    fi
fi

# ======== МОДУЛЬ 5: FAIL2BAN ========
if [[ "$ENABLE_FAIL2BAN" -eq 1 && "$ENABLE_CROWDSEC" -eq 1 ]]; then
    log "⚠️ Включены и Fail2Ban, и CrowdSec — они конфликтуют за SSH-jail. Fail2Ban пропускаем."
elif [[ "$ENABLE_FAIL2BAN" -eq 1 ]]; then
    log "МОДУЛЬ 5: Установка и настройка Fail2Ban..."
    apt_install fail2ban

    # systemd-backend: читаем journald, не зависим от наличия /var/log/auth.log
    cat > /etc/fail2ban/jail.d/sshd.local << EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd
maxretry = 3
findtime = 600
bantime  = 3600
EOF

    systemctl enable --now fail2ban
    systemctl restart fail2ban
    sleep 1
    fail2ban-client status sshd 2>/dev/null | tee -a "$LOG_FILE" || true
    log "✅ Fail2Ban настроен (backend=systemd, порт $SSH_PORT)"
fi

# ======== МОДУЛЬ 6: CROWDSEC ========
if [[ "$ENABLE_CROWDSEC" -eq 1 ]]; then
    log "МОДУЛЬ 6: Установка CrowdSec..."
    apt_install curl
    curl -s https://install.crowdsec.net | bash
    apt_install crowdsec crowdsec-firewall-bouncer-iptables
    systemctl enable --now crowdsec
    cscli metrics 2>/dev/null | tee -a "$LOG_FILE" || true
    log "✅ CrowdSec установлен"
fi

# ======== МОДУЛЬ 7: SYSCTL-ХАРДНЕНИНГ ========
if [[ "$ENABLE_SYSCTL_HARDENING" -eq 1 ]]; then
    log "МОДУЛЬ 7: Хардненинг ядра через sysctl..."
    cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# Сетевая защита
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
# Ядро
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
    sysctl --system >/dev/null
    log "✅ Параметры ядра применены (/etc/sysctl.d/99-hardening.conf)"
fi

# ======== МОДУЛЬ 8: LYNIS ========
if [[ "$ENABLE_LYNIS" -eq 1 ]]; then
    log "МОДУЛЬ 8: Установка Lynis..."
    apt_install lynis
    log "Запуск аудита: sudo lynis audit system"
    if confirm "Запустить аудит Lynis сейчас?" "n"; then
        lynis audit system || true
    fi
fi

# ======== МОДУЛЬ 9: АВТОМАТИЧЕСКИЕ ОБНОВЛЕНИЯ ========
if [[ "$ENABLE_AUTO_UPDATES" -eq 1 ]]; then
    log "МОДУЛЬ 9: Настройка автоматических обновлений безопасности..."
    apt_install unattended-upgrades apt-listchanges

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # Включаем -updates/-security и авто-перезагрузку в 02:00
    UU=/etc/apt/apt.conf.d/50unattended-upgrades
    sed -i 's|//\s*"${distro_id}:${distro_codename}-updates";|"${distro_id}:${distro_codename}-updates";|' "$UU"
    sed -i 's|//\s*"${distro_id}:${distro_codename}-security";|"${distro_id}:${distro_codename}-security";|' "$UU"
    sed -i 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|' "$UU"
    sed -i 's|//Unattended-Upgrade::Automatic-Reboot-Time "02:00";|Unattended-Upgrade::Automatic-Reboot-Time "02:00";|' "$UU"

    systemctl enable --now unattended-upgrades
    systemctl restart unattended-upgrades
    log "✅ Автообновления включены (security+updates, авто-reboot 02:00)"
fi

# ======== МОДУЛЬ 10: LOGWATCH ========
if [[ "$ENABLE_LOGWATCH" -eq 1 ]]; then
    log "МОДУЛЬ 10: Установка Logwatch..."
    apt_install logwatch
    mkdir -p /etc/logwatch/conf
    cat > /etc/logwatch/conf/logwatch.conf << 'EOF'
Output = mail
Format = html
MailTo = root
Range = yesterday
Detail = High
Service = All
EOF
    log "⚠️ Logwatch шлёт почту на root. Без настроенного MTA (postfix/msmtp) отчёты НЕ дойдут."
fi

# ======== МОДУЛЬ 11: РЕЗЕРВНОЕ КОПИРОВАНИЕ (restic) ========
if [[ "$ENABLE_BACKUP" -eq 1 ]]; then
    log "МОДУЛЬ 11: Настройка резервного копирования (restic)..."
    apt_install restic

    if [[ ! -f /etc/restic.env ]]; then
        # ВНИМАНИЕ: задайте надёжный пароль репозитория и храните его отдельно!
        cat > /etc/restic.env << EOF
export RESTIC_REPOSITORY="${BACKUP_REPO}"
export RESTIC_PASSWORD="CHANGE_ME_strong_password"
EOF
        chmod 600 /etc/restic.env
        log "⚠️ Задайте RESTIC_PASSWORD в /etc/restic.env (сейчас плейсхолдер!)"
    fi

    cat > /usr/local/bin/backup.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/restic.env
# Инициализация репозитория при первом запуске
restic snapshots >/dev/null 2>&1 || restic init
restic backup /etc /home --tag system
# Политика хранения: 7 дней, 4 недели, 6 месяцев
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
echo "Backup OK: $(date)"
EOF
    chmod +x /usr/local/bin/backup.sh

    # systemd timer вместо cron (логи в journald, управляемость)
    cat > /etc/systemd/system/backup.service << 'EOF'
[Unit]
Description=Restic system backup

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup.sh
EOF
    cat > /etc/systemd/system/backup.timer << 'EOF'
[Unit]
Description=Daily restic backup at 02:00

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now backup.timer
    log "✅ Бэкап (restic) настроен: ежедневно в 02:00 через systemd timer"
fi

# ======== МОДУЛЬ 12: ЧАСОВОЙ ПОЯС И NTP ========
if [[ "$ENABLE_TIMEZONE" -eq 1 ]]; then
    log "МОДУЛЬ 12: Часовой пояс и NTP..."
    timedatectl set-timezone "$TIMEZONE"

    if [[ "$USE_CHRONY" -eq 1 ]]; then
        apt_install chrony
        systemctl enable --now chrony
        log "✅ Часовой пояс $TIMEZONE, синхронизация через chrony"
    else
        # systemd-timesyncd встроен в 24.04
        timedatectl set-ntp true
        log "✅ Часовой пояс $TIMEZONE, синхронизация через systemd-timesyncd"
    fi
fi

# ======== МОДУЛЬ 13: AUDITD ========
if [[ "$ENABLE_AUDIT" -eq 1 ]]; then
    log "МОДУЛЬ 13: Установка auditd..."
    apt_install auditd audispd-plugins
    systemctl enable --now auditd
    log "✅ auditd запущен (отчёт: sudo aureport)"
fi

# ======== МОДУЛЬ 14: ROOTKIT HUNTER ========
if [[ "$ENABLE_RKHUNTER" -eq 1 ]]; then
    log "МОДУЛЬ 14: Установка rkhunter..."
    apt_install rkhunter
    rkhunter --update || true
    rkhunter --propupd
    if confirm "Запустить проверку rkhunter сейчас?" "n"; then
        rkhunter --check --skip-keypress || true
    fi
    log "✅ rkhunter установлен (проверка: sudo rkhunter --check)"
fi

# ======== МОДУЛЬ 15: APPARMOR ========
if [[ "$ENABLE_APPARMOR" -eq 1 ]]; then
    log "МОДУЛЬ 15: Проверка AppArmor..."
    apt_install apparmor-utils
    aa-status | head -n 5 | tee -a "$LOG_FILE" || true
    log "✅ AppArmor активен (в Ubuntu 24.04 включён по умолчанию)"
fi

# ======== ЗАВЕРШЕНИЕ ========
log "🎉 Настройка сервера завершена!"
log "Лог: cat $LOG_FILE"
log "ПРОВЕРЬТЕ доступ по SSH в НОВОЙ сессии (порт $SSH_PORT) до закрытия текущей!"

if confirm "Перезагрузить сервер сейчас?" "n"; then
    log "Перезагрузка..."
    reboot
else
    log "Перезагрузка отложена. Не забудьте перезагрузить позже."
fi

exit 0
