-- FamCoin: оплата Pro звёздами Telegram (D52).
-- pro_until = NULL при plan = 'pro' означает бессрочный Pro (выдан из админки).
-- Каждый успешный платёж записывается один раз по telegram_payment_charge_id,
-- чтобы повторная доставка события не продлила Pro дважды.

ALTER TABLE users ADD COLUMN IF NOT EXISTS pro_until timestamptz;

CREATE TABLE IF NOT EXISTS payments (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id          uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  provider         text NOT NULL DEFAULT 'telegram_stars',
  charge_id        text NOT NULL UNIQUE,
  telegram_user_id bigint NOT NULL,
  stars            int NOT NULL CHECK (stars > 0),
  period_days      int NOT NULL CHECK (period_days > 0),
  pro_until        timestamptz NOT NULL,
  status           text NOT NULL DEFAULT 'paid' CHECK (status IN ('paid', 'refunded')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  refunded_at      timestamptz
);
CREATE INDEX IF NOT EXISTS payments_user_idx ON payments (user_id, created_at DESC);
