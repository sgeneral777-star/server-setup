#!/bin/bash
#===============================================================================
# Скрипт базовой настройки Ubuntu/Debian сервера
# Автор: Сергей Бондарев
# Дата: $(date +%Y-%m-%d)
#===============================================================================

set -e  # Выход при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Логирование
LOG_FILE="/var/log/server_setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

#===============================================================================
# 📋 КОНФИГУРИРУЕМЫЕ ПАРАМЕТРЫ
#===============================================================================
NEW_HOSTNAME="new-hostname"
DOMAIN="app.bbrother.xyz"
NEW_USER="user2"
SSH_PORT="22"  # Измените на 2222 или другой, если нужно
EMAIL_LETSENCRYPT="admin@bbrother.xyz"  # Для уведомлений Let's Encrypt

#===============================================================================
# 🚀 ФУНКЦИИ
#===============================================================================
log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен выполняться от root!"
        exit 1
    fi
}

confirm_action() {
    read -p "${YELLOW}⚠️  $1 (y/n): ${NC}" -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "Операция отменена пользователем"
        exit 0
    fi
}

#===============================================================================
# 🔐 ПРОВЕРКА ПРАВ
#===============================================================================
check_root
log_info "Запуск настройки сервера: $NEW_HOSTNAME"
confirm_action "Вы уверены, что хотите продолжить настройку сервера?"

#===============================================================================
# 1️⃣ НАСТРОЙКА ИМЕНИ ХОСТА
#===============================================================================
log_info "📝 Настройка hostname..."
hostnamectl set-hostname "$NEW_HOSTNAME"

# Обновляем /etc/hosts
if ! grep -q "$NEW_HOSTNAME" /etc/hosts; then
    echo "127.0.1.1    $NEW_HOSTNAME" >> /etc/hosts
    log_info "✅ Hostname обновлён: $NEW_HOSTNAME"
else
    log_warn "⚠️ Hostname уже присутствует в /etc/hosts"
fi

#===============================================================================
# 2️⃣ ОБНОВЛЕНИЕ СИСТЕМЫ
#===============================================================================
log_info "🔄 Обновление пакетов..."
apt update && apt upgrade -y
log_info "✅ Система обновлена"

#===============================================================================
# 3️⃣ УСТАНОВКА ПАКЕТОВ
#===============================================================================
log_info "📦 Установка базового набора пакетов..."
PACKAGES="curl wget git nano htop unzip zip rsync nginx apache2 certbot postgresql python3-pip tar socat"
apt install -y $PACKAGES
log_info "✅ Пакеты установлены"

#===============================================================================
# 4️⃣ НАСТРОЙКА SSH
#===============================================================================
log_info "🔐 Настройка SSH (порт: $SSH_PORT)..."
SSHD_CONFIG="/etc/ssh/sshd_config"

# Резервная копия конфигурации
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"

# Изменяем порт, если нужно
if [[ "$SSH_PORT" != "22" ]]; then
    sed -i "s/^#Port 22/Port $SSH_PORT/" "$SSHD_CONFIG"
    sed -i "s/^Port 22/Port $SSH_PORT/" "$SSHD_CONFIG"
    log_info "✅ SSH порт изменён на $SSH_PORT"
fi

# Дополнительные рекомендации (опционально)
# sed -i 's/^#PermitRootLogin yes/PermitRootLogin no/' "$SSHD_CONFIG"
# sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' "$SSHD_CONFIG"

log_info "🔄 Перезапуск SSH..."
systemctl restart sshd || log_warn "⚠️ Не удалось перезапустить sshd (возможно, вы подключены по SSH)"

#===============================================================================
# 5️⃣ НАСТРОЙКА FIREWALL (UFW)
#===============================================================================
log_info "🔥 Настройка UFW..."

ufw --force reset > /dev/null 2>&1

# Правила для SSH
if [[ "$SSH_PORT" == "22" ]]; then
    ufw allow OpenSSH
else
    ufw allow "$SSH_PORT"/tcp
    log_info "✅ Открыт порт $SSH_PORT для SSH"
fi

# Веб-порты
ufw allow 80/tcp
ufw allow 443/tcp

# Политики по умолчанию
ufw default deny incoming
ufw default allow outgoing

# Включение (с подтверждением)
echo "y" | ufw enable
log_info "✅ UFW включён и настроен"

#===============================================================================
# 6️⃣ СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ
#===============================================================================
log_info "👤 Создание пользователя: $NEW_USER"

if id "$NEW_USER" &>/dev/null; then
    log_warn "⚠️ Пользователь $NEW_USER уже существует"
else
    adduser --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    log_info "✅ Пользователь $NEW_USER создан и добавлен в sudo"
fi

#===============================================================================
# 7️⃣ SSL СЕРТИФИКАТЫ (CERTBOT)
#===============================================================================
log_info "🔒 Получение SSL-сертификата для $DOMAIN"

# Останавливаем веб-серверы на время получения сертификата в standalone-режиме
systemctl stop nginx 2>/dev/null || true
systemctl stop apache2 2>/dev/null || true

# Получение сертификата
if ! certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL_LETSENCRYPT" --agree-tos --non-interactive; then
    log_warn "⚠️ Не удалось получить сертификат автоматически. Проверьте: 1) домен указывает на сервер, 2) порты 80/443 открыты"
else
    log_info "✅ SSL-сертификат успешно получен"
fi

# Запускаем веб-серверы обратно
systemctl start nginx 2>/dev/null || true
systemctl start apache2 2>/dev/null || true

# Проверка
log_info "📋 Установленные сертификаты:"
certbot certificates

# Проверка автообновления
log_info "⏰ Проверка таймера автообновления..."
systemctl list-timers | grep certbot || log_warn "⚠️ Таймер certbot не найден"

# Тест обновления
log_info "🧪 Тестовое обновление сертификатов..."
certbot renew --dry-run

#===============================================================================
# 8️⃣ УСТАНОВКА 3X-UI PANEL
#===============================================================================
log_info "🚀 Установка панели 3x-ui..."

if command -v x-ui &>/dev/null; then
    log_warn "⚠️ 3x-ui уже установлен"
else
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    log_info "✅ 3x-ui установлен"
fi

#===============================================================================
# 🎯 ФИНАЛЬНЫЕ СООБЩЕНИЯ
#===============================================================================
echo
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} ✅ НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo
echo "📋 Краткий чеклист:"
echo "   • Hostname: $NEW_HOSTNAME"
echo "   • SSH порт: $SSH_PORT"
echo "   • Пользователь: $NEW_USER (с sudo)"
echo "   • Домен: $DOMAIN"
echo "   • Firewall: UFW активен"
echo "   • SSL: Certbot настроен"
echo "   • Панель: 3x-ui установлен"
echo
echo "🔐 Рекомендации по безопасности:"
echo "   1. Проверьте доступ по новому пользователю: ssh -p $SSH_PORT $NEW_USER@$(hostname -I | awk '{print $1}')"
echo "   2. Отключите вход root по SSH: PermitRootLogin no в $SSHD_CONFIG"
echo "   3. Настройте Fail2Ban для защиты от brute-force"
echo "   4. Регулярно обновляйте систему: apt update && apt upgrade"
echo
echo "📁 Лог установки: $LOG_FILE"
echo
