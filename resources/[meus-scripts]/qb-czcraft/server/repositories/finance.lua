-- qb-czcraft financial export repository
-- Persists czcraft_financial_exports — the idempotency journal for money
-- movements to qb-core (player cash/bank) and qb-banking (job/gang accounts).
--
-- Two-phase PENDING/COMMITTED with an external commit point:
--   1. INSERT IGNORE with status='PENDING' — affectedRows=0 means replay.
--   2. Insert a bank_statements row with the export_key embedded in the
--      reason field (the "money was initiated" marker / external commit point).
--   3. The adapter applies the money movement (qb-core or qb-banking).
--   4. markCommitted updates the row to status='COMMITTED' with the result.
--
-- On PENDING replay: query bank_statements for the export_key. If found,
-- the money movement was initiated — skip re-apply and mark COMMITTED
-- (accepting the silent-loss risk: if a crash happened between the
-- statement insert and Player:Save(), the money was never persisted, but
-- the statement exists, so the replay skips. Silent loss is the safer
-- failure mode — the player loses money, but cannot duplicate it). If the
-- statement is NOT found, the money movement was never initiated — re-apply.
--
-- IMPORTANT: this is NOT the same gap shape as the inventory batch. The
-- inventory batch closes its gap because czcraft owns the persistence layer
-- end-to-end (its own DB, its own transaction, FOR UPDATE on its own
-- mutation row). Money is structurally different: Player:Save() writes into
-- qb-core's own persistence path, outside our transaction boundary. The
-- bank_statements row is an external commit point that narrows the window
-- but cannot eliminate it without qb-core supporting idempotency keys on
-- AddMoney/RemoveMoney.

CZCraft = CZCraft or {}

local FinanceRepo = {}

-- Reason field format: czcraft|<export_key>|<human-readable>
-- The pipe-delimited prefix allows a LIKE query to match the export_key
-- without false positives (czcraft|abc|... won't match czcraft|abcd|...).
local REASON_PREFIX = 'czcraft|'

-- Builds the structured reason string embedded in bank_statements.
-- @param exportKey string
-- @param humanReason string
-- @return string
local function formatStatementReason(exportKey, humanReason)
    return REASON_PREFIX .. tostring(exportKey) .. '|' .. tostring(humanReason or 'czcraft')
end

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

-- Checks whether a bank_statements row with the given export_key exists.
-- This is the external commit point for PENDING replay: if the statement
-- exists, the money movement was initiated (the statement was inserted
-- before the money moved). If it doesn't exist, the money movement was
-- never initiated and should be re-applied.
-- @param exportKey string
-- @return boolean exists
function FinanceRepo.checkStatementExists(exportKey)
    local row = MySQL.single.await([[
        SELECT COUNT(*) AS cnt
        FROM `bank_statements`
        WHERE `reason` LIKE ?
    ]], { REASON_PREFIX .. tostring(exportKey) .. '|%' })

    return row and tonumber(row.cnt) and tonumber(row.cnt) > 0 or false
end

-- Inserts a bank_statements row for a player personal account movement.
-- This is the "money was initiated" marker inserted BEFORE the money
-- actually moves via Player.Functions.AddMoney/RemoveMoney + Save. If a
-- crash happens between this insert and Save(), the statement exists but
-- the balance was never persisted — a PENDING replay will see the statement
-- and skip re-apply, resulting in silent loss (not exploitable).
--
-- For job/gang accounts, this is NOT called — qb-banking's AddMoney/
-- RemoveMoney inserts its own statement with the export_key in the reason.
--
-- @param params table {
--   citizenid, account_name, amount, export_key, human_reason,
--   statement_type ('deposit' | 'withdraw'),
-- }
-- @return boolean ok
function FinanceRepo.insertPlayerStatement(params)
    local formattedReason = formatStatementReason(params.export_key, params.human_reason)
    local insertId = MySQL.insert.await([[
        INSERT INTO `bank_statements`
            (`citizenid`, `account_name`, `amount`, `reason`, `statement_type`)
        VALUES (?, ?, ?, ?, ?)
    ]], {
        params.citizenid,
        params.account_name or 'checking',
        params.amount,
        formattedReason,
        params.statement_type or 'deposit',
    })
    return insertId ~= nil
end

-- Builds the structured reason string for qb-banking's AddMoney/RemoveMoney
-- so the export_key is embedded in the bank_statements reason field.
-- @param exportKey string
-- @param humanReason string
-- @return string
function FinanceRepo.formatBankingReason(exportKey, humanReason)
    return formatStatementReason(exportKey, humanReason)
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
