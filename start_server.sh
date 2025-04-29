#!/bin/bash

# Модульный скрипт настройки Ubuntu 24.04 LTS Server
# Каждый модуль может быть включен (1) или отключен (0)

# ======== НАСТРОЙКИ МОДУЛЕЙ ========
# Измените значение на 0, чтобы отключить модуль
ENABLE_UPDATE=1             # Обновление системы
ENABLE_CREATE_USER=1        # Создание пользователя master
ENABLE_SSH_CONFIG=1         # Настройка SSH
ENABLE_FIREWALL=1           # Настройка UFW (файрвол)
ENABLE_FAIL2BAN=1           # Установка и настройка Fail2Ban
ENABLE_CROWDSEC=0           # Установка CrowdSec (альтернатива Fail2Ban)
ENABLE_LYNIS=1              # Установка Lynis для аудита безопасности
ENABLE_AUTO_UPDATES=1       # Настройка автоматических обновлений
ENABLE_LOGWATCH=1           # Установка и настройка Logwatch
ENABLE_BACKUP=0             # Настройка резервного копирования
ENABLE_TIMEZONE=1           # Настройка часового пояса и NTP
ENABLE_AUDIT=0              # Установка auditd для аудита системы
ENABLE_RKHUNTER=0           # Установка rootkit hunter
ENABLE_APPARMOR=0           # Настройка AppArmor

# ======== НАСТРАИВАЕМЫЕ ПАРАМЕТРЫ ========
SSH_PORT=2222               # Порт SSH
NEW_USER="master"           # Имя нового пользователя
TIMEZONE="Europe/Moscow"    # Часовой пояс (измените на свой)
BACKUP_DIR="/var/backups/system"  # Директория для бэкапов

# Функция для логирования
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a /var/log/server_setup.log
}

# Функция проверки успешного выполнения команды
check_status() {
    if [ $? -eq 0 ]; then
        log "✅ $1"
    else
        log "❌ $1 - ОШИБКА!"
        read -p "Продолжить выполнение? (y/n): " choice
        if [[ "$choice" != "y" ]]; then
            log "Скрипт остановлен пользователем."
            exit 1
        fi
    fi
}

# Проверка запуска от имени root
if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен с правами root."
    echo "Используйте: sudo $0"
    exit 1
fi

# Создание лог-файла
touch /var/log/server_setup.log
log "Начало настройки сервера Ubuntu 24.04 LTS"

# ======== МОДУЛЬ 1: ОБНОВЛЕНИЕ СИСТЕМЫ ========
if [ "$ENABLE_UPDATE" -eq 1 ]; then
    log "МОДУЛЬ 1: Обновление системы..."
    apt update
    check_status "Обновление списка пакетов"
    
    apt upgrade -y
    check_status "Обновление пакетов"
    
    apt autoremove -y
    check_status "Удаление неиспользуемых пакетов"
fi

# ======== МОДУЛЬ 2: СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ========
if [ "$ENABLE_CREATE_USER" -eq 1 ]; then
    log "МОДУЛЬ 2: Создание пользователя $NEW_USER..."
    
    # Проверка существования пользователя
    if id "$NEW_USER" &>/dev/null; then
        log "Пользователь $NEW_USER уже существует"
    else
        adduser --gecos "" $NEW_USER
        check_status "Создание пользователя $NEW_USER"
        
        usermod -aG sudo $NEW_USER
        check_status "Добавление пользователя $NEW_USER в группу sudo"
        
        # Создание директории .ssh
        mkdir -p /home/$NEW_USER/.ssh
        touch /home/$NEW_USER/.ssh/authorized_keys
        chmod 700 /home/$NEW_USER/.ssh
        chmod 600 /home/$NEW_USER/.ssh/authorized_keys
        chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh
        
        log "📝 ВАЖНО: Добавьте SSH-ключи в /home/$NEW_USER/.ssh/authorized_keys"
    fi
fi

# ======== МОДУЛЬ 3: НАСТРОЙКА SSH ========
if [ "$ENABLE_SSH_CONFIG" -eq 1 ]; then
    log "МОДУЛЬ 3: Настройка SSH..."
    
    # Создание резервной копии
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    
    # Настройка SSH
    sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
    sed -i "s/^#PermitRootLogin prohibit-password/PermitRootLogin no/" /etc/ssh/sshd_config
    sed -i "s/^#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#PubkeyAuthentication yes/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    
    log "⚠️ SSH будет настроен на порт $SSH_PORT с отключенной аутентификацией по паролю"
    log "⚠️ Убедитесь, что вы добавили SSH-ключи перед перезапуском службы SSH"
    
    read -p "Перезапустить SSH сейчас? (y/n): " restart_ssh
    if [[ "$restart_ssh" == "y" ]]; then
        systemctl restart sshd
        check_status "Перезапуск службы SSH"
    else
        log "Перезапуск SSH отложен. Выполните вручную: sudo systemctl restart sshd"
    fi
