-- FamCoin: очередь входящих оплат Pro (D151, аудит 08.10 CS02).
-- Успешная оплата из Telegram сначала сохраняется сюда и только потом
-- подтверждается Telegram (offset getUpdates). Pro выдаётся из очереди; отметка
-- done и запись в payments делаются одной транзакцией, поэтому повтор после
-- сбоя в любом месте не продлевает Pro дважды и не теряет оплату.
--   pending — ждёт выдачи (повтор по next_at);
--   failed  — не удалось за много попыток или счёт не наш: виден в админке,
--             оператору уходит сигнал; повторы продолжаются раз в час;
--   done    — Pro выдан (или платёж уже был проведён раньше).

CREATE TABLE IF NOT EXISTS payment_inbox (
  charge_id   text PRIMARY KEY,
  chat_id     bigint NOT NULL,
  sender      jsonb NOT NULL DEFAULT '{}'::jsonb,
  payment     jsonb NOT NULL,
  status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'failed', 'done')),
  attempts    int NOT NULL DEFAULT 0,
  last_error  text,
  received_at timestamptz NOT NULL DEFAULT now(),
  next_at     timestamptz NOT NULL DEFAULT now(),
  done_at     timestamptz
);
CREATE INDEX IF NOT EXISTS payment_inbox_due_idx ON payment_inbox (next_at) WHERE status <> 'done';
