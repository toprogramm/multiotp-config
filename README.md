# Корпоративный сервер 2FA multiOTP + Nginx (TLS/SSL) в Docker

Готовое решение для развертывания сервера двухфакторной аутентификации **multiOTP** (`OATH TOTP` — вход по логину/паролю + TOTP-коду при логоне и повышении привилегий) за защищенным реверс-прокси **Nginx** в изолированном корпоративном контуре.

Поддерживает одновременную работу **как по IP-адресу**, так и **по локальному доменному имени** в адресной строке браузера и агентов с использованием автоматически генерируемых локальных сертификатов (`multiotp.crt` и `multiotp.key`) и часового пояса **`Asia/Bishkek` (UTC+6)**.

---

## 1. Что нужно установить перед деплоем (Пререквизиты)

Перед запуском на целевом Linux-сервере должны быть установлены:
1. **Docker Engine** (версия `24.0+`)
2. **Docker Compose Plugin v2** (`docker compose`)
3. **OpenSSL** (для автоматической генерации локальных TLS/SSL сертификатов)

### Установка зависимостей на Ubuntu / Debian:
```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg openssl

# Установка официального репозитория Docker
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Добавление текущего пользователя в группу docker (чтобы запускать без sudo)
sudo usermod -aG docker "$USER"
newgrp docker
```

### Проверка готовности окружения:
```bash
docker --version
docker compose version
openssl version
```

---

## 2. Как это работает (Архитектура и принцип работы)

