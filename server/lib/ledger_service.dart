/// Финансовые данные владельца: состояние и команды.
///
/// Каждая команда проходит через `famcoin_core` — то же ядро, что в
/// приложении. Команда и все её последствия сохраняются в одной транзакции
/// PostgreSQL; строка владельца блокируется, поэтому команды одного
/// пользователя выполняются строго по очереди.
library;

import 'dart:convert';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:postgres/postgres.dart';

import 'auth_service.dart';

/// `purchase` — разовая запланированная покупка (D88): отдельный вид, чтобы
/// прежние версии приложения не приняли её за ежемесячный платёж.
const entityKinds = {'account', 'member', 'limit', 'goal', 'planned', 'purchase', 'debt', 'category', 'quick'};
const maxEntityBytes = 8 * 1024;

/// Предел размера профиля: он хранится одним JSON, и без предела клиент мог бы
/// раздуть свою строку в базе (она читается при каждом открытии приложения).
const maxProfileBytes = 32 * 1024;
const maxBatch = 200;

/// Ограничения обычного тарифа (D05).
const freeMoneyAccounts = 1;
const freeLimits = 2;
const freeGoals = 1;

/// Счета-копилки целей не расходуют лимит денежных счетов обычного тарифа.
bool isPiggy(String accountId) => accountId.startsWith('piggy');

/// Данные владельца для чтения: журнал, профиль и справочники (вид → id → данные).
class LedgerView {
  const LedgerView({required this.ledger, required this.profile, required this.locale, required this.entities});
  final Ledger ledger;
  final Map<String, dynamic> profile;
  final String locale;
  final Map<String, Map<String, Map<String, dynamic>>> entities;

  Map<String, Map<String, dynamic>> of(String kind) => entities[kind] ?? const {};
}

class _Cached {
  _Cached(this.revision, this.ledger);
  final int revision;
  final Ledger ledger;
}

