# Пошаговое руководство по ручному развертыванию и проверке (Manual Deployment Guide)

Данный документ предназначен для **полностью ручного развертывания, настройки и пошаговой диагностики** стека **multiOTP + Nginx (TLS/SSL)** в часовом поясе **`Asia/Bishkek` (UTC+6)** без использования автоматического скрипта `deploy.sh`.

> [!IMPORTANT]
> Синхронизация времени и часового пояса **`Asia/Bishkek`** критически важна для работы алгоритма **TOTP** (Time-based One-Time Password, RFC 6238), так как одноразовые коды для логона и повышения привилегий генерируются с шагом в 30 секунд.

---

## Шаг 1. Настройка времени и часового пояса `Asia/Bishkek` на хост-сервере

Перед запуском контейнеров убедитесь, что на самом Linux-хосте установлен часовой пояс `Asia/Bishkek` и включена синхронизация времени (NTP):

```bash
# 1. Установка часового пояса Asia/Bishkek на хосте
sudo timedatectl set-timezone Asia/Bishkek

# 2. Включение автоматической синхронизации времени по NTP
sudo timedatectl set-ntp true

# 3. Проверка текущего времени и таймзоны (должно быть Asia/Bishkek, +06)
timedatectl status
date
```

---

## Шаг 2. Ручное создание каталогов и установка прав доступа

Перейдите в рабочую директорию проекта и создайте структуру папок для хранения данных, логов и сертификатов (папки FreeRADIUS не требуются, так как используется только HTTPS для TOTP):

```bash
cd /home/isolated/Documents/multiotp

# 1. Создание директорий для томов Docker
mkdir -p \
  data/multiotp \
  logs/multiotp \
  logs/nginx \
  nginx/conf.d \
  nginx/certs

# 2. Установка безопасных прав доступа
chmod 700 data data/multiotp nginx/certs
chmod 750 logs logs/nginx
```

---

## Шаг 3. Ручное создание файла окружения `.env`

Создайте файл `.env` с жестко заданной таймзоной `Asia/Bishkek`, вашим корпоративным доменом и IP-адресом сервера:

```bash
cat > .env <<EOF
DOMAIN=multiotp.corp.local
SERVER_IP=192.168.1.81
TZ=Asia/Bishkek
EOF

# Ограничение прав доступа к файлу окружения (только владелец)
chmod 600 .env

# Проверка содержимого .env
cat .env
```

---

## Шаг 4. Ручная генерация двух файлов локальных TLS-сертификатов (`multiotp.crt` и `multiotp.key`)

Чтобы веб-интерфейс и клиенты проверки TOTP работали **и по IP-адресу (`192.168.1.81`), и по домену (`multiotp.corp.local`)**, сгенерируйте пару файлов `multiotp.crt` и `multiotp.key` с расширением `subjectAltName` (SAN):

```bash
# Укажите ваш корпоративный домен и IP-адрес сервера
DOMAIN="multiotp.corp.local"
SERVER_IP="192.168.1.81"

# Генерация приватного ключа RSA-4096 (multiotp.key) и сертификата (multiotp.crt) сроком на 10 лет
openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days 3650 \
  -keyout nginx/certs/multiotp.key \
  -out nginx/certs/multiotp.crt \
  -subj "/C=KG/ST=Chuy/L=Bishkek/O=Corp-Security/OU=2FA-MultiOTP/CN=${DOMAIN}" \
  -addext "subjectAltName=DNS:${DOMAIN},DNS:localhost,DNS:multiotp,DNS:multiotp.local,IP:127.0.0.1,IP:${SERVER_IP}" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign" \
  -addext "extendedKeyUsage=serverAuth"

# Выставление строгих прав доступа на ключ и сертификат
chmod 600 nginx/certs/multiotp.key
chmod 644 nginx/certs/multiotp.crt
```

### Ручная проверка сгенерированного сертификата:
```bash
# 1. Убедитесь, что в папке ровно 2 файла (multiotp.crt и multiotp.key)
ls -la nginx/certs/

# 2. Проверьте, что внутри сертификата прописаны и DNS-домен, и IP-адрес
openssl x509 -in nginx/certs/multiotp.crt -noout -subject -dates -ext subjectAltName
```

---

## Шаг 5. Ручная проверка конфигурационных файлов перед стартом

