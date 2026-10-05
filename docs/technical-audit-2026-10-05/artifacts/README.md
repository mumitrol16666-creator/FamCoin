# Доказательства технического аудита FamCoin

Снимок `fcd1fa1f481211daca8675595103879de9314d33`. Итоговая классификация — в [REPORT.md](../REPORT.md), обязательные проверки после исправлений — в [TEST-PLAN.md](../TEST-PLAN.md).

## Состав

| Файл/каталог | Назначение |
|---|---|
| `probes/core/technical_audit_core_probe_test.dart` | 10 диагностических проверок ядра |
| `probes/app/technical_audit_app_probe_test.dart` | 7 сценариев; APP-02 — неоднозначное правило M01, не подтверждённый дефект |
| `probes/app/technical_audit_root_probe_test.dart` | 5 проверок: два устройства, сверка, расписание, закрытый долг и календарь |
| `probes/server/technical_audit_server_probe_test.dart` | 10 сценариев: 8 воспроизведений и 2 положительных контроля |
| `probes/server/technical_audit_root_probe_test.dart` | 1 проверка сводки по закрытому долгу |
| `*-probe.log`, `core-probes.log` | Результаты диагностик |
| `*-baseline.log`, `*-analyze.log` | Существующие тесты и статический анализ |
| `server-import-near-db.log` | Все 16 тестов импорта рядом с PostgreSQL: успешно |
| `server-import-wan-recheck.log` | Timeout длинного импорта по удалённому соединению |
| `migrations.log` | Применение 18 миграций к пустой тестовой базе |
| `web-build.log`, `server-build.log`, `flutter-version.json` | Сборки и версия локальных инструментов |
| `restore_probe.py`, `restore-probe.json`, `restore-psql.log` | Проверка порядка restore.sh и поведения psql при SQL-ошибке |
| `performance.md`, `performance_probe.dart`, `performance-results.jsonl` | Методика и числа синтетического журнала 1k/10k/30k |
| `*-findings.md` | Подробности отдельных частей, согласованные с итоговым отчётом |

**Диагностические тесты намеренно утверждают наблюдаемые ошибки. Не добавлять их как есть в постоянный CI.** После исправления заменить ожидания правильными инвариантами из плана. Воспроизведение старого ошибочного поведения должно перестать проходить.

## Повтор в отдельной рабочей копии

Исходники сохранены как артефакты, чтобы не загрязнять набор постоянных тестов. В отдельной копии указанного commit разместить их по исходным путям:

```sh
cp docs/technical-audit-2026-10-05/artifacts/probes/core/*.dart packages/famcoin_core/test/
cp docs/technical-audit-2026-10-05/artifacts/probes/app/*.dart app/test/
cp docs/technical-audit-2026-10-05/artifacts/probes/server/*.dart server/test/
```

Получить зависимости стандартными `dart pub get` / `flutter pub get` в соответствующих пакетах. Из каталога `packages/famcoin_core`:

```sh
dart test test/technical_audit_core_probe_test.dart --reporter expanded
```

Из `app`:

```sh
flutter test test/technical_audit_app_probe_test.dart test/technical_audit_root_probe_test.dart --reporter expanded
```

Серверные пробы требуют **отдельную пустую тестовую PostgreSQL**, а не рабочую базу. Контракт использует localhost, тестовые имя базы/роль/пароль `famcoin`, порт из `TEST_DB_PORT`. В эту базу применить все `server/migrations/*.sql` в порядке имён. Для воспроизведения предпочтительно запускать Dart рядом с PostgreSQL: длинный импорт делает много последовательных запросов.

Из `server`, пример для отдельного тестового порта 55442:

```sh
TEST_DB_PORT=55442 TEST_DB_REQUIRED=1 dart test test/technical_audit_server_probe_test.dart test/technical_audit_root_probe_test.dart --reporter expanded
```

Telegram заменён заглушкой. Stack trace в S-TG — намеренно выброшенная ошибка обработчика для проверки offset. Реальные токены не нужны.

Из корня отдельной копии безопасная проверка скрипта восстановления:

```sh
python3 docs/technical-audit-2026-10-05/artifacts/restore_probe.py "$PWD"
```

Harness ставит временную заглушку `docker` первой в PATH и выполняет исходный restore.sh внутри временного каталога. Он фиксирует команды, а не удаляет базу. **Не заменять этот запуск прямым исполнением deploy/restore.sh на рабочем сервере.** Реальное поведение psql отдельно проверено в одноразовой базе; вывод сохранён.

Команда замера истории приведена в performance.md. Она создаёт только синтетический журнал в памяти.

## Инфраструктура текущего аудита

Использован отдельный временный PostgreSQL 18.6 с ограничением памяти 384 MiB, без рабочего тома приложения; все 18 миграций применены с нуля. Сетевые сценарии, имена и суммы синтетические. Производственные финансовые данные не читались.

После проверки временный контейнер базы остановлен и удалён, временная копия серверного кода на тестовом хосте и SSH-туннель убраны. Рабочие сервисы не перезапускались. Исходники, журналы и отчёт сохранены здесь; продуктовый код не изменён.
