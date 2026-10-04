/// Push-уведомления доступны только в веб-сборке; здесь — заглушка.
library;

Future<String> pushStatus() async => 'unsupported';
Future<String> pushRequestPermission() async => 'unsupported';
void pushConfirmEnabled() {}

Future<Map<String, dynamic>?> pushEnable(String vapidKey) async => null;

Future<String> pushDisable() async => '';
