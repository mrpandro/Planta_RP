-- qb-czcraft financial export adapter
-- Idempotent money movements to qb-core (player cash/bank) and qb-banking
-- (job/gang accounts). Every movement is journaled in czcraft_financial_exports
-- AND marked in bank_statements so a replay (same export_key) does not
-- double-apply.
--
-- Two-phase PENDING/COMMITTED with an external commit point:
--
--   Player personal accounts (qb-core):
--     1. INSERT IGNORE PENDING to czcraft_financial_exports
--     2. INSERT bank_statements row with export_key in reason (BEFORE money moves)
--     3. Player.Functions.AddMoney/RemoveMoney (in-memory) + Save() (persist)
--     4. markCommitted
--
--   Job/gang accounts (qb-banking):
--     1. INSERT IGNORE PENDING to czcraft_financial_exports
--     2. qb-banking AddMoney/RemoveMoney (inserts its own bank_statements row
--        with export_key in reason, then updates balance)
--     3. markCommitted
--
-- On PENDING replay:
--   - Query bank_statements for the export_key.
--   - If found → money movement was initiated → skip re-apply, mark COMMITTED.
--   - If not found → money movement was never initiated → re-apply.
--
-- Residual gap (player accounts): between step 2 (statement insert) and
-- step 3 (Save). A crash there leaves a statement but no persisted balance
-- change → replay skips → silent loss. This is the safer failure mode:
-- the player loses money but cannot duplicate it. The window is one INSERT
-- to one Save call. This cannot be eliminated without qb-core supporting
-- idempotency keys on AddMoney/RemoveMoney.
--
-- This is NOT the same gap as the inventory batch. The inventory batch
-- closes its gap because czcraft owns the persistence layer end-to-end
-- (its own DB, its own transaction, FOR UPDATE on its own mutation row).
-- Money is structurally different: Player:Save() writes into qb-core's
-- own persistence path, outside our transaction boundary.

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

-- Applies a money movement to a qb-banking job/gang account.
-- The reason parameter carries the export_key so the bank_statements row
-- serves as the idempotency guard.
-- @param sourceId string bank account identifier
-- @param direction string 'DEBIT' | 'CREDIT'
-- @param amount number
-- @param bankingReason string (formatted with export_key)
-- @return boolean ok
-- @return string|nil error
local function applyQbBankingMovement(sourceId, direction, amount, bankingReason)
    local banking = exports['qb-banking']
    if not banking then
        return false, 'qb-banking export not found'
    end

    if direction == CZCraft.FinancialDirection.CREDIT then
        local ok = banking.AddMoney(sourceId, amount, bankingReason)
        if not ok then
            return false, 'qb-banking AddMoney failed (account not found)'
        end
    elseif direction == CZCraft.FinancialDirection.DEBIT then
        -- qb-banking's RemoveMoney does NOT check for sufficient balance
        -- (it permits account underflow). Check first to prevent negative
        -- balances.
        local balance = banking.GetAccountBalance(sourceId)
        if not balance or balance < amount then
            return false, 'insufficient account balance'
        end
        local ok = banking.RemoveMoney(sourceId, amount, bankingReason)
        if not ok then
            return false, 'qb-banking RemoveMoney failed (account not found)'
        end
    else
        return false, 'unknown direction: ' .. tostring(direction)
    end

    return true, nil
end