Перед запуском контейнеров проверьте корректность синтаксиса [docker-compose.yml](file:///home/isolated/Documents/multiotp/docker-compose.yml):

```bash
# Проверка итоговой конфигурации Docker Compose (с подстановкой переменных из .env)
docker compose config
```
Убедитесь, что в выводе `docker compose config`:
- Образ `multiotp` имеет фиксированную версию `multiotp/multiotp-open-source:5.10.4.3` и **не публикует** внешних портов (только `expose: ["443"]` внутри сети `multiotp_internal`).
- Образ `nginx` имеет фиксированную версию `nginx:1.27.2-alpine3.20` и публикует только защищенный порт **`443/tcp`**.
- В обоих сервисах в секции `environment` установлено `TZ: Asia/Bishkek`.

---

## Шаг 6. Ручная загрузка образов и запуск контейнеров

```bash
# 1. Ручное скачивание жестко зафиксированных версий образов
docker pull multiotp/multiotp-open-source:5.10.4.3
docker pull nginx:1.27.2-alpine3.20

# 2. Запуск контейнеров в фоновом режиме
docker compose up -d --force-recreate

# 3. Проверка статуса запущенных контейнеров
docker compose ps
```

---

## Шаг 7. Ручная настройка `Asia/Bishkek` и смена пароля администратора в веб-интерфейсе

Контейнер `multiotp-server` хранит собственные настройки в файле `data/multiotp/config/multiotp.ini` (где по умолчанию с завода прописано `timezone=Europe/Zurich`). Выполните следующие команды вручную для установки таймзоны `Asia/Bishkek`:

```bash
# 1. Установка часового пояса Asia/Bishkek в конфигурации самого multiOTP через CLI
docker exec -it multiotp-server /usr/local/bin/multiotp/multiotp.php -config timezone="Asia/Bishkek"

# 2. Проверка в конфигурационном файле multiotp.ini на хосте:
sed -i 's|^timezone=.*|timezone=Asia/Bishkek|g' data/multiotp/config/multiotp.ini
grep '^timezone=' data/multiotp/config/multiotp.ini
```

> [!WARNING]
> **Обязательные действия в Web UI при первом запуске:**
> 1. Откройте веб-интерфейс в браузере (`https://192.168.1.81/` или `https://multiotp.corp.local/`), войдите под стандартными учетными данными по умолчанию (**логин:** `admin`, **пароль:** `1234`) и **немедленно смените пароль администратора прямо в веб-интерфейсе**.
> 2. В настройках веб-интерфейса смените стандартный секретный ключ сервера (**`Server secret`**), где по умолчанию установлено заводское значение **`ClientServerSecret`** (в `multiotp.ini` — `server_secret:=dGx9cn5qeFV7fFJ5RGR/cGd4`), на собственный сложный секретный ключ.
> 3. Персональные секретные ключи TOTP (Seed / QR-код) для пользователей создаются или импортируются также напрямую через веб-интерфейс.

---

## Шаг 8. Чек-лист ручной проверки и диагностики (Troubleshooting)

Если что-то работает не так, выполните эти команды по порядку для проверки каждого узла:

### 1. Проверка часового пояса внутри обоих контейнеров
```bash
# Должно вывести текущее время по Бишкеку (+06 / Asia/Bishkek)
docker exec multiotp-server date
docker exec multiotp-nginx-proxy date
```

### 2. Проверка конфигурации и работы Nginx
```bash
# Проверка синтаксиса конфигурационных файлов Nginx внутри контейнера
docker exec multiotp-nginx-proxy nginx -t

# Перезагрузка конфигурации Nginx без разрыва соединений
docker exec multiotp-nginx-proxy nginx -s reload
```

### 3. Проверка связности между Nginx и внутренним портом 443 контейнера multiOTP
```bash
# Проверка ответа веб-интерфейса по HTTPS по IP-адресу (должен вернуть HTTP/2 200)
curl -kI https://192.168.1.81/

# Проверка ответа по корпоративному домену (через заголовок Host)
curl -kI -H "Host: multiotp.corp.local" https://192.168.1.81/
```

### 4. Проверка открытых портов на хосте
```bash
# Должен слушаться только защищенный порт TCP 443 (Nginx), порт 80 и остальные закрыты
sudo ss -tulnp | grep -E ':443\b'
```

### 5. Чтение логов при разборе ошибок
```bash
# Логи ошибок и запросов Nginx на хосте
tail -n 50 logs/nginx/error.log
tail -n 50 logs/nginx/access.log

# Логи multiOTP на хосте
tail -n 50 logs/multiotp/multiotp.log

# Общие логи Docker-контейнеров
docker compose logs --tail=50 multiotp
docker compose logs --tail=50 nginx
```
