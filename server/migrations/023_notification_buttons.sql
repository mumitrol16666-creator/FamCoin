-- Кнопки Telegram под уведомлением (D167): быстрые операции в пустой вечер.
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS tg_buttons jsonb;
