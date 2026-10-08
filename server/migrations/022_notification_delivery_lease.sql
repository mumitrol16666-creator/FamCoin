-- Один отправитель на запись; после остановки процесса аренда истекает.
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS deliver_token uuid;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS deliver_lease_until timestamptz;