fi

# ======== МОДУЛЬ 4: НАСТРОЙКА ФАЙРВОЛА UFW ========
if [ "$ENABLE_FIREWALL" -eq 1 ]; then
    log "МОДУЛЬ 4: Настройка файрвола UFW..."
    
    apt install ufw -y
    check_status "Установка UFW"
    
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow $SSH_PORT/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    log "⚠️ Файрвол будет включен. Открыты порты: $SSH_PORT (SSH), 80 (HTTP), 443 (HTTPS)"
    
    read -p "Включить файрвол UFW сейчас? (y/n): " enable_ufw
    if [[ "$enable_ufw" == "y" ]]; then
        echo "y" | ufw enable
        check_status "Включение UFW"
        ufw status
    else
        log "Активация UFW отложена. Выполните вручную: sudo ufw enable"
    fi
fi

# ======== МОДУЛЬ 5: НАСТРОЙКА FAIL2BAN ========
if [ "$ENABLE_FAIL2BAN" -eq 1 ]; then
    log "МОДУЛЬ 5: Установка и настройка Fail2Ban..."
    
    apt install fail2ban -y
    check_status "Установка Fail2Ban"
    
    # Настройка Fail2Ban
    if [ ! -f /etc/fail2ban/jail.local ]; then
        cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
        check_status "Создание файла конфигурации jail.local"
        
        # Настройка защиты SSH
        cat > /etc/fail2ban/jail.d/ssh.conf << EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOF
        check_status "Настройка защиты SSH в Fail2Ban"
    else
        log "Файл конфигурации jail.local уже существует"
    fi
    
    systemctl enable fail2ban
    systemctl restart fail2ban
    check_status "Запуск службы Fail2Ban"
    
    fail2ban-client status
fi

# ======== МОДУЛЬ 6: УСТАНОВКА CROWDSEC ========
if [ "$ENABLE_CROWDSEC" -eq 1 ]; then
    log "МОДУЛЬ 6: Установка CrowdSec..."
    
    # Установка curl если его нет
    apt install curl -y
    
    # Установка CrowdSec
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
    check_status "Добавление репозитория CrowdSec"
    
    apt install crowdsec -y
    check_status "Установка CrowdSec"
    
    # Установка бранчера для SSH
    apt install crowdsec-firewall-bouncer-iptables -y
    check_status "Установка фаервол-бранчера CrowdSec"
    
    # Проверка статуса
    cscli metrics
    cscli decisions list
    
    systemctl status crowdsec
fi

# ======== МОДУЛЬ 7: УСТАНОВКА LYNIS ========
if [ "$ENABLE_LYNIS" -eq 1 ]; then
    log "МОДУЛЬ 7: Установка Lynis для аудита безопасности..."
    
    apt install lynis -y
    check_status "Установка Lynis"
    
    log "Для запуска аудита безопасности выполните: sudo lynis audit system"
    
    read -p "Запустить проверку Lynis сейчас? (y/n): " run_lynis
    if [[ "$run_lynis" == "y" ]]; then
        lynis audit system
    fi
fi

# ======== МОДУЛЬ 8: НАСТРОЙКА АВТОМАТИЧЕСКИХ ОБНОВЛЕНИЙ ========
if [ "$ENABLE_AUTO_UPDATES" -eq 1 ]; then
    log "МОДУЛЬ 8: Настройка автоматических обновлений..."
    
    apt install unattended-upgrades apt-listchanges -y
    check_status "Установка unattended-upgrades"
    
    # Настройка автоматических обновлений
    cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
EOF
    check_status "Настройка автоматических обновлений"
    
    # Изменение настройки для включения обновлений безопасности
    sed -i 's|//\s*"${distro_id}:${distro_codename}-updates";|"${distro_id}:${distro_codename}-updates";|' /etc/apt/apt.conf.d/50unattended-upgrades
    sed -i 's|//\s*"${distro_id}:${distro_codename}-security";|"${distro_id}:${distro_codename}-security";|' /etc/apt/apt.conf.d/50unattended-upgrades
    
    # Включение автоматической перезагрузки при необходимости (в 2:00)
    sed -i 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|' /etc/apt/apt.conf.d/50unattended-upgrades
    sed -i 's|//Unattended-Upgrade::Automatic-Reboot-Time "02:00";|Unattended-Upgrade::Automatic-Reboot-Time "02:00";|' /etc/apt/apt.conf.d/50unattended-upgrades
    
    systemctl restart unattended-upgrades
    check_status "Перезапуск службы unattended-upgrades"
fi

# ======== МОДУЛЬ 9: УСТАНОВКА LOGWATCH ========
if [ "$ENABLE_LOGWATCH" -eq 1 ]; then
    log "МОДУЛЬ 9: Установка и настройка Logwatch..."
    
    apt install logwatch -y
    check_status "Установка Logwatch"
    
    # Настройка ежедневной отправки отчетов
    mkdir -p /etc/logwatch/conf
    cat > /etc/logwatch/conf/logwatch.conf << EOF
