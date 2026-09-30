#!/usr/bin/env bash
# Ежедневная резервная копия базы FamCoin.
# Ставится на сервере в cron (см. deploy.sh): дамп PostgreSQL из контейнера,
# сжатие, хранение 14 дней в $DIR/backups и, если в .env заданы
# TELEGRAM_BOT_TOKEN и TELEGRAM_ADMIN_CHAT, отправка файла в Telegram.
set -euo pipefail

DIR="${1:-/opt/famcoin}"
cd "$DIR"
set -a; . ./.env; set +a

mkdir -p backups
STAMP="$(date +%Y-%m-%d_%H%M)"
FILE="backups/famcoin-$STAMP.sql.gz"

# statement_timeout=0: копия большой базы может идти дольше минуты
docker compose exec -T -e PGOPTIONS='-c statement_timeout=0' db pg_dump -U famcoin -d famcoin --no-owner | gzip -9 > "$FILE"
SIZE="$(du -h "$FILE" | cut -f1)"
echo "$(date '+%Y-%m-%dT%H:%M:%S%z') backup $FILE ($SIZE)"

# Ключ подписи Android: без него не выпустить обновление приложения.
if [ -d keys ]; then
  tar -czf backups/famcoin-keys.tar.gz keys
  chmod 600 backups/famcoin-keys.tar.gz
fi

# Старше 14 дней — удаляем.
find backups -name 'famcoin-*.sql.gz' -mtime +14 -delete

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_ADMIN_CHAT:-}" ]; then
  USERS="$(docker compose exec -T db psql -U famcoin -d famcoin -tAc 'select count(*) from users')"
  TX="$(docker compose exec -T db psql -U famcoin -d famcoin -tAc 'select count(*) from transactions')"
  say() { curl -sf -m 15 -o /dev/null "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_ADMIN_CHAT}" --data-urlencode "text=$1" || true; }
  BYTES="$(stat -c%s "$FILE" 2>/dev/null || stat -f%z "$FILE")"
  if [ "$BYTES" -gt 48000000 ]; then
    # Бот Telegram принимает файлы до 50 МБ: внешней копии больше нет, пока
    # не заведено другое хранилище, — об этом нельзя молчать.
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') копия ${SIZE} не влезает в Telegram" >&2
    say "FamCoin: копия базы ${STAMP} (${SIZE}) больше лимита Telegram, внешней копии нет. Нужно другое хранилище (S3 / Storage Box)."
  elif curl -sf -o /dev/null \
    -F "chat_id=${TELEGRAM_ADMIN_CHAT}" \
    -F "document=@${FILE}" \
    -F "caption=FamCoin: резервная копия ${STAMP}, ${SIZE}. Пользователей: ${USERS}, операций: ${TX}." \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument"; then
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') отправлено в Telegram"
  else
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') не удалось отправить в Telegram" >&2
    say "FamCoin: не удалось отправить копию базы ${STAMP} в Telegram. Локальная копия на сервере есть."
  fi
  # Ключ подписи — раз в неделю, по понедельникам.
  if [ -f backups/famcoin-keys.tar.gz ] && [ "$(date +%u)" = "1" ]; then
    curl -sf -o /dev/null -F "chat_id=${TELEGRAM_ADMIN_CHAT}" -F "document=@backups/famcoin-keys.tar.gz" \
      -F "caption=FamCoin: ключ подписи Android. Хранить надёжно, не пересылать." \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" || true
  fi
fi
