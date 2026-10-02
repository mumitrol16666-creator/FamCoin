# Контекст сборки — корень репозитория: серверу нужен пакет famcoin_core.
FROM dart:stable AS build
WORKDIR /src
COPY packages/famcoin_core/pubspec.yaml packages/famcoin_core/
COPY server/pubspec.* server/
RUN cd server && dart pub get
COPY packages/famcoin_core packages/famcoin_core
COPY server server
RUN cd server && dart pub get --offline && dart compile exe bin/server.dart -o /server

FROM debian:bookworm-slim
# poppler-utils — pdftotext: читает PDF-выписку банка, присланную боту (D94).
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates poppler-utils && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /server /app/server
COPY server/migrations /app/migrations
COPY server/healthcheck.sh /app/healthcheck.sh
RUN chmod +x /app/healthcheck.sh
ENV MIGRATIONS_DIR=/app/migrations
EXPOSE 8080
# docker показывает здоров ли API (запрос доходит до базы); перезапускает его сторож.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD ["/app/healthcheck.sh"]
CMD ["/app/server"]