# Логвотч будет отправлять отчеты каждый день
# Измените email на свой
Output = mail
Format = html
MailTo = root
Range = yesterday
Detail = High
Service = All
EOF
    check_status "Настройка Logwatch"
    
    log "Logwatch настроен. Чтобы получать отчеты на внешний email, настройте пересылку почты root"
fi

# ======== МОДУЛЬ 10: НАСТРОЙКА РЕЗЕРВНОГО КОПИРОВАНИЯ ========
if [ "$ENABLE_BACKUP" -eq 1 ]; then
    log "МОДУЛЬ 10: Настройка резервного копирования..."
    
    apt install rsync -y
    check_status "Установка rsync"
    
    # Создание директории для бэкапов
    mkdir -p $BACKUP_DIR
    check_status "Создание директории для бэкапов: $BACKUP_DIR"
    
    # Создание скрипта для бэкапа
    cat > /usr/local/bin/backup.sh << EOF
#!/bin/bash

# Скрипт резервного копирования системы
BACKUP_DIR="$BACKUP_DIR"
DATE=\$(date +%Y-%m-%d)

# Создание директории если не существует
mkdir -p \$BACKUP_DIR

# Бэкап домашних директорий
tar -czf \$BACKUP_DIR/home-\$DATE.tar.gz /home

# Бэкап конфигураций
tar -czf \$BACKUP_DIR/etc-\$DATE.tar.gz /etc

# Удаление старых бэкапов (старше 30 дней)
find \$BACKUP_DIR -name "*.tar.gz" -type f -mtime +30 -delete

echo "Резервное копирование завершено: \$(date)"
EOF
    chmod +x /usr/local/bin/backup.sh
    check_status "Создание скрипта бэкапа /usr/local/bin/backup.sh"
    
    # Добавление задачи в cron
    echo "0 2 * * * root /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1" > /etc/cron.d/backup
    check_status "Добавление задачи в cron"
    
    log "Резервное копирование настроено. Запуск ежедневно в 2:00"
fi

# ======== МОДУЛЬ 11: НАСТРОЙКА ЧАСОВОГО ПОЯСА И NTP ========
if [ "$ENABLE_TIMEZONE" -eq 1 ]; then
    log "МОДУЛЬ 11: Настройка часового пояса и NTP..."
    
    timedatectl set-timezone $TIMEZONE
    check_status "Установка часового пояса: $TIMEZONE"
    
    apt install chrony -y
    check_status "Установка Chrony (NTP)"
    
    systemctl enable chrony
    systemctl restart chrony
    check_status "Запуск службы Chrony"
    
    chronyc sources
fi

# ======== МОДУЛЬ 12: УСТАНОВКА AUDITD ========
if [ "$ENABLE_AUDIT" -eq 1 ]; then
    log "МОДУЛЬ 12: Установка auditd для аудита системы..."
    
    apt install auditd audispd-plugins -y
    check_status "Установка auditd"
    
    systemctl enable auditd
    systemctl start auditd
    check_status "Запуск службы auditd"
    
    log "auditd установлен. Для просмотра отчета выполните: sudo aureport"
fi

# ======== МОДУЛЬ 13: УСТАНОВКА ROOTKIT HUNTER ========
if [ "$ENABLE_RKHUNTER" -eq 1 ]; then
    log "МОДУЛЬ 13: Установка rootkit hunter..."
    
    apt install rkhunter -y
    check_status "Установка rkhunter"
    
    rkhunter --update
    check_status "Обновление баз rkhunter"
    
    rkhunter --propupd
    check_status "Создание начальной базы файловых свойств"
    
    log "Для запуска проверки выполните: sudo rkhunter --check"
    
    read -p "Запустить проверку rkhunter сейчас? (y/n): " run_rkhunter
    if [[ "$run_rkhunter" == "y" ]]; then
        rkhunter --check
    fi
fi

# ======== МОДУЛЬ 14: НАСТРОЙКА APPARMOR ========
if [ "$ENABLE_APPARMOR" -eq 1 ]; then
    log "МОДУЛЬ 14: Настройка AppArmor..."
    
    apt install apparmor-utils -y
    check_status "Установка утилит AppArmor"
    
    aa-status
    check_status "Проверка статуса AppArmor"
    
    log "AppArmor установлен и работает"
fi

# ======== ЗАВЕРШЕНИЕ НАСТРОЙКИ ========
log "🎉 Настройка сервера завершена!"
log "Для просмотра лога выполните: cat /var/log/server_setup.log"

# Рекомендация перезагрузки
read -p "Рекомендуется перезагрузить сервер. Перезагрузить сейчас? (y/n): " reboot_now
if [[ "$reboot_now" == "y" ]]; then
    log "Перезагрузка сервера..."
    reboot
else
    log "Перезагрузка отложена. Не забудьте перезагрузить сервер позже."
fi

exit 0
