# Руководство по деплою и безопасности multiOTP в изолированной корпоративной среде

Данное руководство описывает полный процесс развертывания сервера двухфакторной аутентификации **multiOTP** (проверка логина/пароля и TOTP-кода при логоне и повышении привилегий) в контейнеризированной среде Docker с реверс-прокси **Nginx**, автоматической генерацией локальных корпоративных TLS/SSL-ключей (работающих одновременно и по IP-адресу, и по внутреннему доменному имени) и комплексной настройкой безопасности (Security Hardening).

---

## 1. Жестко зафиксированные версии (Hardcoded Versions)

Для обеспечения воспроизводимости сборок в закрытом контуре и исключения непредвиденных изменений при обновлениях все образы жестко зафиксированы без использования тега `latest`:

| Компонент | Docker-образ | Зафиксированная версия | Назначение |
| :--- | :--- | :--- | :--- |
| **multiOTP** | `multiotp/multiotp-open-source` | `5.10.4.3` | Основной сервер 2FA (OATH TOTP) и Web-интерфейс |
| **Nginx** | `nginx` | `1.27.2-alpine3.20` | TLS-терминация, HTTP->HTTPS редирект, защита заголовков и Rate Limiting |

---

## 2. Архитектура и работа по IP и по домену

### 2.1. Одновременная поддержка доступа по IP и по доменному имени
Для корректной работы веб-интерфейса и агентов проверки TOTP в корпоративной сети как по адресу `https://192.168.1.81/`, так и по `https://multiotp.corp.local/`:
1. **Сертификат с расширением SAN (`subjectAltName`)**:
   - Скрипт `deploy.sh` автоматически определяет локальные IP-адреса сервера (или принимает заданный через `--ip`) и прописывает в единый сертификат `multiotp.crt` как `DNS:`-записи (домен), так и `IP:`-записи (IP-адрес сервера и `127.0.0.1`).
   - Благодаря этому при добавлении `multiotp.crt` в доверенные корневые сертификаты (например, через групповые политики Active Directory GPO или `ca-certificates` в Linux) клиенты и браузеры доверяют узлу **и при обращении по IP, и при обращении по домену**.
