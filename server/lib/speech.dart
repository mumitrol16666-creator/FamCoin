/// Распознавание речи для голосовых сообщений бота (D80).
///
/// Аудио уходит поставщику ИИ, обратно приходит только текст; дальше он
/// разбирается теми же правилами, что и набранное сообщение. Работает только
/// при заданном OPENAI_API_KEY — без ключа бот просит написать текстом.
library;

import 'dart:convert';
import 'dart:io';

class Transcript {
  const Transcript(this.text, {this.tokensIn = 0, this.tokensOut = 0});
  final String text;
  final int tokensIn;
  final int tokensOut;
}

class Speech {
  Speech({required this.apiKey, String? model}) : model = model == null || model.isEmpty ? 'gpt-4o-mini-transcribe' : model;

  final String? apiKey;
  final String model;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  bool get enabled => apiKey != null && apiKey!.isNotEmpty;

  /// Подсказка модели: о чём обычно говорят и как пишутся частые слова.
  static const _hint = 'Запись о трате или доходе в тенге: кофе 1500, такси 2 тысячи вчера, продукты 12400 с каспи, зарплата 350000, жалақы, азық-түлік 5 мың.';

  /// Текст голосового сообщения; `null` — распознать не удалось.
  /// [audio] — файл Telegram (OGG/Opus).
  Future<Transcript?> transcribe(List<int> audio) async {
    if (!enabled) return null;
    try {
      return await _post(audio).timeout(const Duration(seconds: 40));
    } catch (e) {
      stderr.writeln('speech: ${e.runtimeType}');
      return null;
    }
  }

  Future<Transcript?> _post(List<int> audio) async {
    const boundary = '----famcoin-voice-7d1c9a4e';
    String field(String name, String value) => '--$boundary\r\nContent-Disposition: form-data; name="$name"\r\n\r\n$value\r\n';
    final head = utf8.encode('${field('model', model)}${field('prompt', _hint)}${field('response_format', 'json')}'
        '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="voice.ogg"\r\nContent-Type: audio/ogg\r\n\r\n');
    final tail = utf8.encode('\r\n--$boundary--\r\n');

    final req = await _client.postUrl(Uri.parse('https://api.openai.com/v1/audio/transcriptions'));
    req.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
      ..set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
    req.contentLength = head.length + audio.length + tail.length;
    req
      ..add(head)
      ..add(audio)
      ..add(tail);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      // Тело ответа об ошибке ключ не содержит; обрезаем на случай длинного текста.
      stderr.writeln('speech: HTTP ${res.statusCode} ${body.length > 200 ? body.substring(0, 200) : body}');
      return null;
    }
    final data = jsonDecode(body) as Map<String, dynamic>;
    final usage = data['usage'] as Map<String, dynamic>? ?? const {};
    return Transcript(
      (data['text'] as String? ?? '').trim(),
      tokensIn: (usage['input_tokens'] as num?)?.toInt() ?? 0,
      tokensOut: (usage['output_tokens'] as num?)?.toInt() ?? 0,
    );
  }
}
