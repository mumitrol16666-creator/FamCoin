-- FamCoin: подключение ИИ-консультанта (D82). Вопрос и ответ одной отправки
-- связываются общим request_id — тем же, по которому списывается квота в
-- ai_usage: повтор отправки (двойное нажатие, обрыв сети) возвращает уже
-- сохранённый ответ, не спрашивая модель второй раз.
ALTER TABLE ai_messages ADD COLUMN IF NOT EXISTS request_id text;
CREATE INDEX IF NOT EXISTS ai_messages_request_idx ON ai_messages (user_id, request_id);
