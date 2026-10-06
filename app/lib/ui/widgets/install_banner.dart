import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/api_client.dart' show apiUrl;
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import 'browser_platform_stub.dart'
    if (dart.library.js_interop) 'browser_platform_web.dart' as browser;
import 'common.dart';


/// Ссылка на Android-приложение на нашем сервере.
String get apkUrl => '${apiUrl.replaceFirst(RegExp(r'/api$'), '')}/download/famcoin.apk';

/// Показывать ли плашку «Скачайте приложение»: сайт открыт в браузере на
/// Android, не как установленное «на экран Домой», и человек её не закрывал.
bool shouldShowInstallBanner({required bool web, required bool androidBrowser, required bool standalone, required bool dismissed}) =>
    web && androidBrowser && !standalone && !dismissed;

/// Плашка для тех, кто сидит с Android в браузере: предлагает скачать приложение.
/// Закрывается кнопкой «Позже» насовсем на этом устройстве.
/// Параметры [web], [androidBrowser], [standalone] — для тестов; в приложении
/// они определяются сами.
class InstallBanner extends StatelessWidget {
  const InstallBanner({super.key, this.web, this.androidBrowser, this.standalone, this.rounded = false});

  final bool? web;
  final bool? androidBrowser;
  final bool? standalone;

  /// На экране входа плашка — карточка, а не полоса во всю ширину.
  final bool rounded;

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final show = shouldShowInstallBanner(
          web: web ?? kIsWeb,
          androidBrowser: androidBrowser ?? browser.isAndroidBrowser,
          standalone: standalone ?? browser.isStandalonePwa,
          dismissed: settings.installBannerDismissed,
        );
        if (!show) return const SizedBox.shrink();
        final l = context.l10n;
        final fam = context.fam;
        // Текст сверху, кнопки под ним: в одну строку на узком экране и крупном
        // шрифте они не помещаются.
        final row = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.android, color: fam.onAccent, size: 22)),
            const SizedBox(width: 10),
            Expanded(child: Text(l.installBannerText, style: TextStyle(color: fam.onAccent, fontWeight: FontWeight.w600, fontSize: 13))),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, children: [
              TextButton(onPressed: settings.dismissInstallBanner, child: Text(l.later, style: TextStyle(color: fam.onAccent))),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: fam.onAccent, foregroundColor: fam.accent, minimumSize: const Size(0, 40)),
                onPressed: () => launchUrl(Uri.parse(apkUrl), mode: LaunchMode.externalApplication),
                child: Text(l.updateDownload),
              ),
            ]),
          ),
        ]);
        final padded = Padding(padding: const EdgeInsets.fromLTRB(16, 10, 8, 6), child: row);
        return Material(
          color: fam.accent,
          borderRadius: rounded ? BorderRadius.circular(14) : null,
          child: rounded ? padded : SafeArea(bottom: false, child: padded),
        );
      },
    );
  }
}
