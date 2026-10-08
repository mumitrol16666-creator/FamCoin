-- FamCoin: возврат звёзд с сохраняемым намерением (D159, аудит 08.10 CS06).
-- Раньше внешний возврат в Telegram шёл до локальной записи: если Telegram
-- звёзды вернул, а транзакция не прошла, платёж оставался «оплачен» и Pro
-- действовал, а повторный возврат Telegram отклонял.
--   refund_requested — намерение сохранено до обращения к Telegram;
--   refunded         — Telegram подтвердил (или ответил «уже возвращено»),
--                      срок Pro уменьшен — ровно один раз.
ALTER TABLE payments ADD COLUMN IF NOT EXISTS refund_requested_at timestamptz;
ALTER TABLE payments DROP CONSTRAINT IF EXISTS payments_status_check;
ALTER TABLE payments ADD CONSTRAINT payments_status_check CHECK (status IN ('paid', 'refund_requested', 'refunded'));
