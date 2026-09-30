-- Проверка целостности журнала: каждая операция сбалансирована (по правилу
-- ядра: дебет = кредит по видам счетов, а не «сумма проводок = 0»), проводки
-- ссылаются на существующие счета, отменяющие записи — на существующие
-- операции. Возвращает по одной строке на каждую найденную проблему;
-- пустой результат — журнал цел.
SELECT 'unbalanced' AS problem, p.user_id::text, p.tx_id AS ref
FROM postings p JOIN ledger_accounts a ON a.user_id = p.user_id AND a.id = p.account_id
GROUP BY p.user_id, p.tx_id
-- то же правило, что в ядре (Ledger.validate): дебетовые счета (активы и
-- расходы) в сумме равны кредитовым (обязательства, капитал, доходы)
HAVING sum(CASE WHEN a.kind IN ('asset', 'expense') THEN p.amount ELSE 0 END)
    <> sum(CASE WHEN a.kind IN ('asset', 'expense') THEN 0 ELSE p.amount END)
UNION ALL
SELECT 'posting_without_account', p.user_id::text, p.tx_id
FROM postings p LEFT JOIN ledger_accounts a ON a.user_id = p.user_id AND a.id = p.account_id
WHERE a.id IS NULL
UNION ALL
SELECT 'transaction_without_postings', t.user_id::text, t.id
FROM transactions t LEFT JOIN postings p ON p.user_id = t.user_id AND p.tx_id = t.id
WHERE p.tx_id IS NULL
UNION ALL
SELECT 'reversal_of_missing', t.user_id::text, t.id
FROM transactions t LEFT JOIN transactions o ON o.user_id = t.user_id AND o.id = t.reverses
WHERE t.reverses IS NOT NULL AND o.id IS NULL;
