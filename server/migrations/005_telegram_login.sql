-- Вход и регистрация через Telegram (D49).
-- Аккаунт, созданный из Telegram, получает служебный email tg<chat>@telegram.local
-- и случайный пароль; имя берётся из Telegram. Сессия помнит, как открыта:
-- после входа через Telegram пароль можно задать без текущего (восстановление).

ALTER TABLE users ADD COLUMN IF NOT EXISTS display_name text;
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS via text NOT NULL DEFAULT 'password';

CREATE TABLE IF NOT EXISTS telegram_logins (
  code       text PRIMARY KEY,
  chat_id    bigint,
  name       text,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL
);
