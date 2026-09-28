#!/usr/bin/env bash
# Восстановление базы FamCoin из резервной копии.
#   deploy/restore.sh /opt/famcoin/backups/famcoin-2026-09-27_0300.sql.gz
# Останавливает API, пересоздаёт базу, загружает дамп, запускает API.
set -euo pipefail

FILE="${1:?укажите файл .sql.gz}"
DIR="${2:-/opt/famcoin}"
cd "$DIR"

read -r -p "Текущая база будет заменена содержимым $FILE. Продолжить? [y/N] " ok
[ "$ok" = "y" ] || exit 1

docker compose stop api
docker compose exec -T db psql -U famcoin -d postgres -c 'DROP DATABASE IF EXISTS famcoin' -c 'CREATE DATABASE famcoin OWNER famcoin'
gunzip -c "$FILE" | docker compose exec -T db psql -U famcoin -d famcoin -q
docker compose start api
echo "восстановлено из $FILE"
