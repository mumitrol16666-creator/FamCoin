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

docker compose exec -T db pg_dump -U famcoin -d famcoin --no-owner | gzip -9 > "$FILE"
SIZE="$(du -h "$FILE" | cut -f1)"
echo "$(date -Is) backup $FILE ($SIZE)"

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
  curl -sf -o /dev/null \
    -F "chat_id=${TELEGRAM_ADMIN_CHAT}" \
    -F "document=@${FILE}" \
    -F "caption=FamCoin: резервная копия ${STAMP}, ${SIZE}. Пользователей: ${USERS}, операций: ${TX}." \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
    && echo "$(date -Is) отправлено в Telegram" \
    || echo "$(date -Is) не удалось отправить в Telegram" >&2
  # Ключ подписи — раз в неделю, по понедельникам.
  if [ -f backups/famcoin-keys.tar.gz ] && [ "$(date +%u)" = "1" ]; then
    curl -sf -o /dev/null -F "chat_id=${TELEGRAM_ADMIN_CHAT}" -F "document=@backups/famcoin-keys.tar.gz" \
      -F "caption=FamCoin: ключ подписи Android. Хранить надёжно, не пересылать." \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" || true
  fi
fi
