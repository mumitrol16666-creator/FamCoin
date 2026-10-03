/// Слова PDF-файла с координатами — из них собирается таблица выписки банка
/// (D94).
///
/// Текст достаёт `pdftotext -bbox` (пакет poppler-utils): для каждого слова —
/// страница и рамка. Файл прислал человек, поэтому разборщик запускается
/// отдельным процессом без переменных окружения сервера (в них ключи и
/// пароли), с ограничением времени и, где это доступно, без прав и с потолком
/// памяти. Какой способ запуска работает на этой машине, проверяется один раз
/// при старте на крошечном собственном PDF; без `pdftotext` импорт выключен.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class PdfWord {
  const PdfWord(this.page, this.x0, this.y0, this.x1, this.y1, this.text);

  /// Номер страницы с нуля.
  final int page;

  /// Рамка слова в пунктах; `y` растёт вниз.
  final double x0;
  final double y0;
  final double x1;
  final double y1;
  final String text;

  double get yMid => (y0 + y1) / 2;
  double get height => y1 - y0;
}

final _tag = RegExp(
  r'<page\b[^>]*>|<word\s+xMin="([-\d.,]+)"\s+yMin="([-\d.,]+)"\s+xMax="([-\d.,]+)"\s+yMax="([-\d.,]+)"\s*>([^<]*)</word>',
);
final _entity = RegExp(r'&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);');

String _unescape(String s) => s.replaceAllMapped(_entity, (m) {
      final e = m[1]!;
      return switch (e) {
        'amp' => '&',
        'lt' => '<',
        'gt' => '>',
        'quot' => '"',
        'apos' => "'",
        _ => String.fromCharCode(e.startsWith('#x') ? int.parse(e.substring(2), radix: 16) : int.parse(e.substring(1))),
      };
    });

double _number(String s) => double.tryParse(s.replaceAll(',', '.')) ?? 0;

/// Слова из вывода `pdftotext -bbox`: `<page …>` и `<word xMin yMin xMax yMax>`.
List<PdfWord> parseBboxWords(String xhtml) {
  final words = <PdfWord>[];
  var page = -1;
  for (final m in _tag.allMatches(xhtml)) {
    if (m[1] == null) {
      page++;
      continue;
    }
    final text = _unescape(m[5]!).trim();
    if (text.isEmpty || page < 0) continue;
    words.add(PdfWord(page, _number(m[1]!), _number(m[2]!), _number(m[3]!), _number(m[4]!), text));
  }
  return words;
}

/// Крошечный PDF с одним словом — для проверки, что разборщик запускается.
List<int> probePdf(String word) {
  final stream = 'BT /F1 18 Tf 40 120 Td ($word) Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return latin1.encode(out.toString());
}

/// Способ запуска разборщика: команда с ведущими аргументами и то, как ему
/// передаётся файл — через стандартный ввод или временным файлом.
class _Launch {
  const _Launch(this.label, this.command, {this.files = false});
  final String label;
  final List<String> command;
  final bool files;
}

const _unprivileged = ['setpriv', '--reuid=65534', '--regid=65534', '--clear-groups', '--no-new-privs'];

/// От самого строгого к самому простому; берётся первый, что сработал на
/// проверочном файле. Потолок памяти — 512 МБ на разбор: выписке хватает
/// десятков мегабайт, а два файла-«бомбы» разом не выберут память контейнера.
const _launches = [
  _Launch('без прав, с потолком памяти и времени', ['prlimit', '--cpu=30', '--as=536870912', ..._unprivileged, 'pdftotext']),
  _Launch('без прав', [..._unprivileged, 'pdftotext']),
  _Launch('обычный запуск', ['pdftotext']),
  _Launch('обычный запуск через временный файл', ['pdftotext'], files: true),
];

class PdfReader {
  PdfReader({this.maxPages = 200, this.timeout = const Duration(seconds: 25)});

  final int maxPages;
  final Duration timeout;

  /// Больше такого вывода у выписки не бывает; защита от файла-«бомбы».
  static const maxOutputBytes = 40 * 1024 * 1024;

  _Launch? _launch;

  bool get enabled => _launch != null;

  /// Как запускается разборщик — для строки в журнале при старте.
  String get describe => _launch?.label ?? 'нет pdftotext';

  /// Выбирает рабочий способ запуска. `false` — разборщика нет.
  Future<bool> probe() async {
    final sample = probePdf('FamCoin');
    for (final l in _launches) {
      final words = await _words(l, sample);
      if (words != null && words.any((w) => w.text == 'FamCoin')) {
        _launch = l;
        return true;
      }
    }
    _launch = null;
    return false;
  }

  /// Слова файла; `null` — файл не читается как PDF (или разборщика нет).
  Future<List<PdfWord>?> words(List<int> pdf) async {
    final l = _launch;
    if (l == null || !_looksLikePdf(pdf)) return null;
    return _words(l, pdf);
  }

  /// Файл начинается с «%PDF-». Сравнение побайтно, без декодирования:
  /// чужой ввод может быть чем угодно, в том числе не байтами вовсе, и
  /// декодер на нём бросал исключение вместо «не прочитал».
  static bool _looksLikePdf(List<int> bytes) {
    const magic = [0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  Future<List<PdfWord>?> _words(_Launch l, List<int> pdf) async {
    Directory? dir;
    try {
      var input = '-';
      var output = '-';
      if (l.files) {
        dir = await Directory.systemTemp.createTemp('famcoin-pdf');
        input = '${dir.path}/in.pdf';
        output = '${dir.path}/out.html';
        await File(input).writeAsBytes(pdf, flush: true);
      }
      final p = await Process.start(
        l.command.first,
        [...l.command.skip(1), '-bbox', '-enc', 'UTF-8', '-l', '$maxPages', input, output],
        // Разборщику чужого файла не нужны ключи и пароли сервера.
        includeParentEnvironment: false,
        environment: const {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/homebrew/bin', 'LC_ALL': 'C'},
      );
      // Процесс мог завершиться, не дочитав ввод, — это не ошибка сервера.
      unawaited(p.stdin.done.catchError((Object _) {}));
      if (!l.files) p.stdin.add(pdf);
      unawaited(p.stdin.close().catchError((Object _) {}));

      final out = BytesBuilder(copy: false);
      var tooBig = false;
      final outDone = p.stdout.listen((chunk) {
        if (out.length + chunk.length > maxOutputBytes) {
          tooBig = true;
        } else {
          out.add(chunk);
        }
      }).asFuture<void>().catchError((Object _) {});
      final errDone = p.stderr.drain<void>().catchError((Object _) {});
      final code = await p.exitCode.timeout(timeout, onTimeout: () {
        p.kill(ProcessSignal.sigkill);
        return -1;
      });
      await outDone;
      await errDone;
      if (code != 0 || tooBig) return null;
      var bytes = out.takeBytes();
      if (l.files) {
        final file = File(output);
        if (!await file.exists() || await file.length() > maxOutputBytes) return null;
        bytes = await file.readAsBytes();
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      return text.contains('<page') ? parseBboxWords(text) : null;
    } on ProcessException {
      return null; // команды нет на этой машине
    } catch (e) {
      stderr.writeln('pdf: ${e.runtimeType}');
      return null;
    } finally {
      if (dir != null) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}
