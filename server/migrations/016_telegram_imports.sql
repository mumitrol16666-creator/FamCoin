-- FamCoin: импорт выписки банка через бота Telegram (D94).
--
-- Человек пересылает боту PDF-выписку, бот отвечает сводкой с кнопками. Пока
-- «Записать» не нажато, в журнале ничего нет — разобранные строки выписки
-- живут здесь. Сам файл не хранится.
--
-- data — строки выписки (дата, сумма, вид операции, детали), её период и
-- остатки, выбранный счёт; после записи — какие строки записаны и что было с
-- начальным остатком и переносом лимита до импорта: по этим данным кнопка
-- «Отменить импорт» возвращает всё как было.
CREATE TABLE IF NOT EXISTS telegram_imports (
  id         text PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  chat_id    bigint NOT NULL,
  data       jsonb NOT NULL,
  status     text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'saved', 'cancelled', 'undone')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS telegram_imports_created_idx ON telegram_imports (created_at);
CREATE INDEX IF NOT EXISTS telegram_imports_user_idx ON telegram_imports (user_id, created_at);
