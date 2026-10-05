#!/usr/bin/env bash
# Восстановление базы FamCoin из резервной копии.
#   deploy/restore.sh /opt/famcoin/backups/famcoin-2026-09-27_0300.sql.gz [каталог]
#
# Рабочая база заменяется только когда копия доказала, что она годна:
#   1. до любых изменений: файл есть, читается, это целый gzip с дампом
#      PostgreSQL;
#   2. дамп разворачивается во ВРЕМЕННУЮ базу с остановкой на первой ошибке
#      SQL (psql -v ON_ERROR_STOP=1), API всё это время работает;
#   3. во временной базе проверяются схема и целостность журнала
#      (deploy/integrity.sql);
#   4. только после этого API останавливается, текущая база сохраняется
#      («pre-restore» копия в backups/ и переименованная база), временная
#      база становится рабочей, API запускается и проверяется;
#   5. «восстановлено» печатается лишь когда API ответил и данные на месте.
# Любая ошибка до переключения оставляет прежнюю базу на месте и API
# запущенным; ошибка после переключения возвращает прежнюю базу.
#
# Прежняя база остаётся рядом под именем famcoin_before_restore_<метка>:
# удалить её, убедившись, что всё в порядке — вручную (команда в конце вывода).
# RESTORE_YES=1 — не спрашивать подтверждение (для тестов и автоматизации).
set -euo pipefail

FILE="${1:?укажите файл .sql.gz}"
DIR="${2:-/opt/famcoin}"
cd "$DIR"

dc() { docker compose exec -T "$@"; }
# statement_timeout=0: загрузка большой копии идёт дольше минуты
pg() { dc -e PGOPTIONS='-c statement_timeout=0' db "$@"; }
psql_admin() { dc db psql -U famcoin -d postgres -v ON_ERROR_STOP=1 -qAt "$@"; }
fail() { echo "restore.sh: $*" >&2; exit 2; }

# ------------------------------------------------ 1. файл — до любых изменений
[ -e "$FILE" ] || fail "файла нет: $FILE"
[ -f "$FILE" ] && [ -r "$FILE" ] || fail "не читается как файл: $FILE"
[ -s "$FILE" ] || fail "файл пустой: $FILE"
gzip -t "$FILE" 2>/dev/null || fail "не целый gzip-архив: $FILE"
# Дамп pg_dump начинается с этой строки; другой SQL базой FamCoin не является.
HEAD="$(gunzip -c "$FILE" 2>/dev/null | head -c 8192 || true)"
case "$HEAD" in
  *"PostgreSQL database dump"*) ;;
  *) fail "это не дамп PostgreSQL (pg_dump): $FILE" ;;
esac

if [ "${RESTORE_YES:-}" != "1" ]; then
  read -r -p "Текущая база будет заменена содержимым $FILE. Продолжить? [y/N] " ok
  [ "$ok" = "y" ] || exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
TMP="famcoin_restore_${STAMP}_$$"
OLD="famcoin_before_restore_${STAMP}"
STOPPED=0      # API остановлен нами
RENAMED=0      # прежняя база переименована в $OLD
SWITCHED=0     # временная база стала рабочей
DONE=0

cleanup() {
  code=$?
  set +e
  if [ "$DONE" != 1 ]; then
    if [ "$SWITCHED" = 1 ]; then
      # Временная база уже рабочая, но дальше что-то пошло не так — вернуть прежнюю.
      echo "restore.sh: возвращаю прежнюю базу" >&2
      docker compose stop api >/dev/null 2>&1
      psql_admin -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'famcoin' AND pid <> pg_backend_pid()" >/dev/null 2>&1
      psql_admin -c "ALTER DATABASE famcoin RENAME TO famcoin_restore_failed_${STAMP}" >/dev/null 2>&1
      RENAMED_BACK=0
      psql_admin -c "ALTER DATABASE ${OLD} RENAME TO famcoin" >/dev/null 2>&1 && RENAMED_BACK=1
      [ "$RENAMED_BACK" = 1 ] && SWITCHED=0 && RENAMED=0
    elif [ "$RENAMED" = 1 ]; then
      psql_admin -c "ALTER DATABASE ${OLD} RENAME TO famcoin" >/dev/null 2>&1 && RENAMED=0
    fi
    # Временную базу удаляем, пока она не стала рабочей; неудачную после отката — тоже.
    if [ "$SWITCHED" = 0 ]; then
      psql_admin -c "DROP DATABASE IF EXISTS ${TMP}" >/dev/null 2>&1
    fi
    if [ "$STOPPED" = 1 ]; then
      if [ "$SWITCHED" = 0 ]; then
        docker compose start api >/dev/null 2>&1
      else
        echo "restore.sh: прежнюю базу вернуть не удалось, API остановлен — нужен ручной разбор (базы: famcoin, ${OLD}, копия backups/pre-restore-${STAMP}.sql.gz)" >&2
      fi
    fi
    echo "restore.sh: восстановление НЕ выполнено, рабочая база не заменена (код $code)" >&2
  fi
  exit "$code"
}
trap cleanup EXIT

