/// Push-уведомления доступны только в веб-сборке; здесь — заглушка.
library;

Future<String> pushStatus() async => 'unsupported';

Future<Map<String, dynamic>?> pushEnable(String vapidKey) async => null;

Future<String> pushDisable() async => '';
