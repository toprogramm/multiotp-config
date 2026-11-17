#!/usr/bin/env bash
# ==============================================================================
# Скрипт автоматического деплоя и настройки безопасности multiOTP + Nginx (TLS)
# Среда: Изолированный корпоративный контур (Logon / Повышение прав по TOTP)
# Жестко зафиксированные версии:
#   - multiotp/multiotp-open-source:5.10.4.3
#   - nginx:1.27.2-alpine3.20
# ==============================================================================

set -euo pipefail

# --- Жестко закодированные версии (Hardcoded Versions) ---
readonly MULTIOTP_IMAGE="multiotp/multiotp-open-source:5.10.4.3"
readonly NGINX_IMAGE="nginx:1.27.2-alpine3.20"

# --- Автоопределение локального IP хоста ---
DETECTED_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
if [[ -z "${DETECTED_IP}" ]]; then
    DETECTED_IP="192.168.1.81"
fi

# --- Параметры по умолчанию для корпоративной среды ---
DOMAIN="${DOMAIN:-multiotp.corp.local}"
SERVER_IP="${SERVER_IP:-${DETECTED_IP}}"
TZ_VALUE="${TZ:-Asia/Bishkek}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${PROJECT_DIR}/nginx/certs"
ENV_FILE="${PROJECT_DIR}/.env"

# --- Цвета вывода ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Использование: $0 [ОПЦИИ]

Опции:
  --domain <домен>          Корпоративное доменное имя (по умолчанию: multiotp.corp.local)
  --ip <ip-адрес>           IP-адрес сервера для доступа в браузере и SAN-сертификата (авто: ${SERVER_IP})
  --regen-certs             Принудительно перевыпустить локальные сертификаты multiotp.crt и multiotp.key
  --prep-only               Только подготовить конфиги, директории и TLS-сертификаты без запуска контейнеров
  -h, --help                Показать эту справку
EOF
}

PREP_ONLY="false"
REGEN_CERTS="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --ip)
            SERVER_IP="$2"
            shift 2
            ;;
        --regen-certs)
            REGEN_CERTS="true"
            shift
            ;;
        --prep-only)
            PREP_ONLY="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Неизвестный аргумент: $1"
            usage
            exit 1
            ;;
    esac
done

# --- 1. Проверка зависимостей ---
check_dependencies() {
    log_info "Проверка системных утилит..."
    if ! command -v openssl >/dev/null 2>&1; then
        log_error "Утилита openssl не найдена. Установите openssl."
        exit 1
    fi

    if [[ "${PREP_ONLY}" == "false" ]]; then
        if ! command -v docker >/dev/null 2>&1; then
            log_error "Docker не установлен."
            exit 1
        fi
        if ! docker compose version >/dev/null 2>&1; then
            log_error "Плагин Docker Compose v2 не установлен."
            exit 1
        fi
    fi
    log_ok "Все необходимые утилиты присутствуют."
}

# --- 2. Создание структуры каталогов и прав доступа ---
setup_directories() {
    log_info "Создание структуры каталогов и настройка безопасных прав доступа..."
    mkdir -p \
        "${PROJECT_DIR}/data/multiotp" \
        "${PROJECT_DIR}/logs/multiotp" \
        "${PROJECT_DIR}/logs/nginx" \
        "${PROJECT_DIR}/nginx/conf.d" \
        "${CERTS_DIR}"

    chmod 700 \
        "${PROJECT_DIR}/data" \
        "${PROJECT_DIR}/data/multiotp" \
        "${CERTS_DIR}"
    chmod 750 "${PROJECT_DIR}/logs" "${PROJECT_DIR}/logs/nginx"
    log_ok "Каталоги созданы и защищены."
}

# --- 3. Генерация файла окружения (.env) и настройка таймзоны ---
generate_env_config() {
    cat > "${ENV_FILE}" <<EOF
# Автоматически сгенерированный файл окружения multiOTP (Корпоративный контур)
DOMAIN=${DOMAIN}
SERVER_IP=${SERVER_IP}
TZ=${TZ_VALUE}
EOF
    chmod 600 "${ENV_FILE}"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    if [[ -f "${PROJECT_DIR}/data/multiotp/config/multiotp.ini" ]]; then
        sed -i "s|^timezone=.*|timezone=${TZ_VALUE}|g" "${PROJECT_DIR}/data/multiotp/config/multiotp.ini" || true
    fi
    log_ok "Файл .env актуализирован (права 600, TZ=${TZ_VALUE})."
}

