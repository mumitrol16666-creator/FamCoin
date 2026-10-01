-- FamCoin: один Telegram-чат — один аккаунт (D78).
--
-- До сих пор это держалось только на порядке действий в коде. Индекс делает
-- правило свойством базы: два аккаунта с одним чатом невозможны даже при гонке.
-- Если бы дубли уже существовали, чат остаётся у самого раннего аккаунта
-- (на момент миграции дублей на сервере нет — запрос ничего не меняет).
UPDATE users u SET telegram_chat_id = NULL
WHERE u.telegram_chat_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM users o
    WHERE o.telegram_chat_id = u.telegram_chat_id
      AND (o.created_at, o.id) < (u.created_at, u.id));

CREATE UNIQUE INDEX IF NOT EXISTS users_telegram_chat_key
  ON users (telegram_chat_id) WHERE telegram_chat_id IS NOT NULL;