class LedgerService {
  LedgerService(this.db, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Pool db;
  final DateTime Function() _clock;

  /// Журналы в памяти по ревизии владельца: без повторного чтения всей
  /// истории на каждую команду. Не больше [cacheLimit] владельцев —
  /// давно не заходившие вытесняются первыми.
  final Map<String, _Cached> _cache = {};
  static const cacheLimit = 200;

  /// Потолок по общему числу операций в памяти: у одного «тяжёлого» владельца
  /// их десятки тысяч, и 200 таких журналов заняли бы гигабайты.
  static const maxCachedTransactions = 300000;

  void _remember(String userId, _Cached c) {
    // Устаревшую ревизию поверх более новой не кладём: читатель, начавший
    // раньше, мог закончить позже команды.
    final current = _cache[userId];
    if (current != null && current.revision > c.revision) return;
    _cache.remove(userId);
    _cache[userId] = c;
    var total = 0;
    for (final e in _cache.values) {
      total += e.ledger.transactions.length;
    }
    while (_cache.length > 1 && (_cache.length > cacheLimit || total > maxCachedTransactions)) {
      total -= _cache.remove(_cache.keys.first)!.ledger.transactions.length;
    }
  }

  /// Забыть журнал владельца (после удаления аккаунта).
  void forget(String userId) => _cache.remove(userId);

  // --------------------------------------------------------------- чтение

  /// Независимая копия журнала: команда меняет копию, а кеш и ранее выданные
  /// читателям журналы остаются прежними, пока команда не зафиксирована.
  static Ledger _copy(Ledger l) => ledgerFromSnapshot(
        accounts: [for (final a in l.accounts) accountToJson(a)],
        transactions: [for (final t in l.transactions) transactionToJson(t)],
        reservations: reservationsToJson(l),
      );

  /// Журнал владельца на [revision]. Для чтения возвращается общий экземпляр
  /// из кеша: он неизменяем — команды работают с копией ([forWrite]) и кладут
  /// в кеш новый журнал только после commit. Для записи — всегда свой
  /// экземпляр, который в кеш сам не попадает.
  Future<Ledger> _loadLedger(Session s, String userId, int revision, {bool forWrite = false}) async {
    final cached = _cache[userId];
    if (cached != null && cached.revision == revision) {
      _remember(userId, cached); // недавно использован — вытесняется последним
      return forWrite ? _copy(cached.ledger) : cached.ledger;
    }

    final accounts = await s.execute(
      Sql.named('SELECT id, kind, asset_class, liquid, currency, archived FROM ledger_accounts WHERE user_id = @u'),
      parameters: {'u': userId},
    );
    final txs = await s.execute(
      Sql.named("SELECT id, to_char(date, 'YYYY-MM-DD'), type, meta, reverses FROM transactions WHERE user_id = @u ORDER BY seq"),
      parameters: {'u': userId},
    );
    final postings = await s.execute(
      Sql.named('SELECT tx_id, account_id, amount FROM postings WHERE user_id = @u ORDER BY tx_id, n'),
      parameters: {'u': userId},
    );
    final reservations = await s.execute(
      Sql.named('SELECT goal_id, account_id, amount FROM reservations WHERE user_id = @u'),
      parameters: {'u': userId},
    );

    final byTx = <String, List<Map<String, Object?>>>{};
    for (final p in postings) {
      byTx.putIfAbsent(p[0] as String, () => []).add({'a': p[1], 'v': p[2]});
    }
    final ledger = ledgerFromSnapshot(
      accounts: [
        for (final a in accounts)
          {'id': a[0], 'kind': a[1], 'assetClass': a[2], 'liquid': a[3], 'currency': a[4], 'archived': a[5]},
      ],
      transactions: [
        for (final t in txs)
          {'id': t[0], 'date': t[1], 'type': t[2], 'postings': byTx[t[0]] ?? const [], 'meta': t[3], 'reverses': t[4]},
      ],
      reservations: [
        for (final r in reservations) {'goalId': r[0], 'accountId': r[1], 'amount': r[2]},
      ],
    );
    if (!forWrite) _remember(userId, _Cached(revision, ledger));
    return ledger;
  }

  Future<Map<String, Object?>> state(String userId) async {
    return db.runTx((s) async {
      final u = await s.execute(
        Sql.named('SELECT email, locale, plan, profile, revision, display_name, pro_until FROM users WHERE id = @u FOR SHARE'),
        parameters: {'u': userId},
      );
      if (u.isEmpty) throw ApiError(401, 'unauthorized');
      final revision = u.first[4] as int;
      final ledger = await _loadLedger(s, userId, revision);
      final entities = await s.execute(
        Sql.named('SELECT kind, id, data FROM entities WHERE user_id = @u ORDER BY updated_at'),
        parameters: {'u': userId},
      );
      final reconciliations = await s.execute(
        Sql.named('SELECT month, snapshot, closed_at, invalidated_at FROM month_reconciliations WHERE user_id = @u ORDER BY month'),
        parameters: {'u': userId},
      );
      final records = <Map<String, Object?>>[];
      for (final r in reconciliations) {
        final month = r[0] as DateTime;
        var invalidatedAt = r[3] as DateTime?;
        // Старый алгоритм снимал подтверждение по одной лишь дате правки.
        // Восстанавливаем его, если все подтверждённые суммы совпадают.
        // FOR SHARE на users не даёт команде изменить журнал в это время.
        if (invalidatedAt != null && reconciliationChanges(r[1] as Map, reconciliationSnapshot(ledger, month, version: reconciliationVersion(r[1] as Map))).isEmpty) {
          await s.execute(Sql.named('UPDATE month_reconciliations SET invalidated_at = NULL WHERE user_id = @u AND month = @m::date'),
            parameters: {'u': userId, 'm': dateToJson(month)});
          invalidatedAt = null;
        }
        records.add({
          'month': dateToJson(month), 'snapshot': r[1],
          'closedAt': (r[2] as DateTime).toUtc().toIso8601String(),
          'invalidatedAt': invalidatedAt?.toUtc().toIso8601String(),
        });
      }
      return {
        'email': u.first[0],
        'name': u.first[5],
        'locale': u.first[1],
        'plan': u.first[2],
        'proUntil': (u.first[6] as DateTime?)?.toIso8601String(),
        'profile': u.first[3],
        'revision': revision,
        'monthReconciliations': records,
        'accounts': [for (final a in ledger.accounts) accountToJson(a)],
        'transactions': [for (final t in ledger.transactions) transactionToJson(t)],
        'reservations': reservationsToJson(ledger),
        'entities': [
          for (final e in entities) {'kind': e[0], 'id': e[1], 'data': e[2]},
        ],
      };
    });
  }

  /// Журнал и справочники владельца для чтения на самом сервере (бот) — без
  /// сборки JSON-снимка всех операций, который нужен только приложению.
  /// Журнал общий с кешем: его можно только читать, и он не меняется после
  /// выдачи — команды работают с копией. Строка владельца читается с
  /// `FOR SHARE`, как в [state]: пока команда не закончилась (commit или
  /// откат), чтение ждёт и видит только подтверждённое. `null` — владельца нет.
  Future<LedgerView?> view(String userId) async {
    return db.runTx((s) async {
      final u = await s.execute(
        Sql.named('SELECT locale, profile, revision FROM users WHERE id = @u FOR SHARE'),
        parameters: {'u': userId},
      );
      if (u.isEmpty) return null;
      final ledger = await _loadLedger(s, userId, u.first[2] as int);
      final rows = await s.execute(
        Sql.named('SELECT kind, id, data FROM entities WHERE user_id = @u ORDER BY updated_at'),
        parameters: {'u': userId},
      );
      final entities = <String, Map<String, Map<String, dynamic>>>{};
      for (final e in rows) {
        entities.putIfAbsent(e[0] as String, () => {})[e[1] as String] = Map<String, dynamic>.from(e[2] as Map);
      }
      return LedgerView(
        ledger: ledger,
        profile: Map<String, dynamic>.from(u.first[1] as Map? ?? const {}),
        locale: u.first[0] as String? ?? 'ru',
        entities: entities,
      );
    });
  }

  // ------------------------------------------------------------ команды

  /// Применяет команду владельца. Возвращает новую ревизию и признак повтора:
  /// команда с тем же `commandId` уже принята и второй раз не применяется.
  Future<({int revision, bool repeated})> command(String userId, Map<String, dynamic> cmd) async {
    final commandId = cmd['commandId'];
    if (commandId is! String || commandId.isEmpty || commandId.length > maxIdLength) {
      throw ApiError(400, 'bad_request');
    }
    try {
      Ledger? published;
      final result = await db.runTx((s) async {
        final u = await s.execute(
          Sql.named('SELECT revision, plan, profile FROM users WHERE id = @u FOR UPDATE'),
          parameters: {'u': userId},
        );
        if (u.isEmpty) throw ApiError(401, 'unauthorized');
        final revision = u.first[0] as int;
        final plan = u.first[1] as String;

        final seen = await s.execute(
          Sql.named('SELECT revision FROM commands WHERE user_id = @u AND id = @id'),
          parameters: {'u': userId, 'id': commandId},
        );
        if (seen.isNotEmpty) return (revision: revision, repeated: true); // повтор уже принятой команды
        if (cmd['type'] == 'closeMonth' && cmd['expectedRevision'] != revision) {
          throw LedgerException('Данные изменились во время сверки', code: 'monthChanged');
        }

        final ledger = await _loadLedger(s, userId, revision, forWrite: true);
        final before = _Snapshot.of(ledger);
        final ctx = _Ctx(s, userId, plan, ledger, Map<String, dynamic>.from(u.first[2] as Map));
        await _apply(ctx, cmd, depth: 0);
        final affected = earliestPostingDate(ledger.transactions.skip(before.txCount));
        if (affected != null) await _invalidateReconciliations(ctx, affected);

        await _persistLedger(s, userId, ledger, before);
        if (ctx.profileChanged) {
          await s.execute(
            Sql.named('UPDATE users SET profile = @p:jsonb WHERE id = @u'),
            parameters: {'p': ctx.profile, 'u': userId},
          );
        }
        final next = revision + 1;
        await s.execute(Sql.named('UPDATE users SET revision = @r WHERE id = @u'), parameters: {'r': next, 'u': userId});
        await s.execute(
          Sql.named('INSERT INTO commands (user_id, id, revision) VALUES (@u, @id, @r)'),
          parameters: {'u': userId, 'id': commandId, 'r': next},
        );
        published = ledger;
        return (revision: next, repeated: false);
      });
      // В кеш — только после commit: до него читатели видят прежний журнал.
      final done = published;
      if (done != null) _remember(userId, _Cached(result.revision, done));
      return result;
    } catch (e) {
      // Журнал в кеше команда не меняла (работала с копией) — он остаётся.
      if (e is LedgerException) throw ApiError(422, 'ledger', message: e.message, ledgerCode: e.code);
      rethrow;
    }
  }

  Future<void> _apply(_Ctx ctx, Map<String, dynamic> c, {required int depth}) async {
    final type = c['type'];
    if (type == 'batch') {
      final items = c['commands'];
      if (depth > 0 || items is! List || items.isEmpty || items.length > maxBatch) {
        throw ApiError(400, 'bad_request');
      }
      for (final item in items) {
        if (item is! Map) throw ApiError(400, 'bad_request');
        await _apply(ctx, item.cast<String, dynamic>(), depth: depth + 1);
      }
      return;
    }
    if (ledgerCommandTypes.contains(type)) {
      if (type == 'adjustment' && c['allowArchived'] == true &&
          !canReconcileMonth(dateFromJson(c['date']), _clock().toUtc().add(const Duration(hours: 5)))) {
        throw LedgerException('Для архивного счёта можно уточнить только завершённый месяц', code: 'monthNotEnded');
      }
      if (type == 'addMoneyAccount' && ctx.plan == 'free') {
        final newId = c['accountId'];
        final active = ctx.ledger.accounts.where((a) => a.isMoney && !a.archived && !isPiggy(a.id)).length;
        if (newId is String && !isPiggy(newId) && active >= freeMoneyAccounts) throw ApiError(402, 'plan_limit');
      }
      if (type == 'archiveAccount' && c['archived'] == false && ctx.plan == 'free') {
        // Возврат из архива не должен обходить лимит обычной версии (C08).
        final id = c['accountId'];
        final active = ctx.ledger.accounts.where((a) => a.isMoney && !a.archived && !isPiggy(a.id)).length;
        if (id is String && !isPiggy(id) && active >= freeMoneyAccounts) throw ApiError(402, 'plan_limit');
      }
      applyLedgerCommand(ctx.ledger, c);
      return;
    }
    switch (type) {
      case 'closeMonth':
        if (depth != 0) throw ApiError(400, 'bad_request');
        await _closeMonth(ctx, dateFromJson(c['month']));
      case 'upsertEntity':
        final kind = c['kind'];
        final id = c['entityId'];
        final data = c['data'];
        if (kind is! String || !entityKinds.contains(kind) || id is! String || id.isEmpty || id.length > maxIdLength || data is! Map) {
          throw ApiError(400, 'bad_request');
        }
        if (utf8.encode(jsonEncode(data)).length > maxEntityBytes) throw ApiError(400, 'bad_request');
        if (kind == 'goal' && ctx.plan == 'free') {
          final others = await ctx.s.execute(
            Sql.named("SELECT count(*) FROM entities WHERE user_id = @u AND kind = 'goal' AND id <> @id"),
            parameters: {'u': ctx.userId, 'id': id},
          );
          if ((others.first[0] as int) >= freeGoals) throw ApiError(402, 'plan_limit');
        }
        if (kind == 'limit' && ctx.plan == 'free') {
          final others = await ctx.s.execute(
            Sql.named("SELECT count(*) FROM entities WHERE user_id = @u AND kind = 'limit' AND id <> @id"),
            parameters: {'u': ctx.userId, 'id': id},
          );
          if ((others.first[0] as int) >= freeLimits) throw ApiError(402, 'plan_limit');
        }
        await ctx.s.execute(
          Sql.named('''
            INSERT INTO entities (user_id, kind, id, data) VALUES (@u, @k, @id, @d:jsonb)
            ON CONFLICT (user_id, kind, id) DO UPDATE SET data = EXCLUDED.data, updated_at = now()'''),
          parameters: {'u': ctx.userId, 'k': kind, 'id': id, 'd': data},
        );
      case setPaidCommand:
        // Отметка срока (R01): ключ добавляется или снимается в актуальной записи
        // под блокировкой строки, а не заменяет её копией, которая могла устареть
        // на другом устройстве. Платёж удалили — отмечать нечего.
        final kind = c['kind'];
        final id = c['entityId'];
        final period = c['period'];
        if ((kind != 'planned' && kind != 'purchase') || id is! String || id.isEmpty || id.length > maxIdLength || period is! String || period.isEmpty || period.length > 20) {
          throw ApiError(400, 'bad_request');
        }
        final rows = await ctx.s.execute(
          Sql.named('SELECT data FROM entities WHERE user_id = @u AND kind = @k AND id = @id FOR UPDATE'),
          parameters: {'u': ctx.userId, 'k': kind, 'id': id},
        );
        if (rows.isNotEmpty) {
          final current = (rows.first[0] as Map).cast<String, dynamic>();
          final next = withPaidMark(current, period, paid: c['paid'] != false, clearGoal: c['clearGoal'] == true);
          await ctx.s.execute(
            Sql.named('UPDATE entities SET data = @d:jsonb, updated_at = now() WHERE user_id = @u AND kind = @k AND id = @id'),
            parameters: {'u': ctx.userId, 'k': kind, 'id': id, 'd': next},
          );
        }
      case 'deleteEntity':
        final kind = c['kind'];
        final id = c['entityId'];
        if (kind is! String || !entityKinds.contains(kind) || id is! String) throw ApiError(400, 'bad_request');
        if (kind == 'goal' && ctx.ledger.reserved(goalId: id) > 0) {
          throw LedgerException('Сначала освободите резерв цели');
        }
        await ctx.s.execute(
          Sql.named('DELETE FROM entities WHERE user_id = @u AND kind = @k AND id = @id'),
          parameters: {'u': ctx.userId, 'k': kind, 'id': id},
        );
      case 'updateProfile':
        final p = c['profile'];
        if (p is! Map) throw ApiError(400, 'bad_request');
        // Старый экран сверял текущие остатки. Его отметку нельзя выдавать
        // за подтверждение исторического снимка: нужна обновлённая версия.
        if (p.containsKey('closedMonths')) {
          final months = p['closedMonths'];
          if (months is! List || months.any((m) => m is! String || !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(m))) {
            throw ApiError(400, 'bad_request');
          }
          final old = (ctx.profile['closedMonths'] as List?) ?? const [];
          for (final key in months) {
            if (!old.contains(key)) {
              final month = dateFromJson('$key-01');
              if (!canReconcileMonth(month, _clock().toUtc().add(const Duration(hours: 5)))) {
                throw LedgerException('Сверка доступна только после окончания месяца', code: 'monthNotEnded');
              }
              throw LedgerException('Обновите приложение, чтобы сверить остатки на конец месяца', code: 'monthClientUpdate');
            }
          }
        }
        for (final e in p.entries) {
          if (!profileKeys.contains(e.key)) throw ApiError(400, 'bad_request');
          ctx.profile[e.key as String] = e.value;
        }
        if (utf8.encode(jsonEncode(ctx.profile)).length > maxProfileBytes) throw ApiError(400, 'bad_request');
        ctx.profileChanged = true;
      default:
        throw ApiError(400, 'bad_request');
    }
  }

  Future<void> _closeMonth(_Ctx ctx, DateTime month) async {
    final start = DateTime(month.year, month.month, 1);
    final today = _clock().toUtc().add(const Duration(hours: 5));
    if (!canReconcileMonth(start, today)) {
      throw LedgerException('Сверка доступна только после окончания месяца', code: 'monthNotEnded');
    }
    await ctx.s.execute(
      Sql.named('''INSERT INTO month_reconciliations (user_id, month, snapshot)
        VALUES (@u, @m::date, @snapshot:jsonb)
        ON CONFLICT (user_id, month) DO UPDATE SET snapshot = EXCLUDED.snapshot,
          closed_at = now(), invalidated_at = NULL'''),
      parameters: {'u': ctx.userId, 'm': dateToJson(start), 'snapshot': reconciliationSnapshot(ctx.ledger, start)},
    );
    final key = dateToJson(start).substring(0, 7);
    final months = {...((ctx.profile['closedMonths'] as List?) ?? const []).cast<String>(), key}.toList()..sort();
    ctx.profile['closedMonths'] = months.length > 60 ? months.sublist(months.length - 60) : months;
    ctx.profileChanged = true;
  }

  Future<void> _invalidateReconciliations(_Ctx ctx, DateTime affected) async {
    final from = DateTime(affected.year, affected.month, 1);
    final rows = await ctx.s.execute(
      Sql.named('SELECT month, snapshot, invalidated_at FROM month_reconciliations WHERE user_id = @u AND month >= @m::date ORDER BY month'),
      parameters: {'u': ctx.userId, 'm': dateToJson(from)},
    );
    final closed = {...((ctx.profile['closedMonths'] as List?) ?? const []).cast<String>()};
    for (final row in rows) {
      final month = row[0] as DateTime;
      final changed = !reconciliationChanges(row[1] as Map, reconciliationSnapshot(ctx.ledger, month, version: reconciliationVersion(row[1] as Map))).isEmpty;
      if (changed != (row[2] != null)) {
        await ctx.s.execute(
          Sql.named('UPDATE month_reconciliations SET invalidated_at = ${changed ? 'now()' : 'NULL'} WHERE user_id = @u AND month = @m::date'),
          parameters: {'u': ctx.userId, 'm': dateToJson(month)},
        );
      }
      final key = dateToJson(month).substring(0, 7);
      final profileChanged = changed ? closed.remove(key) : closed.add(key);
      if (profileChanged) ctx.profileChanged = true;
    }
    if (ctx.profileChanged) {
      final months = closed.toList()..sort();
      ctx.profile['closedMonths'] = months.length > 60 ? months.sublist(months.length - 60) : months;
    }
  }

  Future<void> _persistLedger(Session s, String userId, Ledger ledger, _Snapshot before) async {
    for (final a in ledger.accounts) {
      final json = jsonEncode(accountToJson(a));
      final old = before.accounts[a.id];
      if (old == json) continue;
      await s.execute(
        Sql.named('''
          INSERT INTO ledger_accounts (user_id, id, kind, asset_class, liquid, currency, archived)
          VALUES (@u, @id, @k, @c, @l, @cur, @ar)
          ON CONFLICT (user_id, id) DO UPDATE SET archived = EXCLUDED.archived'''),
        parameters: {'u': userId, 'id': a.id, 'k': a.kind.name, 'c': a.assetClass?.name, 'l': a.liquid, 'cur': a.currency, 'ar': a.archived},
      );
    }
    final txs = ledger.transactions;
    for (var i = before.txCount; i < txs.length; i++) {
      final t = txs[i];
      await s.execute(
        Sql.named('INSERT INTO transactions (user_id, id, date, type, meta, reverses) VALUES (@u, @id, @d::date, @t, @m:jsonb, @r)'),
        parameters: {'u': userId, 'id': t.id, 'd': dateToJson(t.date), 't': t.type.name, 'm': t.meta, 'r': t.reverses},
      );
      for (var n = 0; n < t.postings.length; n++) {
        final p = t.postings[n];
        await s.execute(
          Sql.named('INSERT INTO postings (user_id, tx_id, n, account_id, amount) VALUES (@u, @tx, @n, @a, @v)'),
          parameters: {'u': userId, 'tx': t.id, 'n': n, 'a': p.accountId, 'v': p.amount},
        );
      }
    }
    final reservations = jsonEncode(reservationsToJson(ledger));
    if (reservations != before.reservations) {
      await s.execute(Sql.named('DELETE FROM reservations WHERE user_id = @u'), parameters: {'u': userId});
      for (final r in ledger.reservations) {
        await s.execute(
          Sql.named('INSERT INTO reservations (user_id, goal_id, account_id, amount) VALUES (@u, @g, @a, @v)'),
          parameters: {'u': userId, 'g': r.goalId, 'a': r.accountId, 'v': r.amount},
        );
      }
    }
  }

}

class _Ctx {
  _Ctx(this.s, this.userId, this.plan, this.ledger, this.profile);
  final Session s;
  final String userId;
  final String plan;
  final Ledger ledger;
  final Map<String, dynamic> profile;
  bool profileChanged = false;
}

class _Snapshot {
  _Snapshot(this.accounts, this.txCount, this.reservations);

  factory _Snapshot.of(Ledger l) => _Snapshot(
        {for (final a in l.accounts) a.id: jsonEncode(accountToJson(a))},
        l.transactions.length,
        jsonEncode(reservationsToJson(l)),
      );

  final Map<String, String> accounts;
  final int txCount;
  final String reservations;
}
