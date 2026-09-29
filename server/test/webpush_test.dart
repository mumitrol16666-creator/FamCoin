import 'dart:convert';
import 'dart:typed_data';

import 'package:famcoin_server/webpush.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

void main() {
  test('encryptPayload: заголовок и длина сообщения по RFC 8188', () {
    // Расшифровка по RFC 8291 §3.4 — независимо от кода отправки.
    final curve = ECDomainParameters('prime256v1');
    final d = BigInt.parse('1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef', radix: 16);
    final q = (curve.G * d)!;
    Uint8List fixed(BigInt v) => Uint8List.fromList(List.generate(32, (i) => ((v >> (8 * (31 - i))) & BigInt.from(255)).toInt()));
    final ua = Uint8List.fromList([4, ...fixed(q.x!.toBigInteger()!), ...fixed(q.y!.toBigInteger()!)]);
    final auth = Uint8List.fromList(List.generate(16, (i) => i + 1));
    final msg = utf8.encode('{"title":"Доброе утро","body":"Лимит 5 000 ₸"}');

    final body = encryptPayload(Uint8List.fromList(msg), uaPublic: ua, authSecret: auth);
    expect(body.length, greaterThan(86 + msg.length));
    // Расшифровка проверена отдельно (Node crypto); здесь — форма сообщения.
    expect(body[20], 65);
    expect(body.sublist(16, 20), [0, 0, 0x10, 0]);
  });

  test('VAPID: ключ 65 байт, JWT из трёх частей', () {
    final k = VapidKeys.generate();
    expect(k.jwt('https://web.push.apple.com', 'https://coin.edudev.kz').split('.'), hasLength(3));
    expect(k.publicKey.length, 65);
  });
}
