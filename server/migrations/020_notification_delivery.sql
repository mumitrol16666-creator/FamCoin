-- FamCoin: уведомление сначала сохраняется, потом доставляется (D158, аудит 08.10 CS05).
-- Раньше отметка «сводка/напоминание отправлены» ставилась до сохранения
-- уведомления: сбой между ними терял напоминание насовсем.
--   dedup_key — одно уведомление на ключ (вид + день или месяц): второй
--               обработчик или перезапуск не создают дубль;
--   deliver_* — внешняя доставка (Telegram, push), отдельно от записи в
--               приложении: повторяется сама, сбой не теряет уведомление;
--   tg_done / push_done — канал уже доставлен, повтор его не дублирует.
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS dedup_key text;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS open_query text;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS deliver_status text NOT NULL DEFAULT 'done'
  CHECK (deliver_status IN ('pending', 'done', 'failed'));
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS deliver_attempts int NOT NULL DEFAULT 0;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS deliver_next_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS deliver_error text;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS tg_done boolean NOT NULL DEFAULT false;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS push_done boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX IF NOT EXISTS notifications_dedup_idx ON notifications (user_id, dedup_key) WHERE dedup_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS notifications_deliver_idx ON notifications (deliver_next_at) WHERE deliver_status = 'pending';
