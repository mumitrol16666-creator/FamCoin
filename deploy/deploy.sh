#!/usr/bin/env bash
# Развёртывание FamCoin на сервер по SSH.
#   deploy/deploy.sh root@95.216.145.108
# Копирует код, при первом запуске создаёт .env с паролем базы,
# собирает образы на сервере и перезапускает контейнеры.
set -euo pipefail

TARGET="${1:?укажите user@host}"
DIR="${2:-/opt/famcoin}"
# deploy/deploy.sh user@host [dir] --android — дополнительно собрать APK.
ANDROID=0; for a in "$@"; do [ "$a" = "--android" ] && ANDROID=1; done
[ "$DIR" = "--android" ] && DIR=/opt/famcoin
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "→ копирую код в $TARGET:$DIR"
ssh "$TARGET" "mkdir -p '$DIR'"
rsync -az --delete \
  --exclude '.git' --exclude '.dart_tool' --exclude 'build' --exclude 'node_modules' \
  --exclude '.env' --exclude '.claude' --exclude 'design' --exclude 'docs' \
  --exclude 'keys' --exclude 'dist' --exclude 'backups' \
  --exclude 'app/ios' --exclude 'app/macos' --exclude 'app/linux' --exclude 'app/windows' \
  "$ROOT/" "$TARGET:$DIR/"

HOST="${TARGET#*@}"
ssh "$TARGET" bash -s "$DIR" "$HOST" "$ANDROID" <<'EOF'
set -euo pipefail
DIR="$1"; HOST="$2"; ANDROID="$3"
cd "$DIR"
if [ ! -f .env ]; then
  echo "→ создаю .env с новым паролем базы"
  printf 'POSTGRES_PASSWORD=%s\nPUBLIC_URL=http://%s\n' "$(openssl rand -hex 24)" "$HOST" > .env
  chmod 600 .env
fi
if ! grep -q '^ADMIN_PASSWORD=' .env; then
  echo "→ создаю пароль админки (см. .env)"
  echo "ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)" >> .env
fi
echo "→ резервные копии: ежедневно в 03:00 (см. deploy/backup.sh)"
chmod +x deploy/backup.sh deploy/restore.sh deploy/build-android.sh
mkdir -p dist
( crontab -l 2>/dev/null | grep -v 'famcoin/deploy/backup.sh' || true; echo "0 3 * * * $DIR/deploy/backup.sh $DIR >> $DIR/backups/backup.log 2>&1" ) | crontab -
mkdir -p backups
echo "→ собираю и запускаю контейнеры"
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build --remove-orphans
docker image prune -f >/dev/null
if [ "$ANDROID" = "1" ]; then
  deploy/build-android.sh "$DIR"
fi
echo "→ состояние"
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
EOF

URL="$(ssh "$TARGET" "grep '^PUBLIC_URL=' '$DIR/.env' | cut -d= -f2")"
URL="${URL:-http://$HOST}"
echo "→ проверяю $URL"
for i in $(seq 1 60); do
  if curl -sf -o /dev/null "$URL/" && curl -sf "$URL/api/health" >/dev/null; then
    echo "готово: $URL"
    exit 0
  fi
  sleep 2
done
echo "приложение не ответило за минуту — смотрите: ssh $TARGET 'cd $DIR && docker compose logs --tail 50'" >&2
exit 1
