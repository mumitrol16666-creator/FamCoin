#!/usr/bin/env bash
# Проверка резервной копии: разворачивает дамп во временной базе, проверяет
# целостность журнала (deploy/integrity.sql) и удаляет временную базу.
# Рабочую базу не трогает. Бэкап, который ни разу не восстанавливали, —
# не бэкап: скрипт запускает сторож раз в неделю.
#
#   deploy/verify-backup.sh [каталог] [файл.sql.gz]   (по умолчанию — последний)
# Код возврата 0 — копия восстановилась и журнал цел.
set -euo pipefail

DIR="${1:-/opt/famcoin}"
cd "$DIR"
FILE="${2:-$(ls -1t backups/famcoin-*.sql.gz 2>/dev/null | head -1)}"
[ -n "$FILE" ] && [ -f "$FILE" ] || { echo "нет резервных копий в $DIR/backups" >&2; exit 2; }

DB="famcoin_verify_$$"
dc() { docker compose exec -T "$@"; }
cleanup() { dc db psql -U famcoin -d postgres -qc "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1 || true; }
trap cleanup EXIT

dc db psql -U famcoin -d postgres -qc "CREATE DATABASE $DB OWNER famcoin"
# statement_timeout=0: загрузка большой копии идёт дольше минуты
gunzip -c "$FILE" | dc -e PGOPTIONS='-c statement_timeout=0' db psql -U famcoin -d "$DB" -q -v ON_ERROR_STOP=1 >/dev/null

COUNTS="$(dc db psql -U famcoin -d "$DB" -Atc "select (select count(*) from users) || ' пользователей, ' || (select count(*) from transactions) || ' операций, ' || (select count(*) from postings) || ' проводок'")"
PROBLEMS="$(dc db psql -U famcoin -d "$DB" -At -F ' ' -f - < deploy/integrity.sql)"
if [ -n "$PROBLEMS" ]; then
  echo "копия $FILE восстановилась ($COUNTS), но журнал повреждён:" >&2
  echo "$PROBLEMS" | head -20 >&2
  exit 1
fi
echo "копия $FILE восстанавливается: $COUNTS, журнал цел"