### 2.1. Жестко зафиксированные версии (Hardcoded Versions)
В проекте намеренно не используется тег `latest` — все версии жестко прописаны в [docker-compose.yml](file:///home/isolated/Documents/multiotp/docker-compose.yml) и [deploy.sh](file:///home/isolated/Documents/multiotp/deploy.sh) для стабильности и предсказуемости в корпоративной среде:
- **`multiotp/multiotp-open-source:5.10.4.3`** — сервер 2FA (OATH TOTP) и веб-панель управления.
- **`nginx:1.27.2-alpine3.20`** — пограничный реверс-прокси сервер.

### 2.2. Схема прохождения трафика (Только HTTPS / TCP 443)
```mermaid
flowchart LR
    Client["Браузер / Агент логона и UAC (IP или Домен)"] -->|TCP 443 HTTPS (TLS 1.2/1.3)| Nginx443["Nginx :443 (multiotp.crt / multiotp.key)"]
    Nginx443 -->|Docker сеть: https://multiotp:443| MultiOTP["multiOTP 5.10.4.3 (TZ: Asia/Bishkek)"]
```

1. **Полная изоляция бэкенда (открыт только защищенный порт 443)**:
   - Контейнер `multiotp-server` **не публикует** никаких портов наружу на хост-машину (незащищенный порт `80` и UDP-порты FreeRADIUS `1812`/`1813` полностью закрыты). Внутренний порт `443` открыт только внутри изолированной Docker-сети `multiotp_internal` для Nginx.
   - Весь внешний трафик (веб-администрирование и запросы проверки TOTP при логоне / повышении привилегий) принимает исключительно контейнер `multiotp-nginx-proxy` строго на порту **`443/tcp` (HTTPS)**, где осуществляет TLS-терминацию с помощью локальной пары сертификатов (`nginx/certs/multiotp.crt` и `nginx/certs/multiotp.key`), проверяет лимиты запросов, добавляет заголовки безопасности и проксирует трафик на `https://multiotp:443`.
2. **Работа одновременно по IP и по домену**:
   - В сертификат `multiotp.crt` при генерации автоматически прописывается расширение **SAN (`Subject Alternative Name`)**, включающее как корпоративный домен (`DNS:multiotp.corp.local`, `DNS:localhost`), так и все локальные IP-адреса сервера (`IP:192.168.1.81`, `IP:127.0.0.1` и др.).
   - В Nginx настроен прием любого заголовка `Host` (`server_name _;` и `proxy_set_header Host $http_host;`), поэтому сервер одинаково отвечает и по `https://192.168.1.81/`, и по `https://multiotp.corp.local/`.

### 2.3. Структура папок и хранения данных
| Путь на хосте | Путь в контейнере | Описание |
| :--- | :--- | :--- |
| `./docker-compose.yml` | — | Описание сервисов, сетей, томов и ограничений безопасности |
| `./deploy.sh` | — | Автоматический скрипт подготовки, генерации ключей и запуска |
| `./.env` | — | Параметры окружения (`DOMAIN`, `SERVER_IP`, `TZ=Asia/Bishkek`, права `600`) |
| `./nginx/certs/multiotp.crt` | `/etc/nginx/certs/multiotp.crt:ro` | Локальный TLS-сертификат (SAN: Домен + IP, права `644`) |
| `./nginx/certs/multiotp.key` | `/etc/nginx/certs/multiotp.key:ro` | Приватный RSA-4096 ключ (права `600`) |
| `./nginx/nginx.conf` | `/etc/nginx/nginx.conf:ro` | Главный конфиг Nginx (лимиты, скрытие версии, логирование) |
| `./nginx/conf.d/multiotp.conf` | `/etc/nginx/conf.d/multiotp.conf:ro` | Конфигурация HTTPS-проксирования и заголовков безопасности |
| `./data/multiotp` | `/etc/multiotp` | База данных пользователей, TOTP-токенов и настроек multiOTP |
| `./logs/multiotp` и `./logs/nginx` | `/var/log/*` | Логи multiOTP и Nginx на хосте |

---

## 3. Как деплоить (Пошаговая инструкция)

### Вариант 1. Полностью автоматический деплой (Рекомендуется)

Все операции (создание папок, выставление прав `700`/`600`, формирование `.env` с таймзоной `Asia/Bishkek`, выпуск сертификатов `multiotp.crt` и `multiotp.key` под ваш IP и домен, запуск контейнеров) выполняет скрипт [deploy.sh](file:///home/isolated/Documents/multiotp/deploy.sh):

```bash
# 1. Перейдите в папку проекта и сделайте скрипт исполняемым
chmod +x deploy.sh

# 2. Запустите деплой (скрипт сам определит IP сервера или вы можете указать его явно)
./deploy.sh --domain multiotp.corp.local --ip 192.168.1.81
```

#### Полезные ключи скрипта `deploy.sh`:
- `./deploy.sh` — запуск с автоопределением IP-адреса текущего сервера.
- `./deploy.sh --domain otp.company.lan --ip 10.10.20.50 --regen-certs` — принудительно перевыпустить `multiotp.crt` и `multiotp.key` под новый IP или домен и перезапустить контейнеры.
- `./deploy.sh --prep-only` — только подготовить папки, `.env` и сертификаты без запуска Docker.

---

### Вариант 2. Полностью ручное развертывание и пошаговая диагностика

Подробная инструкция со всеми командами для ручного создания каталогов, генерации сертификатов, настройки часового пояса **`Asia/Bishkek`** и ручной проверки каждого узла вынесена в отдельный файл:
👉 **[MANUAL_DEPLOY.md](file:///home/isolated/Documents/multiotp/MANUAL_DEPLOY.md)**

Краткие команды управления через Docker Compose:

```bash
# Запуск или пересоздание контейнеров
docker compose up -d --force-recreate

# Проверка статуса контейнеров
docker compose ps

# Просмотр логов в реальном времени
docker compose logs -f

# Остановка стека
docker compose down
```

---

## 4. Первичная настройка после деплоя и безопасность

### 4.1. Первый вход в веб-интерфейс, смена пароля админа и секретного ключа (Server Secret / TOTP)
1. Откройте в браузере `https://<IP-вашего-сервера>/` (например, `https://192.168.1.81/`) или `https://multiotp.corp.local/`.
2. Выполните первый вход со стандартными учетными данными по умолчанию:
   - **Логин**: `admin`
   - **Пароль**: `1234`
3. **Обязательно сразу смените в веб-интерфейсе два стандартных параметра безопасности**:
   - **Пароль администратора** (вместо дефолтного `1234`).
   - **Секретный ключ сервера (`Server secret` / Client-Server Secret)**: по умолчанию там установлен стандартный ключ **`ClientServerSecret`** (в конфиге `multiotp.ini` хранится в зашифрованном виде как `server_secret:=dGx9cn5qeFV7fFJ5RGR/cGd4`). Обязательно замените его в Web UI на собственный криптостойкий ключ — именно этот ключ указывается на клиентах/агентах при настройке двухфакторного логона и повышения прав.
4. **Добавление секретных ключей TOTP для пользователей через Web UI**:
   - Да, индивидуальные секретные ключи (TOTP Seed в формате Base32/Hex) и QR-коды для приложений-аутентификаторов (Google Authenticator, FreeOTP, Yandex Key и др.) можно добавлять и генерировать прямо в веб-интерфейсе при создании пользователя или аппаратного/программного токена.

### 4.2. Добавление локального сертификата в доверенные (на клиентах и серверах)
Так как сертификат [nginx/certs/multiotp.crt](file:///home/isolated/Documents/multiotp/nginx/certs/multiotp.crt) является локальным корпоративным (с поддержкой CA и SAN для IP и домена), вы можете добавить файл `nginx/certs/multiotp.crt` в хранилище **«Доверенные корневые центры сертификации» (Trusted Root Certification Authorities)**:
- **В Windows / Active Directory**: через GPO (`Computer Configuration -> Policies -> Windows Settings -> Security Settings -> Public Key Policies -> Trusted Root Certification Authorities`).
- **На Linux (Ubuntu/Debian)**:
  ```bash
  sudo cp nginx/certs/multiotp.crt /usr/local/share/ca-certificates/multiotp.crt
  sudo update-ca-certificates
  ```

### 4.3. Замена сертификатов на собственные корпоративные (Wildcard + Root CA в форматах `.crt` и `.key`/`.rsa`)
Если в вашей корпорации уже есть собственный Удостоверяющий Центр (Root CA) и выпущенный Wildcard-сертификат (например, `*.corp.local`), менять конфигурацию Nginx или Docker не нужно — достаточно заменить два файла в `nginx/certs/`:

1. **Склейте ваш Wildcard-сертификат и Корневой сертификат в единый файл `multiotp.crt`** (строго в порядке: сначала сертификат сервера/домена, затем промежуточный/корневой `CA`):
   ```bash
   cat wildcard_corp.crt root_ca.crt > nginx/certs/multiotp.crt
   ```
2. **Подготовьте приватный ключ (`.key` или `.rsa`) и запишите его в `multiotp.key`**:
   - Если ключ **без пароля**:
     ```bash
     cp wildcard_corp.rsa nginx/certs/multiotp.key
     # или cp wildcard_corp.key nginx/certs/multiotp.key
     ```
   - Если ключ **зашифрован паролем** (`ENCRYPTED PRIVATE KEY`), снимите парольную фразу, чтобы Nginx мог запускаться автоматически:
     ```bash
     openssl rsa -in wildcard_corp.rsa -out nginx/certs/multiotp.key
     ```
3. **Проверьте совпадение пары «сертификат — приватный ключ»** (хэши MD5 должны быть одинаковыми):
   ```bash
   openssl x509 -noout -modulus -in nginx/certs/multiotp.crt | openssl md5
   openssl rsa -noout -modulus -in nginx/certs/multiotp.key | openssl md5
   ```
4. **Выставьте права и примените изменения в Nginx без остановки сервиса**:
   ```bash
   chmod 644 nginx/certs/multiotp.crt
   chmod 600 nginx/certs/multiotp.key
   docker exec multiotp-nginx-proxy nginx -t
   docker exec multiotp-nginx-proxy nginx -s reload
   ```
   *(Примечание: скрипт `./deploy.sh` при обычном запуске без флага `--regen-certs` не перезаписывает существующие файлы `multiotp.crt` и `multiotp.key`).*

### 4.4. Сводка включенных настроек безопасности
- **Минимизация поверхности атаки**: бэкенд `multiotp` полностью закрыт во внутренней сети Docker (`multiotp_internal`), незащищенный порт `80/tcp` и UDP-порты RADIUS (`1812`/`1813`) отключены; наружу смотрит **только порт `443/tcp` (HTTPS)** контейнера Nginx.
- **Защита контейнеров**: включен `no-new-privileges:true`, файловая система Nginx работает в режиме `read_only: true` (временные файлы в `tmpfs`), конфиги и сертификаты смонтированы как `:ro` (только чтение), настроена ротация логов (`max-size: 10m`, `max-file: 5`).
- **Защита TLS и HTTP**: включены только `TLSv1.2` и `TLSv1.3`, современные AEAD-шифры, скрыта версия Nginx (`server_tokens off`), добавлены заголовки `HSTS`, `CSP`, `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, а также флаги `HttpOnly; Secure; SameSite=Strict` для кук и Rate Limiting (`30 req/s`, `burst=60`) от перебора паролей/TOTP.