# --- 4. Автоматическая генерация локальных сертификатов (multiotp.crt и multiotp.key) ---
generate_tls_certificates() {
    if [[ "${REGEN_CERTS}" == "true" ]]; then
        rm -f "${CERTS_DIR}/multiotp.crt" "${CERTS_DIR}/multiotp.key"
    fi

    if [[ -f "${CERTS_DIR}/multiotp.crt" && -f "${CERTS_DIR}/multiotp.key" ]]; then
        log_info "Локальные TLS сертификаты (multiotp.crt и multiotp.key) уже существуют."
        return
    fi

    log_info "Генерация локальной пары TLS (multiotp.crt и multiotp.key) для домена и IP..."

    # Формируем список Subject Alternative Names (SAN) для работы и по домену, и по IP
    local san_list="DNS:${DOMAIN},DNS:localhost,DNS:multiotp,DNS:multiotp.local,IP:127.0.0.1"
    if [[ "${SERVER_IP}" != "127.0.0.1" ]]; then
        san_list="${san_list},IP:${SERVER_IP}"
    fi

    # Добавляем все остальные локальные IPv4 интерфейсы хоста, если они есть
    for ip in $(hostname -I 2>/dev/null || true); do
        if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "${san_list}" != *"IP:${ip}"* ]]; then
            san_list="${san_list},IP:${ip}"
        fi
    done

    openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days 3650 \
        -keyout "${CERTS_DIR}/multiotp.key" \
        -out "${CERTS_DIR}/multiotp.crt" \
        -subj "/C=KG/ST=Chuy/L=Bishkek/O=Corp-Security/OU=2FA-MultiOTP/CN=${DOMAIN}" \
        -addext "subjectAltName=${san_list}" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign" \
        -addext "extendedKeyUsage=serverAuth" 2>/dev/null

    chmod 600 "${CERTS_DIR}/multiotp.key"
    chmod 644 "${CERTS_DIR}/multiotp.crt"
    log_ok "Созданы 2 локальных файла сертификатов (срок 10 лет):"
    log_ok "  - ${CERTS_DIR}/multiotp.crt (SAN: ${san_list})"
    log_ok "  - ${CERTS_DIR}/multiotp.key"
}

# --- 5. Запуск контейнеров и пост-стартовая настройка ---
start_and_harden_stack() {
    if [[ "${PREP_ONLY}" == "true" ]]; then
        log_ok "Режим --prep-only завершен. Все файлы и локальные TLS-сертификаты готовы."
        return
    fi

    log_info "Проверка доступности демона Docker..."
    if ! docker info >/dev/null 2>&1; then
        log_warn "Демон Docker не запущен или недоступен текущему пользователю."
        log_warn "Все конфигурационные файлы и локальные TLS-сертификаты подготовлены. Запустите стек командой:"
        echo "  sudo docker compose up -d"
        return
    fi

    log_info "Запуск контейнеров через Docker Compose..."
    cd "${PROJECT_DIR}"
    docker compose up -d --force-recreate

    log_info "Ожидание инициализации контейнера multiotp-server..."
    local retries=20
    while [[ ${retries} -gt 0 ]]; do
        if docker ps --filter "name=multiotp-server" --filter "status=running" --format '{{.Names}}' | grep -q "multiotp-server"; then
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done

    log_info "Установка часового пояса ${TZ_VALUE} внутри multiOTP (критично для TOTP)..."
    docker exec multiotp-server /usr/local/bin/multiotp/multiotp.php -config timezone="${TZ_VALUE}" >/dev/null 2>&1 || \
        log_warn "Не удалось установить таймзону через CLI автоматически."

    log_ok "Деплой в корпоративном контуре успешно завершен!"
    echo "----------------------------------------------------------------------"
    echo -e "Доступ по домену:      ${GREEN}https://${DOMAIN}/${NC}"
    echo -e "Доступ по IP-адресу:   ${GREEN}https://${SERVER_IP}/${NC}"
    echo -e "Конфигурация окружения: ${ENV_FILE} (права 600, TZ=${TZ_VALUE})"
    echo "----------------------------------------------------------------------"
    echo -e "${YELLOW}[ВАЖНО — ОБЯЗАТЕЛЬНЫЕ ДЕЙСТВИЯ В WEB UI ПРИ ПЕРВОМ ЗАПУСКЕ]:${NC}"
    echo -e "  1. Войдите в Web UI (по умолчанию логин: ${YELLOW}admin${NC}, пароль: ${YELLOW}1234${NC}) и сразу смените пароль администратора."
    echo -e "  2. В разделе настроек Web UI смените стандартный секретный ключ сервера (Server secret),"
    echo -e "     где по умолчанию стоит значение: ${YELLOW}ClientServerSecret${NC}"
    echo -e "  3. Секретные ключи (сиды / QR-коды) TOTP для пользователей создаются и привязываются также прямо через Web UI."
    echo "----------------------------------------------------------------------"
}

main() {
    check_dependencies
    setup_directories
    generate_env_config
    generate_tls_certificates
    start_and_harden_stack
}

main
