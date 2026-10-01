#!/usr/bin/env bash
# Сторож FamCoin. Запускается раз в минуту из cron (ставит deploy.sh).
# Следит за приложением и пишет в Telegram (TELEGRAM_BOT_TOKEN и
# TELEGRAM_ADMIN_CHAT из .env), если что-то не так:
#   - /api/health не отвечает или не доходит до базы → через несколько
#     минут перезапускает api, сообщает о падении и о восстановлении;
#   - упал контейнер → поднимает;
#   - диск заполнен на 85% и больше, свежей копии базы нет больше 26 часов,
#     сертификат HTTPS истекает меньше чем через 10 дней;
#   - раз в сутки проверяет целостность журнала, раз в неделю — что копия
#     базы восстанавливается (deploy/verify-backup.sh).
# Пока всё в порядке, ничего не пишет.
#
# Проверить, что сообщения доходят до Telegram:
#   deploy/watchdog.sh /opt/famcoin --test
#
# Для проверок можно переопределить: WATCHDOG_URL, WATCHDOG_HEALTH_PATH,
# WATCHDOG_SERVICES, WATCHDOG_FAILS (сколько неудач подряд считать падением,
# по умолчанию 3), WATCHDOG_COMPOSE, WATCHDOG_STATE.
set -uo pipefail
# У cron короткий PATH — добавляем привычные каталоги (docker, curl, openssl).
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DIR="${1:-/opt/famcoin}"
cd "$DIR" || exit 1
set -a; [ -f .env ] && . ./.env; set +a
STATE="${WATCHDOG_STATE:-/var/tmp/famcoin-watchdog}"
mkdir -p "$STATE"
URL="${WATCHDOG_URL:-${PUBLIC_URL:-https://coin.edudev.kz}}"
HEALTH_PATH="${WATCHDOG_HEALTH_PATH:-/api/health}"
SERVICES="${WATCHDOG_SERVICES:-api db web caddy}"
FAILS="${WATCHDOG_FAILS:-3}"
HOST="${URL#*://}"; HOST="${HOST%%/*}"
# Только с боевым файлом: голый docker-compose.yml поднял бы контейнеры с паролями для разработки.
DC="${WATCHDOG_COMPOSE:-docker compose -f docker-compose.yml -f docker-compose.prod.yml}"

now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { echo "$(now_iso) $*"; }

# Сообщение в Telegram и в журнал. Без токена — только в журнал.
alert() {
  log "ALERT: $*"
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_ADMIN_CHAT:-}" ]; then
    curl -sf -m 15 -o /dev/null "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_ADMIN_CHAT}" \
      --data-urlencode "text=FamCoin: $*" || log "не удалось отправить в Telegram"
  fi
}

# Не чаще одного раза в сутки на один ключ.
once_a_day() {
  local mark="$STATE/once-$1-$(date +%F)"
  [ -e "$mark" ] && return 1
  find "$STATE" -name "once-$1-*" -mtime +2 -delete 2>/dev/null
  : > "$mark"
}

if [ "${2:-}" = "--test" ]; then
  alert "проверка связи: сторож работает (${HOST})"
  exit 0
fi

# Во время выкладки контейнеры пересоздаются — сторож молчит (deploy.sh
# ставит отметку и снимает её в конце; забытая отметка живёт не дольше 20 минут).
if [ -n "$(find "$STATE/paused" -mmin -20 2>/dev/null)" ]; then exit 0; fi

# 1. Приложение отвечает и доходит до базы
if curl -fsS -m 10 "$URL$HEALTH_PATH" 2>/dev/null | grep -q '"ok":true'; then
  if [ -e "$STATE/down" ]; then
    since="$(cat "$STATE/down")"
    alert "снова работает (был недоступен с $since)"
    rm -f "$STATE/down"
  fi
  echo 0 > "$STATE/fails"
else
  n=$(( $(cat "$STATE/fails" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$STATE/fails"
  log "health не отвечает ($n)"
  if [ "$n" -eq "$FAILS" ]; then
    [ -e "$STATE/down" ] || now_iso > "$STATE/down"
    alert "$URL$HEALTH_PATH не отвечает $n мин. подряд, перезапускаю api"
    $DC restart api >/dev/null 2>&1 || $DC up -d api >/dev/null 2>&1
  elif [ "$n" -eq $(( FAILS * 3 )) ]; then
    alert "после перезапуска всё ещё не отвечает ($n мин.), поднимаю все контейнеры; нужен человек"
    $DC up -d >/dev/null 2>&1
  fi
fi

# 2. Все контейнеры запущены. Одному показанию не верим: 01.10.2026 список
# запущенных один раз не показал db, хотя база работала без перезапусков, —
# ушла ложная тревога. Поэтому «сервиса нет» перепроверяется через 5 секунд.
running_now() { $DC ps --status running --services 2>/dev/null; }
running="$(running_now)"
for svc in $SERVICES; do
  if ! grep -qx "$svc" <<<"$running"; then
    sleep "${WATCHDOG_RECHECK_SECONDS:-5}"
    if grep -qx "$svc" <<<"$(running_now)"; then
      log "сервис $svc один раз не попал в список запущенных; перепроверка: работает"
      continue
    fi
    if once_a_day "svc-$svc"; then alert "контейнер $svc не запущен, поднимаю"; fi
    $DC up -d "$svc" >/dev/null 2>&1
  fi
done

# 3. Диск
used="$(df -P / | awk 'NR==2 {gsub("%", "", $5); print $5}')"
if [ "${used:-0}" -ge 85 ] && once_a_day disk; then alert "диск заполнен на ${used}%"; fi

# 4. Свежая копия базы
newest="$(ls -1t backups/famcoin-*.sql.gz 2>/dev/null | head -1)"
if [ -z "$newest" ] || [ -n "$(find "$newest" -mmin +1560 2>/dev/null)" ]; then
  if once_a_day backup; then alert "резервной копии базы нет больше 26 часов"; fi
fi

# 5. Сертификат HTTPS (только для настоящего домена)
if [[ "$URL" == https://* ]] && [ "$(date +%H%M)" = "0400" ]; then
  end="$(echo | openssl s_client -servername "$HOST" -connect "$HOST:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  if [ -n "$end" ] && date -d "$end" +%s >/dev/null 2>&1; then
    left=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
    [ "$left" -lt 10 ] && alert "сертификат $HOST истекает через $left дн."
  fi
fi

# 6. Раз в сутки — целостность журнала в рабочей базе
if [ "$(date +%H%M)" = "0410" ]; then
  problems="$(docker compose exec -T db psql -U famcoin -d famcoin -At -F ' ' -f - < deploy/integrity.sql 2>&1 | head -5)"
  [ -n "$problems" ] && alert "проверка целостности журнала нашла проблемы: $problems"
fi

# 7. Раз в неделю (понедельник) — копия базы действительно восстанавливается
if [ "$(date +%u%H%M)" = "10420" ]; then
  if ! out="$(deploy/verify-backup.sh "$DIR" 2>&1)"; then alert "резервная копия не проходит проверку: $(echo "$out" | tail -3 | tr '\n' ' ')"; else log "$out"; fi
fi
exit 0
