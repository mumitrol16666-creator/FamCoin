-- FamCoin: вид справочника `purchase` (разовая покупка, D88) не попал в
-- ограничение таблицы — сервер отвечал 500 при сохранении покупки. Та же
-- ошибка, что была с категориями и быстрыми операциями (004): список видов
-- живёт в двух местах — в коде (`entityKinds`) и здесь. Тест
-- `entity_kinds_db_test.dart` сверяет их на настоящей базе.
ALTER TABLE entities DROP CONSTRAINT IF EXISTS entities_kind_check;
ALTER TABLE entities ADD CONSTRAINT entities_kind_check
  CHECK (kind IN ('account', 'member', 'limit', 'goal', 'planned', 'purchase', 'debt', 'category', 'quick'));
