-- FamCoin: распознавание голосовых сообщений бота (D80) — ещё одна фича в
-- учёте обращений к ИИ. Дневной предел считается по строкам ai_usage, как и
-- остальные квоты (007_ai.sql); request_id — id файла в Telegram, поэтому
-- пересланное ещё раз то же сообщение второй раз в счёт не идёт.
ALTER TABLE ai_usage DROP CONSTRAINT IF EXISTS ai_usage_feature_check;
ALTER TABLE ai_usage ADD CONSTRAINT ai_usage_feature_check CHECK (feature IN ('chat', 'monthly_review', 'voice'));
