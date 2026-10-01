-- FamCoin: черновики операций из чата Telegram (D79).
--
-- Человек пишет боту «кофе 1500», бот отвечает черновиком с кнопками. Пока
-- кнопка не нажата, в журнале ничего нет — черновик живёт здесь. Хранится в
-- базе, а не в памяти процесса: выкладка новой версии не должна превращать
-- уже показанные кнопки в мёртвые.
--
-- data — разобранная операция (тип, сумма, категория, счёт, дата, заметка)
-- и заранее выданные id операции и её отмены: повторное нажатие «Записать»
-- или «Отменить» отправляет ту же команду, и журнал принимает её один раз.
CREATE TABLE IF NOT EXISTS telegram_drafts (
  id         text PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  chat_id    bigint NOT NULL,
  data       jsonb NOT NULL,
  status     text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'saved', 'cancelled', 'undone')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS telegram_drafts_created_idx ON telegram_drafts (created_at);
