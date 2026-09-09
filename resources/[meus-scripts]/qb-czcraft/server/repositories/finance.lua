-- qb-czcraft financial export repository
-- Persists czcraft_financial_exports — the idempotency journal for money
-- movements to qb-core (player cash/bank) and qb-banking (bank accounts).
--
-- The PENDING/COMMITTED pattern mirrors the inventory batch:
--   1. INSERT IGNORE with status='PENDING' — affectedRows=0 means replay.
--   2. The adapter applies the money movement (qb-core or qb-banking).
--   3. markCommitted updates the row to status='COMMITTED' with the result.
--
-- On replay (affectedRows=0): if the row is COMMITTED, return the cached
-- result; if PENDING, the prior attempt did not complete — the adapter
-- re-applies the money movement and marks COMMITTED.

CZCraft = CZCraft or {}

local FinanceRepo = {}

-- Attempts to record a new financial export intent. INSERT IGNORE gives
-- affectedRows=0 when the export_key already exists (replay).
-- @param params table {
--   export_id, export_key, source_type, source_id, direction, amount,
--   account, reason, machine_uuid?, bill_id?,
-- }
-- @return boolean ok
-- @return boolean isFresh (true = new row inserted, false = replay)
-- @return table|nil existingRow (when isFresh=false: the prior row)
function FinanceRepo.beginExport(params)
    local result = MySQL.update.await([[
        INSERT IGNORE INTO `czcraft_financial_exports`
            (`export_id`, `export_key`, `source_type`, `source_id`,
             `direction`, `amount`, `account`, `reason`,
             `machine_uuid`, `bill_id`, `status`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING')
    ]], {
        params.export_id,
        params.export_key,
        params.source_type,
        params.source_id,
        params.direction,
        params.amount,
        params.account,
        params.reason,
        params.machine_uuid,
        params.bill_id,
    })

    if result and result > 0 then
        return true, true, nil
    end

    -- Replay: load the existing row to check its status.
    local existing = MySQL.single.await([[
        SELECT `export_id`, `status`, `result`
        FROM `czcraft_financial_exports`
        WHERE `export_key` = ?
    ]], { params.export_key })

    return true, false, existing
end

-- Marks a financial export as COMMITTED with the result of the money movement.
-- @param exportId string
-- @param resultJson string JSON-encoded result
-- @return boolean ok
function FinanceRepo.markCommitted(exportId, resultJson)
    local affected = MySQL.update.await([[
        UPDATE `czcraft_financial_exports`
        SET `status` = 'COMMITTED',
            `result` = ?,
            `version` = `version` + 1
        WHERE `export_id` = ? AND `status` = 'PENDING'
    ]], { resultJson, exportId })

    return affected and affected > 0
end

-- Loads a financial export by its export_key (for replay inspection).
-- @param exportKey string
-- @return table|nil row
function FinanceRepo.loadByKey(exportKey)
    return MySQL.single.await([[
        SELECT `export_id`, `export_key`, `source_type`, `source_id`,
               `direction`, `amount`, `account`, `reason`,
               `machine_uuid`, `bill_id`, `status`, `result`
        FROM `czcraft_financial_exports`
        WHERE `export_key` = ?
    ]], { exportKey })
end

CZCraft.FinanceRepo = FinanceRepo
return FinanceRepo
