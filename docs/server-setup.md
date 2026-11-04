# Конфигурация виртуальной машины devops-vm


## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Имя в VirtualBox | devops-vm1  |
| Гостевая ОС | Ubuntu Server 24.04 LTS (64-bit) |
| Оперативная память | 2048 МБ  |
| Ядра процессора | 2  |
| Диск | 25 ГБ, динамически расширяемый  |
| Средство виртуализации | VirtualBox 7.x, хост macOS |

## 2. Сетевые интерфейсы

| Адаптер | Тип | Интерфейс в ВМ | Адрес | Назначение |
|---|---|---|---|---|
| 1 | NAT | enp0s3  | 10.0.2.15/24 (DHCP) | выход в интернет, SSH с хоста через проброс порта |
| 2 | Виртуальный адаптер хоста (Host-only) | enp0s8  | 192.168.56.2  | прямой доступ с хоста по адресу, имя devops.local |

Проверка **[VM]**: `ip -brief address`

### Имя узла и DNS

- Имя узла: `devops-vm`, FQDN: `devops-vm.devops.local`
- На хосте имя `devops.local` указывает на адрес Host-only

**[VM]**
```bash
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f
```
**[HOST]**
```bash
echo "192.168.56.2    devops.local" | sudo tee -a /etc/hosts
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
ssh -p 2222 -i ~/.ssh/devops_vm devops@devops.local
```

## 3. Правило проброса портов

Адаптер 1 (NAT):

| Имя | Протокол | Адрес хоста | Порт хоста | Адрес гостя | Порт гостя |
|---|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | — | 2222 |

На чистой установке порт гостя 22; после настройки SSH (раздел 5) изменить на 2222:
```bash
# [HOST]
VBoxManage controlvm devops-vm1 natpf1 delete ssh
VBoxManage controlvm devops-vm1 natpf1 "ssh,tcp,127.0.0.1,2222,,2222"
```

## 4. Учётные записи

| Имя | Группы | Аутентификация |
|---|---|---|
| student | student, sudo (+ стандартные группы установщика) | пароль, только локальная консоль (вход по SSH запрещён директивой `AllowUsers devops`) |
| devops | devops, sudo | по SSH только ключ ed25519; пароль используется для sudo |
| root | — | вход по SSH запрещён (`PermitRootLogin no`) |

Создание **[VM]** (под student, через `ssh student@127.0.0.1 -p 2222` или консоль):
```bash
sudo adduser devops
sudo usermod -aG sudo devops
groups devops
```

Ключ на хосте **[HOST]**:
```bash
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm     # если ключа ещё нет
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
```
Права в ВМ: `~/.ssh` — 700, `~/.ssh/authorized_keys` — 600.

Файл `~/.ssh/config` на хосте:
```
Host devops-vm
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

## 5. Служба SSH

- Порт: **2222**
- Основной файл `/etc/ssh/sshd_config` не изменяется, копия: `/etc/ssh/sshd_config.backup`
- Изменения: `/etc/ssh/sshd_config.d/99-hardening.conf`
- В `/etc/ssh/sshd_config.d/50-cloud-init.conf` строка `PasswordAuthentication yes` закомментирована (иначе она имеет приоритет над 99-)
- Сокет-активация отключена: `ssh.socket` выключен, `ssh.service` включён

Содержимое `99-hardening.conf`:
```
Port 2222

PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30

AllowUsers devops

X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

Применение **[VM]** (не закрывая текущую сессию!):
```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<'CONF'
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
CONF
sudo sed -i 's/^PasswordAuthentication yes/#PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null
sudo sshd -t && echo OK
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd        # 0.0.0.0:2222
```
Затем изменить проброс портов (раздел 3) и проверить в новом терминале `ssh devops-vm`.

## 6. Правила межсетевого экрана

Политики по умолчанию: входящие — **deny**, исходящие — **allow**, маршрутизируемые — disabled. Журналирование: **medium**.

| Порт | Действие | Комментарий |
|---|---|---|
| 2222/tcp | LIMIT IN | SSH rate-limited |
| 80/tcp | ALLOW IN | HTTP |
| 443/tcp | ALLOW IN | HTTPS |

(те же правила для IPv6)

