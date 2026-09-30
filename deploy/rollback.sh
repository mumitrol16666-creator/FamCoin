#!/usr/bin/env bash
# Откат к предыдущей выкладке: возвращает образы api и web, которые
# deploy.sh сохранил перед сборкой (теги famcoin-api:previous и
# famcoin-web:previous). Базу не трогает: миграции только добавляют таблицы и
# колонки, старый код с ними работает.
#
#   deploy/rollback.sh [каталог]     (по умолчанию /opt/famcoin)
#
# Откат — на крайний случай. Потом исправьте код и выложите заново
# deploy/deploy.sh: исходники на сервере остаются от новой версии.
set -euo pipefail

DIR="${1:-/opt/famcoin}"
cd "$DIR"
for svc in api web; do
  docker image inspect "famcoin-$svc:previous" >/dev/null 2>&1 \
    || { echo "нет сохранённого образа famcoin-$svc:previous — откатываться не к чему" >&2; exit 1; }
done
for svc in api web; do docker tag "famcoin-$svc:previous" "famcoin-$svc:latest"; done
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-build api web
echo "откатились к предыдущей версии; проверка: curl -s https://coin.edudev.kz/api/health"
