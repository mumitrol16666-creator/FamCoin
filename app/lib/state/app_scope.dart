import 'package:flutter/widgets.dart';

import 'app_state.dart';
import 'settings.dart';

/// Кто сверху: фоновые анимации останавливаются, пока открыт другой экран.
final routeObserver = RouteObserver<ModalRoute<void>>();

/// Доступ к настройкам и данным владельца из дерева виджетов.
/// [state] доступен только после входа.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.settings, this.stateOrNull, required super.child});

  final Settings settings;
  final AppState? stateOrNull;

  AppState get state => stateOrNull!;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      settings != oldWidget.settings || stateOrNull != oldWidget.stateOrNull;
}
