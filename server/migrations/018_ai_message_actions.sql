-- Кнопки-переходы под ответом консультанта (D108): id экранов из закрытого
-- списка ядра, чтобы история чата показывала их так же, как свежий ответ.
ALTER TABLE ai_messages ADD COLUMN actions jsonb NOT NULL DEFAULT '[]'::jsonb;
