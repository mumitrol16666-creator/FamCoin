-- FamCoin: финансовый журнал владельца.
-- Подтверждение email временно отключено (решение D23): аккаунт
-- открывается сразу после регистрации.

DROP TABLE IF EXISTS email_codes;
ALTER TABLE users DROP COLUMN IF EXISTS email_verified;

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS revision bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS plan text NOT NULL DEFAULT 'free' CHECK (plan IN ('free', 'pro')),
  ADD COLUMN IF NOT EXISTS profile jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Счета журнала: денежные счета пользователя и технические счета
-- категорий, долгов, капитала. Ключ включает владельца, поэтому ссылка на
-- чужой счёт невозможна на уровне базы.
CREATE TABLE ledger_accounts (
  user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  id          text NOT NULL CHECK (length(id) BETWEEN 1 AND 100),
  kind        text NOT NULL CHECK (kind IN ('asset', 'liability', 'income', 'expense', 'equity')),
  asset_class text CHECK (asset_class IN ('money', 'receivable', 'other')),
  liquid      boolean NOT NULL DEFAULT false,
  currency    text NOT NULL DEFAULT 'KZT',
  archived    boolean NOT NULL DEFAULT false,
  PRIMARY KEY (user_id, id)
);

CREATE TABLE transactions (
  user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  id         text NOT NULL CHECK (length(id) BETWEEN 1 AND 100),
  seq        bigserial NOT NULL,
  date       date NOT NULL,
  type       text NOT NULL,
  meta       jsonb NOT NULL DEFAULT '{}'::jsonb,
  reverses   text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, id),
  FOREIGN KEY (user_id, reverses) REFERENCES transactions (user_id, id)
);

CREATE INDEX transactions_user_seq_idx ON transactions (user_id, seq);
CREATE INDEX transactions_user_date_idx ON transactions (user_id, date, seq);

CREATE TABLE postings (
  user_id    uuid NOT NULL,
  tx_id      text NOT NULL,
  n          smallint NOT NULL,
  account_id text NOT NULL,
  amount     bigint NOT NULL,
  PRIMARY KEY (user_id, tx_id, n),
  FOREIGN KEY (user_id, tx_id) REFERENCES transactions (user_id, id) ON DELETE CASCADE,
  FOREIGN KEY (user_id, account_id) REFERENCES ledger_accounts (user_id, id)
);

CREATE INDEX postings_account_idx ON postings (user_id, account_id);

-- Резервы целей: назначение существующих денег.
CREATE TABLE reservations (
  user_id    uuid NOT NULL,
  goal_id    text NOT NULL,
  account_id text NOT NULL,
  amount     bigint NOT NULL CHECK (amount > 0),
  PRIMARY KEY (user_id, goal_id, account_id),
  FOREIGN KEY (user_id, account_id) REFERENCES ledger_accounts (user_id, id)
);

-- Справочники и планы: описание счетов, члены семьи, лимиты, цели,
-- плановые платежи, условия кредитов.
CREATE TABLE entities (
  user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  kind       text NOT NULL CHECK (kind IN ('account', 'member', 'limit', 'goal', 'planned', 'debt')),
  id         text NOT NULL CHECK (length(id) BETWEEN 1 AND 100),
  data       jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, kind, id)
);

-- Принятые команды: повтор с тем же id не применяется второй раз (T17).
CREATE TABLE commands (
  user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  id         text NOT NULL CHECK (length(id) BETWEEN 1 AND 100),
  revision   bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, id)
);
