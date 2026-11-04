#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [OK]   $desc"; ((PASS++))
    else
        echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён"        "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"
# TODO 1: порт отличен от 22 (check сравнивает на равенство, поэтому сравниваем отдельно и передаём yes/no)
SSH_PORT="$(sudo sshd -T | awk '/^port /{print $2; exit}')"
check "Порт SSH отличен от 22 (текущий: $SSH_PORT)" "yes" "$([[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]] && echo yes || echo no)"
# TODO 2: maxauthtries равно 3
check "MaxAuthTries равно 3"               "3"  "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
# TODO 3: политика по умолчанию для входящего трафика равна deny
#         строка вида: Default: deny (incoming), allow (outgoing), disabled (routed)
check "Политика входящего трафика deny" "deny" "$(sudo ufw status verbose | grep '^Default:' | grep -oE '[a-z]+ \(incoming\)' | awk '{print $1}')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "        %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
# Порог срока действия сертификата в днях; для проверки на нарушение: CERT_MIN_DAYS=400 bash audit.sh
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"
check "Служба nginx активна" "active" "$(systemctl is-active nginx 2>/dev/null)"
check "Конфигурация nginx корректна (nginx -t)" "yes" "$(sudo nginx -t >/dev/null 2>&1 && echo yes || echo no)"
check "Сертификат действует ещё не менее ${CERT_MIN_DAYS} дн." "yes" \
      "$(sudo openssl x509 -in /etc/ssl/certs/devops.crt -noout -checkend $((CERT_MIN_DAYS * 86400)) >/dev/null 2>&1 && echo yes || echo no)"
WW_FILES="$(sudo find /var/www/devops-site -perm -o+w 2>/dev/null | tr '\n' ' ')"
check "Нет файлов ресурса с правом записи для всех" "" "${WW_FILES% }"
check "Права ключа TLS равны 600" "600" "$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null)"

echo "[5] Контейнеризация"
check "Служба docker активна" "active" "$(systemctl is-active docker 2>/dev/null)"
check "Контейнер СУБД app-db-1 в состоянии healthy" "healthy" \
      "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)"
# Сокеты на портах 5000 и 5432 с адресом, отличным от 127.0.0.1 (ожидается пустой список)
EXPOSED="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E ':(5000|5432)$' | grep -v '^127\.0\.0\.1:' | tr '\n' ' ')"
check "Порты 5000 и 5432 прослушиваются только на 127.0.0.1" "" "${EXPOSED% }"
check "Права файла ~/app/.env равны 600" "600" "$(stat -c '%a' "$HOME/app/.env" 2>/dev/null)"

echo "[6] Контрольная работа № 2"
KR2_DIR="${KR2_DIR:-$HOME/kr2}"
KR2_PORT="${KR2_PORT:-8001}"
REDIS_CID="$(docker compose --project-directory "$KR2_DIR" ps -q redis 2>/dev/null)"
check "Контейнер сервиса redis в состоянии healthy" "healthy" \
      "$(docker inspect -f '{{.State.Health.Status}}' "$REDIS_CID" 2>/dev/null)"
check "Порт $KR2_PORT опубликован только на 127.0.0.1" "127.0.0.1:$KR2_PORT" \
      "$(docker compose --project-directory "$KR2_DIR" port app "$KR2_PORT" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "Права файла ~/kr2/.env равны 600" "600" "$(stat -c '%a' "$KR2_DIR/.env" 2>/dev/null)"
check "Сертификат kr2.crt действует ещё не менее 30 дн." "yes" \
      "$(openssl x509 -in /etc/ssl/certs/kr2.crt -noout -checkend $((30 * 86400)) >/dev/null 2>&1 && echo yes || echo no)"
check "Ресурс kr2 активирован (ссылка в sites-enabled)" "/etc/nginx/sites-available/kr2" \
      "$(readlink /etc/nginx/sites-enabled/kr2 2>/dev/null)"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
