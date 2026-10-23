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