2. **Универсальный прием заголовков в Nginx**:
   - В [nginx/conf.d/multiotp.conf](file:///home/isolated/Documents/multiotp/nginx/conf.d/multiotp.conf) настроен только защищенный порт `listen 443 ssl default_server` с `server_name _;` (порт `80` полностью отключен), что позволяет принимать HTTPS-обращения по любому IP и доменному имени.
   - Заголовок `proxy_set_header Host $http_host;` и `X-Forwarded-Host $http_host;` передает в multiOTP именно тот адрес (IP или домен), к которому обратился клиент.

### 2.2. Изоляция контейнеров и закрытие лишних портов
- Контейнер `multiotp-server` **не публикует никаких портов** наружу на хост-машину (неиспользуемые порты `80` и UDP-порты FreeRADIUS `1812`/`1813` полностью закрыты). Внутренний порт `443` доступен только внутри изолированной Docker-сети `multiotp_internal` (`expose: ["443"]`).
- Весь внешний трафик принимает исключительно `multiotp-nginx-proxy` строго на защищенном порту **`443/tcp`** (TLSv1.2 / TLSv1.3), проксируя запросы на внутренний порт `https://multiotp:443`.
- Постоянные данные вынесены на хост:
  - `./data/multiotp` -> `/etc/multiotp` — конфигурация multiOTP, база TOTP-токенов и пользователей.
  - `./logs/multiotp` и `./logs/nginx` — журналы для аудита и SIEM.
  - `./nginx/certs` -> `/etc/nginx/certs:ro` — два файла локальных сертификатов (`multiotp.crt` и `multiotp.key`), примонтированные в режиме **только для чтения**.

---

## 3. Автоматизированный запуск (Bash-скрипт `deploy.sh`)

Для того чтобы не прописывать настройки и сертификаты вручную, используется скрипт автоматизации [deploy.sh](file:///home/isolated/Documents/multiotp/deploy.sh).

### Что делает скрипт автоматически:
1. Проверяет наличие `openssl`, `docker` и `docker compose`.
2. Создает структуру каталогов (`data/multiotp`, `logs/multiotp`, `logs/nginx`, `nginx/certs/`) и выставляет строгие права доступа (`chmod 700` на директории с данными и ключами, `chmod 750` на директории логов).
3. Генерирует файл `.env` (с правами `600`), устанавливает часовой пояс **`TZ=Asia/Bishkek`**, а также прописывает `timezone=Asia/Bishkek` в `data/multiotp/config/multiotp.ini`.
4. Генерирует в `./nginx/certs/` ровно 2 локальных файла сроком на 10 лет (3650 дней):
   - **`multiotp.crt`** (сертификат RSA-4096 с `subjectAltName` для домена и всех локальных IP-адресов хоста, права `644`).
   - **`multiotp.key`** (приватный ключ, права `600`).
5. Запускает стек через `docker compose up -d --force-recreate`.
6. Устанавливает часовой пояс `Asia/Bishkek` внутри контейнера `multiotp-server` через CLI (`multiotp.php -config timezone="Asia/Bishkek"`).

### Примеры запуска:

#### А. Запуск с указанием корпоративного домена и IP-адреса сервера
```bash
./deploy.sh --domain multiotp.corp.local --ip 192.168.1.81
```
*(Если не указывать `--ip`, скрипт автоматически определит текущий IP сетевого интерфейса сервера и включит его в сертификат).*

#### Б. Перевыпуск сертификатов (при смене IP или домена)
```bash
./deploy.sh --domain otp.internal.lan --ip 192.168.100.15 --regen-certs
```

#### В. Только подготовка файлов и сертификатов без старта Docker
```bash
./deploy.sh --domain multiotp.corp.local --ip 192.168.1.81 --prep-only
```

---

## 4. Все настройки безопасности (Security Hardening Guide)

### 4.1. Безопасность на уровне Docker и ОС
В файле [docker-compose.yml](file:///home/isolated/Documents/multiotp/docker-compose.yml) применены следующие меры:
- **Закрытие всех незащищенных и лишних портов**: порт `80/tcp` и UDP-порты RADIUS полностью отключены, наружу открыт исключительно **`443/tcp` (HTTPS)** на реверс-прокси Nginx.
- **`security_opt: ["no-new-privileges:true"]`**: запрещает процессам внутри контейнеров повышать привилегии через бинарные файлы с битами `setuid`/`setgid`.
- **`read_only: true` для Nginx**: корневая файловая система прокси-сервера примонтирована в режиме «только чтение». Временные директории (`/var/cache/nginx`, `/var/run`, `/tmp`) вынесены в `tmpfs` в оперативной памяти.
- **Ротация логов (`json-file`)**: ограничение `max-size: "10m"` и `max-file: "5"` предотвращает переполнение диска.
- **Права доступа на хосте**:
  - `.env` и `nginx/certs/multiotp.key` имеют права `600` (чтение/запись только владельцу), а `nginx/certs/multiotp.crt` — `644`.
  - Каталог `./data/multiotp` и `./nginx/certs` имеют права `700`.

### 4.2. Безопасность TLS/SSL и Nginx Reverse Proxy
В конфигурациях [nginx.conf](file:///home/isolated/Documents/multiotp/nginx/nginx.conf) и [multiotp.conf](file:///home/isolated/Documents/multiotp/nginx/conf.d/multiotp.conf) настроены:
- **Отключение устаревших протоколов**: разрешены только `TLSv1.2` и `TLSv1.3` (SSLv3, TLSv1.0 и TLSv1.1 полностью отключены).
- **Стойкие шифры (AEAD Ciphers)**: используются только алгоритмы с прямой секретностью (Forward Secrecy — `ECDHE`) и аутентифицированным шифрованием (`AES-GCM`, `CHACHA20-POLY1305`).
- **Защита от брутфорса TOTP-кодов и паролей (Rate Limiting)**:
  - Зона `multiotp_login` ограничивает частоту запросов с одного IP-адреса до `30 req/s` (с `burst=60 nodelay`), защищая от перебора без блокировки загрузки статики интерфейса.
  - Зона `multiotp_conn` ограничивает число одновременных TCP-соединений с одного IP до `50`.
- **Скрытие версии сервера**: директива `server_tokens off;` убирает версию Nginx из заголовков ответа и страниц ошибок.
- **HTTP Security Headers**:
  - `Strict-Transport-Security: max-age=31536000` (HSTS) — принудительное использование HTTPS.
  - `X-Frame-Options: SAMEORIGIN` и `Content-Security-Policy: frame-ancestors 'self'` — защита от Clickjacking.
  - `X-Content-Type-Options: nosniff` — защита от MIME-sniffing атак.
  - `Referrer-Policy: strict-origin-when-cross-origin` — защита заголовка Referer.
- **Защита сессионных Cookie**:
  - Директива `proxy_cookie_path / "/; HttpOnly; Secure; SameSite=Strict";` принудительно добавляет флаги безопасности всем кукам веб-интерфейса.

### 4.3. Обязательная смена стандартных секретов в Web UI при первом запуске
После первого запуска откройте веб-интерфейс в браузере (`https://192.168.1.81/` или `https://multiotp.corp.local/`) и обязательно измените заводские параметры:
1. **Пароль администратора Web UI**:
   - По умолчанию установлены **логин:** `admin`, **пароль:** `1234`. Сразу замените пароль администратора прямо в веб-интерфейсе.
2. **Секретный ключ сервера (`Server secret`)**:
   - По умолчанию в настройках стоит открыто известный ключ **`ClientServerSecret`** (в файле `multiotp.ini` он записан как `server_secret:=dGx9cn5qeFV7fFJ5RGR/cGd4`).
   - Обязательно смените его через Web UI на уникальный корпоративный секрет (и используйте этот же секрет при подключении агентов логона / повышения прав).
3. **Генерация и добавление TOTP-ключей пользователей из Web UI**:
   - Создание пользователей, задание или генерация секретного ключа (Seed) для TOTP и вывод QR-кода для мобильного аутентификатора полностью доступны из веб-интерфейса.

### 4.4. Настройка межсетевого экрана (UFW / iptables внутри корпоративной сети)
Для работы веб-интерфейса и проверки TOTP на хосте требуется разрешить входящие подключения только на защищенный порт **`443/tcp`** для корпоративной подсети (не меняя ваши существующие правила для кастомного порта SSH):
```bash
sudo ufw allow from 192.168.1.0/24 to any port 443 proto tcp
```

---

## 5. Замена сертификатов на корпоративные (Wildcard + Root CA) и проверка работоспособности

### 5.1. Замена на корпоративный Wildcard-сертификат (`.crt` + `.key`/`.rsa`)
При наличии собственного корпоративного Wildcard-сертификата и корневого сертификата УЦ:
```bash
# 1. Объедините сертификат сервера и корневой сертификат в multiotp.crt (сначала wildcard, затем root CA)
cat wildcard_corp.crt root_ca.crt > nginx/certs/multiotp.crt

# 2. Поместите расшифрованный приватный ключ (.key или .rsa) в multiotp.key
cp wildcard_corp.rsa nginx/certs/multiotp.key
# (если ключ под паролем: openssl rsa -in wildcard_corp.rsa -out nginx/certs/multiotp.key)

# 3. Проверьте совпадение модулей ключа и сертификата
openssl x509 -noout -modulus -in nginx/certs/multiotp.crt | openssl md5
openssl rsa -noout -modulus -in nginx/certs/multiotp.key | openssl md5

# 4. Выставьте права и перезагрузите Nginx
chmod 644 nginx/certs/multiotp.crt
chmod 600 nginx/certs/multiotp.key
docker exec multiotp-nginx-proxy nginx -t && docker exec multiotp-nginx-proxy nginx -s reload
```

### 5.2. Проверка сертификата и доступности сервиса
```bash
# Проверить прописанные доменные имена и IP-адреса внутри локального сертификата
openssl x509 -in nginx/certs/multiotp.crt -noout -ext subjectAltName

# Проверка доступа по домену и по IP
curl -kI https://multiotp.corp.local
curl -kI https://192.168.1.81
```
