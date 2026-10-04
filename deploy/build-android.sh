#!/usr/bin/env bash
# Сборка APK для Android на сервере (в контейнере с Flutter и Android SDK).
#   deploy/build-android.sh /opt/famcoin
# Ключ подписи создаётся один раз в $DIR/keys и больше не меняется:
# обновления ставятся поверх только с тем же ключом. Берегите папку keys.
set -euo pipefail

DIR="${1:-/opt/famcoin}"
cd "$DIR"
set -a; . ./.env; set +a
: "${PUBLIC_URL:?PUBLIC_URL не задан в .env}"

IMAGE=ghcr.io/cirruslabs/flutter:stable
mkdir -p keys dist

if [ ! -f keys/upload.jks ]; then
  echo "→ создаю ключ подписи"
  PASS="$(openssl rand -hex 16)"
  docker run --rm -v "$DIR/keys:/keys" "$IMAGE" \
    keytool -genkeypair -v -keystore /keys/upload.jks -alias famcoin -keyalg RSA -keysize 2048 -validity 10000 \
      -storepass "$PASS" -keypass "$PASS" -dname "CN=FamCoin, O=FamCoin, C=KZ" >/dev/null
  printf 'storeFile=/keys/upload.jks\nstorePassword=%s\nkeyAlias=famcoin\nkeyPassword=%s\n' "$PASS" "$PASS" > keys/key.properties
  chmod 600 keys/key.properties keys/upload.jks
fi

VERSION="$(grep -E "^version:" app/pubspec.yaml | awk "{print \$2}")"
echo "→ собираю APK $VERSION (API: $PUBLIC_URL/api)"
docker run --rm \
  -v "$DIR/app:/src/app" -v "$DIR/packages:/src/packages" -v "$DIR/keys:/keys:ro" \
  -v famcoin_pub_cache:/root/.pub-cache -v famcoin_gradle:/root/.gradle \
  -w /src/app "$IMAGE" bash -lc '
    set -e
    git config --global --add safe.directory "*" 2>/dev/null || true
    cp /keys/key.properties android/key.properties
    flutter pub get
    flutter build apk --release --dart-define=API_URL='"$PUBLIC_URL"'/api --dart-define=APP_VERSION='"$VERSION"'
    rm -f android/key.properties
  '

# Версия и ссылка для проверки обновлений в приложении (D103).
cp app/build/app/outputs/flutter-apk/app-release.apk "dist/famcoin.apk"
cp app/build/app/outputs/flutter-apk/app-release.apk "dist/famcoin-$VERSION.apk"
printf '{"version":"%s","builtAt":"%s","url":"%s/download/famcoin.apk"}\n' "$VERSION" "$(date -Is)" "$PUBLIC_URL" > dist/android.json
ls -la dist/famcoin.apk
echo "готово: $PUBLIC_URL/download/famcoin.apk"
