#!/usr/bin/env bash
# Проверка живости для docker: запрос к /health, который доходит до базы.
exec 3<>/dev/tcp/127.0.0.1/"${PORT:-8080}" || exit 1
printf 'GET /health HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
grep -q '"ok":true' <&3
