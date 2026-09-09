-- qb-czcraft financial export adapter
-- Idempotent money movements to qb-core (player cash/bank) and qb-banking
-- (bank accounts). Every movement is journaled in czcraft_financial_exports
-- so a replay (same export_key) does not double-apply.
--
-- Two source types:
--   qb-core:    Player.Functions.AddMoney / RemoveMoney (in-memory + save)
--   qb-banking: exports['qb-banking']:... bank account transfer
--
-- The PENDING/COMMITTED flow:
--   1. FinanceRepo.beginExport — INSERT IGNORE; affectedRows=0 = replay.
--   2. If replay + COMMITTED → return cached result (no re-apply).
--   3. If replay + PENDING → prior attempt incomplete; re-apply.
--   4. If fresh → apply the money movement via the source adapter.
--   5. FinanceRepo.markCommitted — record the outcome.
--
-- qb-core money methods mutate memory without immediate persistence; the
-- adapter calls Player.Functions.Save() after a successful movement so the
-- balance change is durable before the export is marked COMMITTED. This
-- closes the window where a crash after AddMoney but before Save would lose
-- the balance change while the export says COMMITTED.

CZCraft = CZCraft or {}

local FinanceAdapter = {}

-- Generates a UUID v4 string (same pattern as other modules).
local function generateUuid()
    return string.gsub('xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx', '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

-- Applies a money movement to a qb-core player account.
-- @param source number player server id
-- @param direction string 'DEBIT' | 'CREDIT'
-- @param amount number
-- @param account string 'cash' | 'bank'
-- @return boolean ok
-- @return string|nil error
local function applyQbCoreMovement(source, direction, amount, account)
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then
        return false, 'player not found'
    end

    if direction == CZCraft.FinancialDirection.CREDIT then
        Player.Functions.AddMoney(account, amount, 'czcraft-finance')
    elseif direction == CZCraft.FinancialDirection.DEBIT then
        local currentBalance = Player.PlayerData.money[account] or 0
        if currentBalance < amount then
            return false, 'insufficient ' .. account .. ' balance'
        end
        Player.Functions.RemoveMoney(account, amount, 'czcraft-finance')
    else
        return false, 'unknown direction: ' .. tostring(direction)
    end

    -- Persist immediately so the balance change is durable before the
    -- export is marked COMMITTED. Without this, a crash between the
    -- in-memory mutation and the periodic save would lose the change.
    Player.Functions.Save()

    return true, nil
end

-- Applies a money movement to a qb-banking bank account.
-- @param sourceId string bank account identifier
-- @param direction string 'DEBIT' | 'CREDIT'
-- @param amount number
-- @return boolean ok
-- @return string|nil error
local function applyQbBankingMovement(sourceId, direction, amount)
    -- qb-banking exposes a server-side export for account balance changes.
    -- The export name and signature may vary by qb-banking version; this
    -- adapter calls the documented AddAccountMoney / RemoveAccountMoney.
    local banking = exports['qb-banking']
    if not banking then
        return false, 'qb-banking export not found'
    end

    if direction == CZCraft.FinancialDirection.CREDIT then
        local ok = banking.AddAccountMoney(sourceId, amount)
        if not ok then
            return false, 'qb-banking AddAccountMoney failed'
        end
    elseif direction == CZCraft.FinancialDirection.DEBIT then
        local ok = banking.RemoveAccountMoney(sourceId, amount)
        if not ok then
            return false, 'qb-banking RemoveAccountMoney failed (insufficient balance or account not found)'
        end
    else
        return false, 'unknown direction: ' .. tostring(direction)
    end

    return true, nil
end

-- Executes an idempotent financial movement. The export_key prevents
-- double-application on replay. Returns the outcome so callers can decide
-- whether to proceed (e.g., skip a purchase if the debit failed).
--
-- @param params table {
--   export_key string (idempotency key — caller builds deterministically),
--   source_type string 'qb-core' | 'qb-banking',
--   source_id string (player source id for qb-core, account id for qb-banking),
--   direction string 'DEBIT' | 'CREDIT',
--   amount number (>= 0),
--   account string 'cash' | 'bank' (qb-core only; ignored for qb-banking),
--   reason string,
--   machine_uuid? string,
--   bill_id? string,
-- }
-- @return table { success, replayed?, reason?, result? }
function FinanceAdapter.applyMovement(params)
    if type(params) ~= 'table' then
        return { success = false, reason = 'params must be a table' }
    end
    if type(params.export_key) ~= 'string' or params.export_key == '' then
        return { success = false, reason = 'export_key required' }
    end
    if params.source_type ~= CZCraft.FinancialSourceType.QB_CORE
       and params.source_type ~= CZCraft.FinancialSourceType.QB_BANKING then
        return { success = false, reason = 'invalid source_type' }
    end
    if params.direction ~= CZCraft.FinancialDirection.DEBIT
       and params.direction ~= CZCraft.FinancialDirection.CREDIT then
        return { success = false, reason = 'invalid direction' }
    end
    local amount = tonumber(params.amount)
    if not amount or amount < 0 then
        return { success = false, reason = 'amount must be >= 0' }
    end
    if amount == 0 then
        return { success = true, replayed = false, result = { zero = true } }
    end

    local exportId = generateUuid()

    -- Step 1: record the intent (INSERT IGNORE for idempotency).
    local beginOk, isFresh, existing = CZCraft.FinanceRepo.beginExport({
        export_id = exportId,
        export_key = params.export_key,
        source_type = params.source_type,
        source_id = tostring(params.source_id),
        direction = params.direction,
        amount = amount,
        account = params.account or 'bank',
        reason = params.reason or 'czcraft',
        machine_uuid = params.machine_uuid,
        bill_id = params.bill_id,
    })

    if not beginOk then
        return { success = false, reason = 'failed to begin financial export' }
    end

    -- Step 2: replay handling.
    if not isFresh then
        -- The export_key already exists. If COMMITTED, return the cached
        -- result. If PENDING, the prior attempt did not complete — re-apply.
        if existing and existing.status == 'COMMITTED' then
            local cachedResult = existing.result and json.decode(existing.result) or nil
            return { success = true, replayed = true, result = cachedResult }
        end
        -- PENDING: use the existing export_id so markCommitted updates the
        -- correct row.
        exportId = existing and existing.export_id or exportId
    end

    -- Step 3: apply the money movement.
    local applyOk, applyErr
    if params.source_type == CZCraft.FinancialSourceType.QB_CORE then
        applyOk, applyErr = applyQbCoreMovement(
            params.source_id, params.direction, amount, params.account or 'bank'
        )
    else
        applyOk, applyErr = applyQbBankingMovement(
            params.source_id, params.direction, amount
        )
    end

    local resultMeta = {
        appliedAt = os.time(),
        sourceType = params.source_type,
        direction = params.direction,
        amount = amount,
    }

    if not applyOk then
        -- The money movement failed. Mark the export as COMMITTED with the
        -- failure result so a replay does not retry indefinitely (the caller
        -- can inspect the result to see the failure reason). The caller
        -- treats this as a failed movement.
        resultMeta.success = false
        resultMeta.error = applyErr
        CZCraft.FinanceRepo.markCommitted(exportId, json.encode(resultMeta))
        return { success = false, replayed = false, reason = applyErr, result = resultMeta }
    end

    -- Step 4: mark the export as COMMITTED.
    resultMeta.success = true
    CZCraft.FinanceRepo.markCommitted(exportId, json.encode(resultMeta))

    return { success = true, replayed = false, result = resultMeta }
end

CZCraft.FinanceAdapter = FinanceAdapter
return FinanceAdapter
