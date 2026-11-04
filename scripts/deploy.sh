#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops-vm"                  # псевдоним из ~/.ssh/config (ПР № 5)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"

# Корень репозитория определяется по расположению сценария, поэтому
# сценарий работает из любого каталога (требование 2)
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"

err() { echo "deploy: $*" >&2; }

# 1. Разбор аргумента --dry-run (требование 1)
DRY_RUN=""
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN="--dry-run" ;;
    *)         err "неизвестный аргумент: $1"; echo "Использование: $0 [--dry-run]" >&2; exit 1 ;;
esac

# 2. Проверки до доставки
# Требование 4: без главной страницы --delete удалил бы её с сервера
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    err "нет файла ${LOCAL_DIR}index.html, доставка отменена"
    exit 1
fi

# Требование 5: незафиксированные изменения, в т.ч. в индексе и новые файлы
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    err "в репозитории есть незафиксированные изменения, доставка отменена:"
    git -C "$REPO_ROOT" status --short >&2
    exit 1
fi

COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

# 3. Синхронизация: единственное SSH-соединение за запуск (требование 8).
# BatchMode=yes — без интерактивного запроса пароля (требование 9).
# --delete + --chmod — точная копия site/ с правами 755/644 (требование 3).
if ! rsync -avz --delete --chmod=D755,F644 --exclude='.DS_Store' $DRY_RUN \
        -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
        "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}/"; then
    err "ошибка rsync, доставка не выполнена"
    exit 1
fi

# 4. При --dry-run проверка доступности не выполняется
if [[ -n "$DRY_RUN" ]]; then
    echo "Пробный запуск завершён, сервер не изменён (коммит ${COMMIT})"
    exit 0
fi

# 5. Проверка доступности с проверкой сертификата, без -k (требование 6)
if ! curl -fsS --cacert "$CA_CERT" --max-time 10 -o /dev/null "$SITE_URL/"; then
    err "ресурс ${SITE_URL} недоступен после доставки"
    exit 1
fi

# Требование 7
echo "Деплой выполнен: коммит ${COMMIT}, ${SITE_URL} доступен"
exit 0
