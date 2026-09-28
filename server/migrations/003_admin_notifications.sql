-- FamCoin: уведомления, привязка Telegram, журнал действий администратора.

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS telegram_chat_id bigint,
  ADD COLUMN IF NOT EXISTS last_seen_at timestamptz,
  -- Настройки уведомлений и отметки последней отправки:
  -- {"morning": true, "evening": true, "sentMorning": "2026-09-27", "sentEvening": "..."}
  ADD COLUMN IF NOT EXISTS notif jsonb NOT NULL DEFAULT '{"morning": true, "evening": true}'::jsonb;

CREATE TABLE IF NOT EXISTS notifications (
  id         uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  kind       text NOT NULL CHECK (kind IN ('morning', 'evening', 'system')),
  title      text NOT NULL,
  body       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at    timestamptz
);
CREATE INDEX IF NOT EXISTS notifications_user_idx ON notifications (user_id, created_at DESC);

-- Одноразовые коды привязки: пользователь отправляет боту «/start <код>».
CREATE TABLE IF NOT EXISTS telegram_links (
  code       text PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_audit (
  id         bigserial PRIMARY KEY,
  at         timestamptz NOT NULL DEFAULT now(),
  action     text NOT NULL,
  target     uuid,
  details    jsonb NOT NULL DEFAULT '{}'::jsonb
);
