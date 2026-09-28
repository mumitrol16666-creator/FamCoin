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

const entityKinds = {'account', 'member', 'limit', 'goal', 'planned', 'debt', 'category', 'quick'};
const profileKeys = {'mode', 'onboarded', 'incomeDay', 'budgetMethod', 'hiddenCategories', 'dailyLimit', 'firstName', 'lastName', 'birthDate'};
const maxEntityBytes = 8 * 1024;
const maxBatch = 200;

/// Ограничения обычного тарифа (D05).
const freeMoneyAccounts = 1;
const freeLimits = 2;
const freeGoals = 1;

/// Счета-копилки целей не расходуют лимит денежных счетов обычного тарифа.
bool isPiggy(String accountId) => accountId.startsWith('piggy');

class _Cached {
  _Cached(this.revision, this.ledger);
  final int revision;
  final Ledger ledger;
}

class LedgerService {
  LedgerService(this.db);

  final Pool db;

  /// Журналы в памяти по ревизии владельца: без повторного чтения всей
  /// истории на каждую команду.
  final Map<String, _Cached> _cache = {};

  /// Забыть журнал владельца (после удаления аккаунта).
  void forget(String userId) => _cache.remove(userId);

  // --------------------------------------------------------------- чтение

  Future<Ledger> _loadLedger(Session s, String userId, int revision) async {
    final cached = _cache[userId];
    if (cached != null && cached.revision == revision) return cached.ledger;

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
    _cache[userId] = _Cached(revision, ledger);
    return ledger;
  }

  Future<Map<String, Object?>> state(String userId) async {
    return db.runTx((s) async {
      final u = await s.execute(
        Sql.named('SELECT email, locale, plan, profile, revision, display_name, pro_until FROM users WHERE id = @u'),
        parameters: {'u': userId},
      );
      if (u.isEmpty) throw ApiError(401, 'unauthorized');
      final revision = u.first[4] as int;
      final ledger = await _loadLedger(s, userId, revision);
      final entities = await s.execute(
        Sql.named('SELECT kind, id, data FROM entities WHERE user_id = @u ORDER BY updated_at'),
        parameters: {'u': userId},
      );
      return {
        'email': u.first[0],
        'name': u.first[5],
        'locale': u.first[1],
        'plan': u.first[2],
        'proUntil': (u.first[6] as DateTime?)?.toIso8601String(),
        'profile': u.first[3],
        'revision': revision,
        'accounts': [for (final a in ledger.accounts) accountToJson(a)],
        'transactions': [for (final t in ledger.transactions) transactionToJson(t)],
        'reservations': reservationsToJson(ledger),
        'entities': [
          for (final e in entities) {'kind': e[0], 'id': e[1], 'data': e[2]},
        ],
      };
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
      return await db.runTx((s) async {
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

        final ledger = await _loadLedger(s, userId, revision);
        final before = _Snapshot.of(ledger);
        final ctx = _Ctx(s, userId, plan, ledger, Map<String, dynamic>.from(u.first[2] as Map));
        await _apply(ctx, cmd, depth: 0);

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
        _cache[userId] = _Cached(next, ledger);
        return (revision: next, repeated: false);
      });
    } catch (e) {
      // Журнал в памяти мог измениться до отказа — перечитываем из базы.
      _cache.remove(userId);
      if (e is LedgerException) throw ApiError(422, 'ledger', message: e.message);
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
      if (type == 'addMoneyAccount' && ctx.plan == 'free') {
        final newId = c['accountId'];
        final active = ctx.ledger.accounts.where((a) => a.isMoney && !a.archived && !isPiggy(a.id)).length;
        if (newId is String && !isPiggy(newId) && active >= freeMoneyAccounts) throw ApiError(402, 'plan_limit');
      }
      applyLedgerCommand(ctx.ledger, c);
      return;
    }
    switch (type) {
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
        for (final e in p.entries) {
          if (!profileKeys.contains(e.key)) throw ApiError(400, 'bad_request');
          ctx.profile[e.key as String] = e.value;
        }
        ctx.profileChanged = true;
      default:
        throw ApiError(400, 'bad_request');
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
