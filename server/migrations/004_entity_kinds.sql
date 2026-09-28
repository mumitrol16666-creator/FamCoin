-- Виды сущностей: свои категории (D41) и быстрые операции (D47) не попали
-- в ограничение из 002 — сервер отвечал 500 при их сохранении.
ALTER TABLE entities DROP CONSTRAINT IF EXISTS entities_kind_check;
ALTER TABLE entities ADD CONSTRAINT entities_kind_check
  CHECK (kind IN ('account', 'member', 'limit', 'goal', 'planned', 'debt', 'category', 'quick'));
