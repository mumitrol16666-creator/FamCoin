/// Web Push: шифрование сообщений (RFC 8291, aes128gcm), подпись VAPID
/// (RFC 8292, ES256) и отправка на адрес подписки браузера.
///
/// Пара ключей VAPID создаётся при первом запуске и хранится в базе.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:postgres/postgres.dart';

String b64u(List<int> b) => base64Url.encode(b).replaceAll('=', '');
Uint8List unb64u(String s) => base64Url.decode(base64Url.normalize(s));

final _curve = ECDomainParameters('prime256v1');

Uint8List _fixed(BigInt v, int len) {
  final out = Uint8List(len);
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

/// Несжатая точка: 0x04 || X || Y (65 байт).
Uint8List _point(ECPoint p) => Uint8List.fromList([4, ..._fixed(p.x!.toBigInteger()!, 32), ..._fixed(p.y!.toBigInteger()!, 32)]);

Uint8List _hmac(List<int> key, List<int> data) => Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

Uint8List _rand(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// Шифрует [payload] для подписки: открытый ключ браузера и секрет аутентификации.
Uint8List encryptPayload(Uint8List payload, {required Uint8List uaPublic, required Uint8List authSecret, Uint8List? salt, BigInt? ephemeral}) {
  final gen = ECKeyGenerator()
    ..init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), SecureRandom('Fortuna')..seed(KeyParameter(_rand(32)))));
  ECPrivateKey asPriv;
  ECPublicKey asPub;
  if (ephemeral != null) {
    asPriv = ECPrivateKey(ephemeral, _curve);
    asPub = ECPublicKey(_curve.G * ephemeral, _curve);
  } else {
    final pair = gen.generateKeyPair();
    asPriv = pair.privateKey;
    asPub = pair.publicKey;
  }
  final uaPoint = _curve.curve.decodePoint(uaPublic);
  if (uaPoint == null) throw ArgumentError('bad p256dh');
  final agreement = ECDHBasicAgreement()..init(asPriv);
  final shared = _fixed(agreement.calculateAgreement(ECPublicKey(uaPoint, _curve)), 32);
  final asPublic = _point(asPub.Q!);

  final s = salt ?? _rand(16);
  final prkKey = _hmac(authSecret, shared);
  final keyInfo = Uint8List.fromList([...utf8.encode('WebPush: info'), 0, ...uaPublic, ...asPublic, 1]);
  final ikm = _hmac(prkKey, keyInfo);
  final prk = _hmac(s, ikm);
  final cek = _hmac(prk, [...utf8.encode('Content-Encoding: aes128gcm'), 0, 1]).sublist(0, 16);
  final nonce = _hmac(prk, [...utf8.encode('Content-Encoding: nonce'), 0, 1]).sublist(0, 12);

  final cipher = GCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(cek), 128, nonce, Uint8List(0)));
  final sealed = cipher.process(Uint8List.fromList([...payload, 2]));
  return Uint8List.fromList([...s, 0, 0, 0x10, 0, asPublic.length, ...asPublic, ...sealed]);
}

class VapidKeys {
  VapidKeys(this.d)
      : publicKey = _point((_curve.G * d)!);

  final BigInt d;
  final Uint8List publicKey;

  String get publicKeyB64 => b64u(publicKey);

  static VapidKeys generate() {
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), SecureRandom('Fortuna')..seed(KeyParameter(_rand(32)))));
    return VapidKeys(gen.generateKeyPair().privateKey.d!);
  }

  /// JWT для заголовка Authorization; [audience] — источник адреса подписки.
  String jwt(String audience, String subject, {Duration ttl = const Duration(hours: 12)}) {
    final exp = DateTime.now().toUtc().add(ttl).millisecondsSinceEpoch ~/ 1000;
    final head = b64u(utf8.encode('{"typ":"JWT","alg":"ES256"}'));
    final claims = b64u(utf8.encode(jsonEncode({'aud': audience, 'exp': exp, 'sub': subject})));
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter(ECPrivateKey(d, _curve)));
    final sig = signer.generateSignature(Uint8List.fromList(utf8.encode('$head.$claims'))) as ECSignature;
    return '$head.$claims.${b64u([..._fixed(sig.r, 32), ..._fixed(sig.s, 32)])}';
  }
}

/// Контакт для VAPID: адрес сайта, а без него — заглушка (push-сервисы её принимают).
String pushSubject(String? origin) => origin != null && origin.startsWith('https://') ? origin : 'mailto:admin@famcoin.kz';

class PushSubscription {
  PushSubscription(this.id, this.endpoint, this.p256dh, this.auth);
  final String id;
  final String endpoint;
  final String p256dh;
  final String auth;
}

