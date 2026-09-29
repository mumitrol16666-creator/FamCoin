-- FamCoin: хранилище для ИИ-консультанта (F081-F088) — только данные,
-- сам вызов модели ещё не подключён (docs/ai-assistant-prompts.md,
-- product-map.md §11: провайдер и квоты пока не выбраны).
--
-- Две разные по характеру фичи с общей квотой (§11 карты продукта):
-- чат («болтушка», F081-F083, F085-F087) — по запросу, разговор из
-- нескольких сообщений; ежемесячный разбор (F084, S28) — НЕ разговор,
-- одна запись на период, запускается по расписанию 1-2 раза в месяц,
-- а не по каждому заходу на экран. Разные фичи могут использовать
-- разные модели — модель хранится на каждой записи, а не одной
-- настройкой на всё приложение.
--
-- Эти таблицы не входят в клиентский снимок `/state` (`entities`) —
-- ИИ-переписка не синхронизируется на устройство как обычные справочники,
-- у неё будут свои эндпоинты, когда дойдёт очередь до самого вызова модели.

CREATE TABLE IF NOT EXISTS ai_conversations (
  id         uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  locale     text NOT NULL DEFAULT 'ru' CHECK (locale IN ('ru', 'kk')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ai_conversations_user_idx ON ai_conversations (user_id, updated_at DESC);

-- context — тот самый JSON-снимок готовых чисел, который ушёл модели
-- (docs/ai-assistant-prompts.md §1): хранится вместе с сообщением, а не
-- пересчитывается задним числом, чтобы «что именно видела модель» было
-- проверяемо (F088), даже если цифры в журнале потом изменятся.
-- insufficient_data — модель прямо сказала «не знаю» из-за нехватки
-- данных (правило 7 системного промпта), а не тихо промолчала об этом.
CREATE TABLE IF NOT EXISTS ai_messages (
  id                uuid PRIMARY KEY DEFAULT uuidv7(),
  conversation_id   uuid NOT NULL REFERENCES ai_conversations (id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  role              text NOT NULL CHECK (role IN ('user', 'assistant')),
  content           text NOT NULL,
  context           jsonb,
  model             text,
  insufficient_data boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ai_messages_conversation_idx ON ai_messages (conversation_id, created_at);

-- F087: предложение изменения хранится отдельно от чата и НЕ применяется
-- само (T35, §11 карты продукта: «Предложение ИИ хранится отдельно.
-- Кнопка «Применить» показывает конкретные изменения и отправляет
-- обычную проверяемую команду приложения»). applied_command_id ссылается
-- на ту же таблицу commands, что и любое другое действие пользователя —
-- отдельного ИИ-пути записи в журнал нет и не будет.
CREATE TABLE IF NOT EXISTS ai_proposals (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),
  message_id         uuid NOT NULL REFERENCES ai_messages (id) ON DELETE CASCADE,
  user_id            uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  kind               text NOT NULL,   -- 'limit', 'budgetMethod', 'debtPayoffPlan' и т.п.
  before             jsonb NOT NULL,
  after              jsonb NOT NULL,
  status             text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'applied', 'declined')),
  applied_command_id text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  resolved_at        timestamptz,
  FOREIGN KEY (user_id, applied_command_id) REFERENCES commands (user_id, id)
);
CREATE INDEX IF NOT EXISTS ai_proposals_user_idx ON ai_proposals (user_id, status);

-- F084/S28: ежемесячный разбор — одна запись на период (год-месяц),
-- генерируется по расписанию, не по каждому открытию экрана.
-- insufficient_data — честно пометить период, где истории мало (например,
-- первый месяц учёта, см. F08 в D67: «нет данных» ≠ «было 0»), вместо
-- того чтобы придумывать разбор по неполным данным.
CREATE TABLE IF NOT EXISTS ai_monthly_reviews (
  user_id           uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  period            text NOT NULL CHECK (period ~ '^\d{4}-\d{2}$'),
  status            text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'generated', 'failed')),
  content           text,
  context           jsonb,
  model             text,
  insufficient_data boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  generated_at      timestamptz,
  PRIMARY KEY (user_id, period)
);

-- F088: расход квоты по каждому обращению к модели, отдельно по фиче и
-- модели — чат и разбор могут стоить по-разному и использовать разные
-- модели; остаток квоты считается по факту этих строк, не отдельным
-- счётчиком, который можно рассинхронизировать. request_id — тот же
-- принцип идемпотентности, что у обычных команд (D53): повтор одного и
-- того же запроса (двойной тап, обрыв сети) не списывает квоту дважды.
CREATE TABLE IF NOT EXISTS ai_usage (
  id         bigserial PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  feature    text NOT NULL CHECK (feature IN ('chat', 'monthly_review')),
  model      text NOT NULL,
  request_id text NOT NULL,
  tokens_in  int NOT NULL DEFAULT 0 CHECK (tokens_in >= 0),
  tokens_out int NOT NULL DEFAULT 0 CHECK (tokens_out >= 0),
  cost_minor bigint NOT NULL DEFAULT 0 CHECK (cost_minor >= 0), -- себестоимость в тиынах; провайдер и цена ещё не выбраны
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, request_id)
);
CREATE INDEX IF NOT EXISTS ai_usage_user_idx ON ai_usage (user_id, created_at DESC);
