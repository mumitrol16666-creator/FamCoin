# Веб-сборка приложения и раздача статики nginx.
# Контекст сборки — корень репозитория: приложению нужен пакет famcoin_core.
# Версия SDK закреплена: плавающий тег `stable` менял версии зависимостей
# от сборки к сборке. Обновлять вместе с локальным Flutter (см. README).
FROM ghcr.io/cirruslabs/flutter:3.44.0 AS build
WORKDIR /src

# Зависимости кешируются отдельно от кода: правка экранов не тянет pub get.
COPY packages/famcoin_core/pubspec.yaml packages/famcoin_core/
COPY app/pubspec.* app/
RUN cd app && flutter pub get

COPY packages/famcoin_core packages/famcoin_core
COPY app app

# Адрес API подставляется на сборке: браузер обращается к нему напрямую.
ARG API_URL=http://localhost:8080
# Без service worker: обновления видны сразу после перезагрузки страницы,
# а не после закрытия всех вкладок (кеш отдаёт nginx через ETag).
# --wasm: движок skwasm (WebAssembly) там, где браузер умеет (Safari 26,
# Chrome), иначе загрузчик сам берёт main.dart.js с CanvasKit.
# Метка сборки (D103): зашивается в код (BUILD_ID) и кладётся рядом с сайтом в
# build.json — приложение сравнивает их и предлагает перезагрузить страницу.
# Та же метка — версия в адресе загрузчика и main.dart.js/wasm: имена без
# хеша, и Safari иначе держит старую копию в HTTP-кеше до истечения срока.
RUN cd app && V=$(date +%s) \
  && flutter build web --release --wasm --pwa-strategy=none --dart-define=API_URL=$API_URL --dart-define=BUILD_ID=$V \
  && APP_VERSION=$(grep -E '^version:' pubspec.yaml | awk '{print $2}') \
  && printf '{"buildId":"%s","version":"%s"}\n' "$V" "$APP_VERSION" > build/web/build.json \
  && cd build/web \
  && sed -i "s#flutter_bootstrap.js#flutter_bootstrap.js?v=$V#" index.html \
  && sed -i "s#\"mainJsPath\":\"main.dart.js\"#\"mainJsPath\":\"main.dart.js?v=$V\"#" flutter_bootstrap.js \
  && sed -i "s#\"mainWasmPath\":\"main.dart.wasm\"#\"mainWasmPath\":\"main.dart.wasm?v=$V\"#" flutter_bootstrap.js \
  && sed -i "s#\"jsSupportRuntimePath\":\"main.dart.mjs\"#\"jsSupportRuntimePath\":\"main.dart.mjs?v=$V\"#" flutter_bootstrap.js \
  && grep -q "main.dart.js?v=$V" flutter_bootstrap.js && grep -q "main.dart.wasm?v=$V" flutter_bootstrap.js \
  && grep -q "main.dart.mjs?v=$V" flutter_bootstrap.js

FROM nginx:1.27-alpine
COPY app/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/app/build/web /usr/share/nginx/html
EXPOSE 80
