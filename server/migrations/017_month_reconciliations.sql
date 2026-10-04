-- Сохранённый результат сверки не подменяется сегодняшними остатками.
-- Новые операции задним числом помечают его устаревшим, сохраняя снимок.
CREATE TABLE month_reconciliations (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  month date NOT NULL CHECK (extract(day FROM month) = 1),
  snapshot jsonb NOT NULL,
  closed_at timestamptz NOT NULL DEFAULT now(),
  invalidated_at timestamptz,
  PRIMARY KEY (user_id, month)
);
