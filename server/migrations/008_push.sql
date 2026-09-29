-- FamCoin: Web Push — подписки устройств (PWA на главном экране) и ключи VAPID.

CREATE TABLE IF NOT EXISTS push_subscriptions (
  id         uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  endpoint   text NOT NULL UNIQUE,
  p256dh     text NOT NULL,
  auth       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS push_subscriptions_user_idx ON push_subscriptions (user_id);

-- Пара ключей VAPID создаётся сервером при первом запуске и живёт в базе:
-- сменишь ключ — все подписки перестанут работать.
CREATE TABLE IF NOT EXISTS push_config (
  key   text PRIMARY KEY,
  value text NOT NULL
);