Применение **[VM]** (правило для SSH создаётся ДО `ufw enable`):
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw logging medium
sudo ufw status verbose
```

## 7. Снимки состояния

| Снимок | Момент создания |
|---|---|
| 01-clean-install | после установки Ubuntu Server и `apt upgrade`, ВМ выключена |
| 02-keys-configured | после создания devops и настройки входа по ключу (задание 1)|
| 03-ssh-hardened | после усиления SSH и смены порта на 2222 (задание 2)  |
| 04-nginx-https | после установки Nginx и перевода ресурса на HTTPS (ПР № 6, задание 2) |
| 05-docker-compose | после установки Docker Engine и запуска проекта «приложение + СУБД» (ПР № 7, задание 2) |

## 8. Веб-сервер

| Параметр | Значение |
|---|---|
| Пакет | `nginx` из репозитория Ubuntu (на стенде nginx/1.28.3) |
| Конфигурация ресурса | `/etc/nginx/sites-available/devops-site`, ссылка в `/etc/nginx/sites-enabled/` |
| Стандартный ресурс | отключён: удалена ссылка `/etc/nginx/sites-enabled/default`, файл в `sites-available` сохранён |
| Каталог ресурса | `/var/www/devops-site`, владелец `devops:devops`, каталоги 755, файлы 644 |
| Сертификат | `/etc/ssl/certs/devops.crt`, `root:root`, 644, самоподписанный, CN и SAN `DNS:devops.local`, срок 365 дней |
| Закрытый ключ | `/etc/ssl/private/devops.key`, `root:root`, 600, RSA 2048, без пароля; в репозиторий не добавляется |
| Журналы | `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log` (запросы на порт 80 — в общий `/var/log/nginx/access.log`) |
| Порты | 80 (перенаправление 301 на HTTPS), 443 (TLSv1.2, TLSv1.3); правила UFW из раздела 6 |
| Доставка содержимого | `scripts/deploy.sh` из каталога `site/` репозитория (rsync `--delete --chmod=D755,F644`) |

Установка **[VM]**:
```bash
sudo apt update && sudo apt install -y nginx
sudo mkdir -p /var/www/devops-site
sudo chown -R devops:devops /var/www/devops-site
```

Сертификат **[VM]** (срок действия 365 дней; перевыпуск — той же командой, затем reload):
```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
sudo chmod 600 /etc/ssl/private/devops.key
```

Конфигурация ресурса **[VM]**:
```bash
sudo tee /etc/nginx/sites-available/devops-site > /dev/null <<'CONF'
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;

    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/devops-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    error_page 404 /404.html;

    access_log /var/log/nginx/devops-site.access.log;
    error_log  /var/log/nginx/devops-site.error.log;
}
CONF
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```
Изменения конфигурации применяются только `sudo nginx -t && sudo systemctl reload nginx` (не `restart`). Заголовок HSTS не добавляется.

Хост **[HOST]**: сертификат копируется для проверки клиентом, затем содержимое доставляется сценарием:
```bash
scp devops-vm:/etc/ssl/certs/devops.crt ~/devops.crt
curl --cacert ~/devops.crt -I https://devops.local   # 200 OK без -k
scripts/deploy.sh                                     # требуется GNU rsync (macOS: brew install rsync)
```

Снимок состояния: `04-nginx-https` — после перевода ресурса на HTTPS (задание 2 ПР № 6).

## 9. Контейнеризация

| Параметр | Значение |
|---|---|
| Docker Engine | из официального репозитория `download.docker.com` (не пакет `docker.io`); на стенде Docker Engine 29.9.3, containerd v2.4.2, Docker Compose v5.7.0 |
| Репозиторий APT | `/etc/apt/sources.list.d/docker.sources`, ключ `/etc/apt/keyrings/docker.asc`, Suites — кодовое имя Ubuntu (`resolute`) |
| Группа `docker` | только `devops` (у неё есть право sudo); учётные записи без sudo в группу не добавляются: участник группы фактически получает права root |
| Проект на сервере | `~/app` (`/home/devops/app`), владелец `devops`, доставляется с хоста из каталога `app/` репозитория через rsync с `--exclude=.env` |
| Файл `.env` | `~/app/.env`, `devops:devops`, права 600, создаётся только на сервере из `.env.example`, пароль СУБД — `openssl rand -hex 16`; в репозиторий и на хост не копируется (`.env` в `.gitignore` и `.dockerignore`) |
| Сервисы | `app` — образ `devops-app:1.0` (python:3.12-slim, gunicorn, процесс от пользователя `app`); `db` — `postgres:16-alpine` с проверкой `pg_isready` |
| Сеть | пользовательская сеть `app_backend` (bridge); приложение обращается к СУБД по имени `db` |
| Публикуемые порты | `127.0.0.1:5000` → `app:5000` (только для Nginx на той же машине); порт СУБД 5432 не публикуется |
| Именованный том | `app_db_data` → `/var/lib/postgresql/data` (на сервере `/var/lib/docker/volumes/app_db_data/_data`); `docker compose down -v` удаляет данные безвозвратно |
| Обратный прокси | `location /app/` в HTTPS-блоке `/etc/nginx/sites-available/devops-site`, `proxy_pass http://127.0.0.1:5000/` |
| Перезапуск | `restart: unless-stopped` у обоих сервисов: после перезагрузки ВМ контейнеры поднимаются вместе со службой docker |

Установка Docker Engine **[VM]** (по https://docs.docker.com/engine/install/ubuntu/):
```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources <<SRC
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
SRC
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker devops      # затем новая SSH-сессия
docker run --rm hello-world
```

Доставка проекта **[HOST]** (из корня репозитория):
```bash
rsync -avz --delete --exclude=.env app/ devops-vm:app/
```

Файл `.env` и запуск **[VM]**:
```bash
cd ~/app
cp .env.example .env
chmod 600 .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
docker compose up -d --build
docker compose ps                          # db: (healthy)
sudo ss -tlnp | grep -E ':(5000|5432)\b'   # только 127.0.0.1:5000
```

Обратный прокси **[VM]** — добавить в блок `server` на порту 443 после `location /`:
```nginx
    location /app/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
```
```bash
sudo nginx -t && sudo systemctl reload nginx
```

Проверка **[HOST]**:
```bash
curl --cacert ~/devops.crt https://devops.local/app/         # Hello from Docker, ...! Visits: N
curl --cacert ~/devops.crt -I https://devops.local/          # статический ресурс, 200 OK
```

Порт приложения на `0.0.0.0` не публикуется: правила DNAT, которые Docker добавляет в iptables, обрабатываются раньше правил UFW, и такой порт доступен из сети при отсутствии разрешающего правила UFW. Ответ `502 Bad Gateway` на `/app/` означает, что Nginx не может подключиться к `127.0.0.1:5000`: проверить `docker compose ps` и `/var/log/nginx/devops-site.error.log`.

Снимок состояния: `05-docker-compose` — после запуска проекта (задание 2 ПР № 7).
