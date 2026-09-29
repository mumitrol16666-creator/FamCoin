import 'api_client.dart';
import 'models.dart';

typedef CommandAction = Future<void> Function(String commandId);

/// Holds an immutable action closure until the server result is known.
/// A network error or an unsuccessful refresh after commit MUST NOT release
/// the key: retrying then reconciles the original mutation, never creates another.
class RetryableAction {
  CommandAction? _action;
  String? _id;
  bool _busy = false;
  bool get pending => _action != null;

  Future<void> run(CommandAction? action) async {
    if (_busy) throw StateError('An action is already in flight');
    if (_action == null) {
      if (action == null) throw StateError('No action to retry');
      _action = action;
      _id = newId();
    }
    _busy = true;
    try {
      await _action!(_id!);
      _clear();
    } on ApiException catch (e) {
      // These are explicit application rejections, before commit. A GET
      // refresh cannot return these errors; all ambiguous failures keep the key.
      if ((e.status == 422 && e.code == 'ledger') ||
          (e.status == 402 && e.code == 'plan_limit') ||
          (e.status == 400 && e.code == 'bad_request')) {
        _clear();
      }
      rethrow;
    } finally {
      _busy = false;
    }
  }

  void _clear() {
    _action = null;
    _id = null;
  }
}
