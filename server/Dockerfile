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
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /server /app/server
COPY server/migrations /app/migrations
ENV MIGRATIONS_DIR=/app/migrations
EXPOSE 8080
CMD ["/app/server"]