-- Executes an idempotent financial movement. The export_key prevents
-- double-application on replay. The bank_statements row serves as the
-- external commit point for PENDING replay resolution.
--
-- @param params table {
--   export_key string (idempotency key — caller builds deterministically),
--   source_type string 'qb-core' | 'qb-banking',
--   source_id string (player source id for qb-core, account id for qb-banking),
--   direction string 'DEBIT' | 'CREDIT',
--   amount number (>= 0),
--   account string 'cash' | 'bank' (qb-core only; ignored for qb-banking),
--   reason string (human-readable, stored in journal + bank_statements),
--   machine_uuid? string,
--   bill_id? string,
--   citizenid? string (required for qb-core player statements),
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
    local humanReason = params.reason or 'czcraft'
    local isPlayerAccount = params.source_type == CZCraft.FinancialSourceType.QB_CORE

    -- Step 1: record the intent (INSERT IGNORE for idempotency).
    local beginOk, isFresh, existing = CZCraft.FinanceRepo.beginExport({
        export_id = exportId,
        export_key = params.export_key,
        source_type = params.source_type,
        source_id = tostring(params.source_id),
        direction = params.direction,
        amount = amount,
        account = params.account or 'bank',
        reason = humanReason,
        machine_uuid = params.machine_uuid,
        bill_id = params.bill_id,
    })

    if not beginOk then
        return { success = false, reason = 'failed to begin financial export' }
    end

    -- Step 2: replay handling.
    if not isFresh then
        -- The export_key already exists.
        if existing and existing.status == 'COMMITTED' then
            -- Prior attempt completed. Return the cached result.
            local cachedResult = existing.result and json.decode(existing.result) or nil
            return { success = true, replayed = true, result = cachedResult }
        end

        -- PENDING: the prior attempt did not complete. Check the external
        -- commit point (bank_statements) to determine whether the money
        -- movement was initiated.
        exportId = existing and existing.export_id or exportId

        local statementExists = CZCraft.FinanceRepo.checkStatementExists(params.export_key)
        if statementExists then
            -- The money movement was initiated (statement was inserted before
            -- the money moved). Skip re-apply and mark COMMITTED. If a crash
            -- happened between the statement insert and Save(), the money was
            -- never persisted — this is silent loss, not double-grant.
            local resultMeta = {
                appliedAt = os.time(),
                sourceType = params.source_type,
                direction = params.direction,
                amount = amount,
                success = true,
                replayedFromStatement = true,
            }
            CZCraft.FinanceRepo.markCommitted(exportId, json.encode(resultMeta))
            return { success = true, replayed = true, result = resultMeta }
        end

        -- The statement was NOT found — the money movement was never
        -- initiated. Fall through to re-apply (insert statement + move money).
    end

    -- Step 3 (fresh or PENDING-without-statement): apply the money movement.

    -- For DEBIT, check balance before inserting the statement.
    if params.direction == CZCraft.FinancialDirection.DEBIT then
        if isPlayerAccount then
            local Player = exports['qb-core']:GetPlayer(params.source_id)
            if not Player then
                local failMeta = { success = false, error = 'player not found' }
                CZCraft.FinanceRepo.markCommitted(exportId, json.encode(failMeta))
                return { success = false, reason = 'player not found', result = failMeta }
            end
            local balance = Player.PlayerData.money[params.account or 'bank'] or 0
            if balance < amount then
                local failMeta = { success = false, error = 'insufficient balance' }
                CZCraft.FinanceRepo.markCommitted(exportId, json.encode(failMeta))
                return { success = false, reason = 'insufficient ' .. (params.account or 'bank') .. ' balance', result = failMeta }
            end
        else
            local banking = exports['qb-banking']
            local balance = banking and banking.GetAccountBalance(params.source_id) or 0
            if balance < amount then
                local failMeta = { success = false, error = 'insufficient account balance' }
                CZCraft.FinanceRepo.markCommitted(exportId, json.encode(failMeta))
                return { success = false, reason = 'insufficient account balance', result = failMeta }
            end
        end
    end

    -- Insert the external commit point (bank_statements) BEFORE the money
    -- moves. For player accounts, we insert directly. For job/gang accounts,
    -- qb-banking's AddMoney/RemoveMoney inserts the statement as part of
    -- the money movement, so we pass the formatted reason there instead.
    if isPlayerAccount then
        local stmtType = (params.direction == CZCraft.FinancialDirection.CREDIT) and 'deposit' or 'withdraw'
        local stmtOk = CZCraft.FinanceRepo.insertPlayerStatement({
            citizenid = params.citizenid,
            account_name = params.account or 'checking',
            amount = amount,
            export_key = params.export_key,
            human_reason = humanReason,
            statement_type = stmtType,
        })
        if not stmtOk then
            local failMeta = { success = false, error = 'failed to insert bank statement' }
            CZCraft.FinanceRepo.markCommitted(exportId, json.encode(failMeta))
            return { success = false, reason = 'failed to insert bank statement', result = failMeta }
        end
    end

    -- Apply the money movement.
    local applyOk, applyErr
    if isPlayerAccount then
        applyOk, applyErr = applyQbCoreMovement(
            params.source_id, params.direction, amount, params.account or 'bank'
        )
    else
        local bankingReason = CZCraft.FinanceRepo.formatBankingReason(params.export_key, humanReason)
        applyOk, applyErr = applyQbBankingMovement(
            params.source_id, params.direction, amount, bankingReason
        )
    end

    local resultMeta = {
        appliedAt = os.time(),
        sourceType = params.source_type,
        direction = params.direction,
        amount = amount,
    }

    if not applyOk then
        -- The money movement failed. Mark COMMITTED with the failure result
        -- so a replay does not retry indefinitely.
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
