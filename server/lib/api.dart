/// HTTP-маршруты API.
library;

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'admin.dart';
import 'admin_page.dart';
import 'ai.dart';
import 'auth_service.dart';
import 'billing.dart';
import 'export.dart';
import 'ledger_service.dart';
import 'notifications.dart';
import 'telegram.dart';

const maxBodyBytes = 512 * 1024;

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Future<Map<String, dynamic>> _body(Request req) async {
  final len = req.contentLength;
  if (len != null && len > maxBodyBytes) throw ApiError(413, 'too_large');
  final text = await req.readAsString();
  if (text.length > maxBodyBytes) throw ApiError(413, 'too_large');
  if (text.isEmpty) return const {};
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  throw ApiError(400, 'bad_request');
}

String? _bearer(Request req) {
  final h = req.headers['authorization'];
  if (h == null || !h.startsWith('Bearer ')) return null;
  return h.substring(7);
}

Handler buildHandler(
  AuthService auth,
  LedgerService ledger,
  NotificationService notifications,
  AdminService admin, {
  required Telegram telegram,
  required BillingService billing,
  required AiService ai,
  String allowedOrigin = '*',
}) {
  Future<String> user(Request req) async {
    final token = _bearer(req);
    final id = token == null ? null : await auth.userIdFor(token);
    if (id == null) throw ApiError(401, 'unauthorized');
    return id;
  }

  final exports = ExportLinks();

  final router = Router()
    // Проверка живости с запросом к базе: по ней следит внешний сторож
    // (deploy/watchdog.sh), поэтому недоступная база должна давать ошибку.
    ..get('/health', (Request _) async {
      try {
        await auth.db.execute('SELECT 1').timeout(const Duration(seconds: 3));
        return _json(200, {'ok': true});
      } catch (_) {
        return _json(503, {'ok': false, 'error': 'db'});
      }
    })
    ..post('/auth/register', (Request req) async {
      final b = await _body(req);
      return _json(201, await auth.register('${b['email'] ?? ''}', '${b['password'] ?? ''}', '${b['locale'] ?? 'ru'}'));
    })
    ..post('/auth/login', (Request req) async {
      final b = await _body(req);
      return _json(200, await auth.login('${b['email'] ?? ''}', '${b['password'] ?? ''}'));
    })
    ..post('/auth/telegram/start', (Request req) async {
      final bot = await telegram.username();
      if (bot == null) throw ApiError(503, 'telegram_unavailable');
      final code = await auth.telegramStart();
      return _json(200, {'code': code, 'url': 'https://t.me/$bot?start=login_$code'});
    })
    ..post('/auth/telegram/check', (Request req) async {
      final b = await _body(req);
      return _json(200, await auth.telegramCheck('${b['code'] ?? ''}', '${b['locale'] ?? 'ru'}'));
    })
    ..post('/auth/logout', (Request req) async {
      final token = _bearer(req);
      if (token != null) await auth.logout(token);
      return _json(200, {'status': 'ok'});
    })
    ..post('/auth/password', (Request req) async {
      final id = await user(req);
      final b = await _body(req);
      await auth.changePassword(id, _bearer(req)!, '${b['current'] ?? ''}', '${b['next'] ?? ''}');
      return _json(200, {'status': 'ok'});
    })
    ..post('/auth/logout-others', (Request req) async {
      final id = await user(req);
      return _json(200, {'closed': await auth.logoutOthers(id, _bearer(req)!)});
    })
    ..get('/auth/sessions', (Request req) async {
      final id = await user(req);
      return _json(200, {'count': await auth.sessionCount(id)});
    })
    ..get('/state', (Request req) async {
      final id = await user(req);
      await auth.touch(id);
      return _json(200, await ledger.state(id));
    })
    ..post('/command', (Request req) async {
      final id = await user(req);
      final r = await ledger.command(id, await _body(req), fromClient: true);
      await auth.touch(id);
      return _json(200, {'revision': r.revision, 'repeated': r.repeated});
    })
    ..post('/auth/locale', (Request req) async {
      final id = await user(req);
      await auth.setLocale(id, '${(await _body(req))['locale'] ?? ''}');
      return _json(200, {'status': 'ok'});
    })
    ..post('/auth/reset', (Request req) async {
      final id = await user(req);
      await resetUserData(auth.db, id);
      ledger.forget(id);
      return _json(200, {'status': 'ok'});
    })
    ..post('/auth/delete', (Request req) async {
      final id = await user(req);
      await deleteUserData(auth.db, id);
      ledger.forget(id);
      return _json(200, {'status': 'ok'});
    })
    // ИИ-консультант (D82): чат по снимку показателей и ежемесячный разбор
    ..get('/ai', (Request req) async => _json(200, await ai.status(await user(req))))
    ..post('/ai/chat', (Request req) async {
      final id = await user(req);
      return _json(200, await ai.chat(id, await _body(req)));
    })
    ..post('/ai/clear', (Request req) async {
      await ai.clear(await user(req));
      return _json(200, {'status': 'ok'});
    })
    ..get('/ai/review/<period>', (Request req, String period) async => _json(200, await ai.reviewFor(await user(req), period)))
    ..post('/ai/review', (Request req) async {
      final id = await user(req);
      return _json(200, await ai.review(id, await _body(req)));
    })
    // Тариф: оплата Pro звёздами Telegram (D52)
    ..get('/billing', (Request req) async => _json(200, await billing.info(await user(req))))
    ..post('/billing/invoice', (Request req) async => _json(200, await billing.invoice(await user(req))))

    // Экспорт: приложение просит одноразовую ссылку и открывает её в браузере.
    ..post('/export/link', (Request req) async {
      final id = await user(req);
      final b = await _body(req);
      final format = b['format'] == 'json' ? 'json' : 'csv';
      final headers = [for (final h in (b['headers'] as List? ?? const [])) '$h'];
      final names = {for (final e in (b['names'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'};
      if (headers.length > 20 || names.length > 5000) throw ApiError(400, 'bad_request');
      final token = exports.create(ExportRequest(
        userId: id,
        format: format,
        headers: headers,
        names: names,
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      ));
      return _json(200, {'path': '/export/$token', 'format': format});
    })
    ..get('/export/<token>', (Request req, String token) async {
      final r = exports.take(token);
      if (r == null) throw ApiError(404, 'not_found');
      final snapshot = await ledger.state(r.userId);
      final day = DateTime.now().toUtc().add(kzOffset).toIso8601String().substring(0, 10);
      if (r.format == 'json') {
        return Response.ok(
          jsonBackup(snapshot, email: '${snapshot['email']}'),
          headers: {
            'content-type': 'application/json; charset=utf-8',
            'content-disposition': 'attachment; filename="famcoin-backup-$day.json"',
            'cache-control': 'no-store',
          },
        );
      }
      return Response.ok(
        csvJournal(snapshot, headers: r.headers, names: r.names),
        headers: {
          'content-type': 'text/csv; charset=utf-8',
          'content-disposition': 'attachment; filename="famcoin-$day.csv"',
          'cache-control': 'no-store',
        },
      );
    })

    // Уведомления
    ..get('/notifications', (Request req) async => _json(200, {'items': await notifications.list(await user(req))}))
    ..post('/notifications/read', (Request req) async {
      await notifications.markRead(await user(req));
      return _json(200, {'status': 'ok'});
    })
    ..get('/notifications/settings', (Request req) async => _json(200, await notifications.settings(await user(req))))
    ..post('/notifications/settings', (Request req) async {
      final id = await user(req);
      await notifications.updateSettings(id, await _body(req));
      return _json(200, await notifications.settings(id));
    })
    ..post('/notifications/test', (Request req) async {
      final id = await user(req);
      final kind = '${(await _body(req))['kind']}';
      final now = DateTime.now().toUtc().add(kzOffset);
      if (kind == 'month') {
        await notifications.sendMonthNudgePreview(id, now);
      } else {
        await notifications.sendBrief(id, kind == 'evening' ? 'evening' : 'morning', DateTime(now.year, now.month, now.day));
      }
      return _json(200, {'status': 'ok'});
    })
    ..get('/push/key', (Request req) async => _json(200, {'key': await notifications.push.publicKey()}))
    ..post('/push/subscribe', (Request req) async {
      final id = await user(req);
      final b = await _body(req);
      try {
        await notifications.push.subscribe(id, '${b['endpoint'] ?? ''}', '${b['p256dh'] ?? ''}', '${b['auth'] ?? ''}');
      } on ArgumentError {
        throw ApiError(400, 'bad_request');
      }
      return _json(200, {'status': 'ok'});
    })
    ..post('/push/unsubscribe', (Request req) async {
      final id = await user(req);
      await notifications.push.unsubscribe(id, '${(await _body(req))['endpoint'] ?? ''}');
      return _json(200, {'status': 'ok'});
    })
    ..post('/telegram/link', (Request req) async {
      final id = await user(req);
      return _json(200, {'code': await notifications.linkCode(id)});
    })
    ..post('/telegram/unlink', (Request req) async {
      await notifications.unlink(await user(req));
      return _json(200, {'status': 'ok'});
    })

    // Админка
    ..get('/admin/', (Request _) => Response.ok(adminHtml, headers: {'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store'}))
    ..get('/admin', (Request _) => Response.found('/api/admin/'))
    ..post('/admin/login', (Request req) async {
      final b = await _body(req);
      return _json(200, {'token': admin.login('${b['password'] ?? ''}')});
    })
    ..get('/admin/stats', (Request req) async {
      admin.require(_bearer(req));
      return _json(200, await admin.stats());
    })
    ..get('/admin/users', (Request req) async {
      admin.require(_bearer(req));
      return _json(200, await admin.users(req.url.queryParameters['q'] ?? ''));
    })
    ..get('/admin/audit', (Request req) async {
      admin.require(_bearer(req));
      return _json(200, await admin.audit());
    })
    ..post('/admin/users/<id>/unlock', (Request req, String id) async {
      admin.require(_bearer(req));
      await admin.unlock(id);
      return _json(200, {'status': 'ok'});
    })
    ..post('/admin/users/<id>/plan', (Request req, String id) async {
      admin.require(_bearer(req));
      await admin.setPlan(id, '${(await _body(req))['plan']}');
      return _json(200, {'status': 'ok'});
    })
    ..post('/admin/users/<id>/reset-password', (Request req, String id) async {
      admin.require(_bearer(req));
      return _json(200, {'password': await admin.resetPassword(id)});
    })
    ..post('/admin/users/<id>/delete', (Request req, String id) async {
      admin.require(_bearer(req));
      await admin.deleteUser(id, '${(await _body(req))['email'] ?? ''}');
      return _json(200, {'status': 'ok'});
    })
    ..get('/admin/payments', (Request req) async {
      admin.require(_bearer(req));
      return _json(200, await billing.all());
    })
    ..get('/admin/payments/inbox', (Request req) async {
      admin.require(_bearer(req));
      return _json(200, await billing.inbox());
    })
    ..post('/admin/payments/inbox/<charge>/retry', (Request req, String charge) async {
      admin.require(_bearer(req));
      final status = await billing.retry(Uri.decodeComponent(charge));
      await admin.audit_('payment_retry', target: null, details: {'charge': Uri.decodeComponent(charge), 'status': status});
      return _json(200, {'status': status});
    })
    ..post('/admin/payments/<id>/refund', (Request req, String id) async {
      admin.require(_bearer(req));
      await billing.refund(id);
      await admin.audit_('refund', target: null, details: {'payment': id});
      return _json(200, {'status': 'ok'});
    });

  Middleware errors() => (inner) => (req) async {
        try {
          // Клиент ждёт 20 секунд; дольше держать сокет открытым незачем.
          return await Future.sync(() => inner(req)).timeout(const Duration(seconds: 30));
        } on TimeoutException {
          print('timeout on ${req.method} ${req.url.path}');
          return _json(504, {'error': 'timeout'});
        } on ApiError catch (e) {
          return _json(e.status, e.toJson());
        } catch (e, st) {
          // Тексты операций и пароли в журнал сервера не пишутся.
          print('internal error on ${req.method} ${req.url.path}: ${e.runtimeType}\n$st');
          return _json(500, {'error': 'internal'});
        }
      };

  final cors = {
    'access-control-allow-origin': allowedOrigin,
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'content-type, authorization',
  };
  Middleware corsMw() => (inner) => (req) async {
        if (req.method == 'OPTIONS') return Response.ok('', headers: cors);
        final res = await inner(req);
        return res.change(headers: cors);
      };

  return const Pipeline().addMiddleware(corsMw()).addMiddleware(errors()).addHandler(router.call);
}