class WebPush {
  WebPush(this.db, {required this.subject});

  final Pool db;
  final String subject;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  VapidKeys? _keys;

  Future<VapidKeys> keys() async {
    if (_keys != null) return _keys!;
    final r = await db.execute("SELECT value FROM push_config WHERE key = 'vapid_private'");
    if (r.isNotEmpty) return _keys = VapidKeys(BigInt.parse(r.first[0] as String, radix: 16));
    final k = VapidKeys.generate();
    // ON CONFLICT: при гонке двух запусков побеждает первая запись.
    await db.execute(
      Sql.named("INSERT INTO push_config (key, value) VALUES ('vapid_private', @v) ON CONFLICT DO NOTHING"),
      parameters: {'v': k.d.toRadixString(16)},
    );
    final again = await db.execute("SELECT value FROM push_config WHERE key = 'vapid_private'");
    return _keys = VapidKeys(BigInt.parse(again.first[0] as String, radix: 16));
  }

  Future<String> publicKey() async => (await keys()).publicKeyB64;

  Future<void> subscribe(String userId, String endpoint, String p256dh, String auth) async {
    final uri = Uri.tryParse(endpoint);
    if (uri == null || uri.scheme != 'https' || endpoint.length > 2000) throw ArgumentError('bad endpoint');
    final pk = unb64u(p256dh);
    if (pk.length != 65 || unb64u(auth).length != 16) throw ArgumentError('bad keys');
    await db.execute(
      Sql.named('''
        INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth) VALUES (@u, @e, @p, @a)
        ON CONFLICT (endpoint) DO UPDATE SET user_id = @u, p256dh = @p, auth = @a'''),
      parameters: {'u': userId, 'e': endpoint, 'p': p256dh, 'a': auth},
    );
  }

  Future<void> unsubscribe(String userId, String endpoint) => db.execute(
        Sql.named('DELETE FROM push_subscriptions WHERE user_id = @u AND endpoint = @e'),
        parameters: {'u': userId, 'e': endpoint},
      );

  Future<int> deviceCount(String userId) async {
    final r = await db.execute(Sql.named('SELECT count(*) FROM push_subscriptions WHERE user_id = @u'), parameters: {'u': userId});
    return r.first[0] as int;
  }

  /// Отправляет на все устройства пользователя; мёртвые подписки удаляет.
  /// `false` — хотя бы одному устройству доставить не удалось (временная
  /// ошибка, повтор имеет смысл); устаревшие подписки удаляются и ошибкой не
  /// считаются. Без подписок — `true`.
  Future<bool> sendToUser(String userId, String title, String body, {String tag = 'famcoin', String? url}) async {
    final rows = await db.execute(
      Sql.named('SELECT id, endpoint, p256dh, auth FROM push_subscriptions WHERE user_id = @u'),
      parameters: {'u': userId},
    );
    if (rows.isEmpty) return true;
    var ok = true;
    final k = await keys();
    final payload = utf8.encode(jsonEncode({'title': title, 'body': body, 'tag': tag, if (url != null) 'url': url}));
    for (final r in rows) {
      final sub = PushSubscription(r[0].toString(), r[1] as String, r[2] as String, r[3] as String);
      try {
        final status = await _send(k, sub, Uint8List.fromList(payload));
        if (status == 404 || status == 410) {
          await db.execute(Sql.named('DELETE FROM push_subscriptions WHERE id = @i'), parameters: {'i': sub.id});
        } else if (status >= 300) {
          stderr.writeln('webpush: ${Uri.parse(sub.endpoint).host} ответил $status');
          ok = false;
        }
      } catch (e) {
        stderr.writeln('webpush: ${e.runtimeType}');
        ok = false;
      }
    }
    return ok;
  }

  Future<int> _send(VapidKeys k, PushSubscription sub, Uint8List payload) async {
    final uri = Uri.parse(sub.endpoint);
    final body = encryptPayload(payload, uaPublic: unb64u(sub.p256dh), authSecret: unb64u(sub.auth));
    final req = await _client.postUrl(uri);
    req.headers
      ..set('Authorization', 'vapid t=${k.jwt('${uri.scheme}://${uri.authority}', subject)}, k=${k.publicKeyB64}')
      ..set('Content-Encoding', 'aes128gcm')
      ..set('Content-Type', 'application/octet-stream')
      ..set('TTL', '43200')
      ..set('Urgency', 'normal');
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close().timeout(const Duration(seconds: 20));
    await res.drain<void>();
    return res.statusCode;
  }
}