# ------------------------------------------ 2. загрузка во временную базу
echo "Разворачиваю копию во временной базе $TMP…"
psql_admin -c "CREATE DATABASE ${TMP} OWNER famcoin"
gunzip -c "$FILE" | pg psql -U famcoin -d "$TMP" -q -v ON_ERROR_STOP=1 >/dev/null

# ------------------------------------- 3. схема и целостность до переключения
HAS="$(dc db psql -U famcoin -d "$TMP" -qAt -c "select (to_regclass('public.users') is not null and to_regclass('public.transactions') is not null and to_regclass('public.postings') is not null and to_regclass('public.ledger_accounts') is not null)")"
[ "$HAS" = "t" ] || fail "в копии нет таблиц FamCoin (users, transactions, postings, ledger_accounts)"
COUNTS="$(dc db psql -U famcoin -d "$TMP" -qAt -c "select (select count(*) from users) || ' пользователей, ' || (select count(*) from transactions) || ' операций, ' || (select count(*) from postings) || ' проводок'")"
PROBLEMS="$(dc db psql -U famcoin -d "$TMP" -qAt -F ' ' -f - < deploy/integrity.sql)"
if [ -n "$PROBLEMS" ]; then
  echo "копия восстановилась ($COUNTS), но журнал в ней повреждён:" >&2
  echo "$PROBLEMS" | head -20 >&2
  fail "восстанавливать из такой копии нельзя"
fi
echo "Копия годна: $COUNTS, журнал цел."

# --------------------------- 4. остановка API, сохранение прежней, переключение
docker compose stop api
STOPPED=1
mkdir -p backups
PRE="backups/pre-restore-${STAMP}.sql.gz"
pg pg_dump -U famcoin -d famcoin --no-owner | gzip -9 > "$PRE"
gzip -t "$PRE" && [ -s "$PRE" ] || fail "не удалось сохранить текущую базу перед заменой: $PRE"

psql_admin -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'famcoin' AND pid <> pg_backend_pid()" >/dev/null
psql_admin -c "ALTER DATABASE famcoin RENAME TO ${OLD}"
RENAMED=1
psql_admin -c "ALTER DATABASE ${TMP} RENAME TO famcoin"
SWITCHED=1

# ------------------------------------------- 5. запуск и проверка до «успеха»
# Данные сверяются до запуска API: после него в базе уже могут появиться новые.
NOW="$(dc db psql -U famcoin -d famcoin -qAt -c "select (select count(*) from users) || ' пользователей, ' || (select count(*) from transactions) || ' операций, ' || (select count(*) from postings) || ' проводок'")"
[ "$NOW" = "$COUNTS" ] || fail "данные после переключения ($NOW) не совпадают с проверенной копией ($COUNTS)"
docker compose start api
ALIVE=0
for _ in $(seq 1 "${RESTORE_HEALTH_TRIES:-60}"); do
  if dc api /app/healthcheck.sh >/dev/null 2>&1; then ALIVE=1; break; fi
  sleep "${RESTORE_HEALTH_PAUSE:-2}"
done
[ "$ALIVE" = 1 ] || fail "API не ответил после восстановления"

DONE=1
echo "восстановлено из $FILE: $NOW"
echo "Прежняя база сохранена: база $OLD и файл $DIR/$PRE."
echo "Когда убедитесь, что всё в порядке, удалите её:"
echo "  docker compose exec -T db psql -U famcoin -d postgres -c 'DROP DATABASE $OLD'"
