-- qb-czcraft bills repository
-- Persists czcraft_bills rows: bill creation, pause/resume, remove, and
-- produced-quantity increments. All mutations use optimistic version checks.

CZCraft = CZCraft or {}

local BillsRepo = {}

-- Loads a single bill by ID.
-- @param billId string
-- @return table|nil bill row
function BillsRepo.load(billId)
    return MySQL.single.await([[
        SELECT `bill_id`, `machine_uuid`, `recipe_id`, `mode`, `primary_output`,
               `target_quantity`, `produced_quantity`, `enabled`, `status`,
               `block_reason`, `block_detail`, `priority`, `until_threshold`,
               `created_by_type`, `created_by_id`, `created_sequence`, `version`
        FROM `czcraft_bills`
        WHERE `bill_id` = ?
    ]], { billId })
end

-- Loads all bills for a machine.
-- @param machineUuid string
-- @return table list of bill rows
function BillsRepo.listForMachine(machineUuid)
    return MySQL.query.await([[
        SELECT `bill_id`, `machine_uuid`, `recipe_id`, `mode`, `primary_output`,
               `target_quantity`, `produced_quantity`, `enabled`, `status`,
               `block_reason`, `block_detail`, `priority`, `until_threshold`,
               `created_by_type`, `created_by_id`, `created_sequence`, `version`
        FROM `czcraft_bills`
        WHERE `machine_uuid` = ?
        ORDER BY `created_sequence` ASC
    ]], { machineUuid }) or {}
end

-- Loads all active/pending bills for a machine (for bill selection).
-- @param machineUuid string
-- @return table list of bill rows
function BillsRepo.listActiveForMachine(machineUuid)
    return MySQL.query.await([[
        SELECT `bill_id`, `machine_uuid`, `recipe_id`, `mode`, `primary_output`,
               `target_quantity`, `produced_quantity`, `enabled`, `status`,
               `block_reason`, `block_detail`, `priority`, `until_threshold`,
               `created_by_type`, `created_by_id`, `created_sequence`, `version`
        FROM `czcraft_bills`
        WHERE `machine_uuid` = ? AND `status` IN ('PENDING', 'ACTIVE', 'PAUSED')
        ORDER BY `created_sequence` ASC
    ]], { machineUuid }) or {}
end

-- Creates a new bill. The bill_id is a caller-generated UUID.
-- @param params table {
--   bill_id, machine_uuid, recipe_id, mode, primary_output,
--   target_quantity, priority, until_threshold? (required for UNTIL_X),
--   created_by_type, created_by_id,
-- }
-- @return boolean ok
-- @return string|nil error
function BillsRepo.create(params)
    local affected, err = MySQL.update.await([[
        INSERT INTO `czcraft_bills`
            (`bill_id`, `machine_uuid`, `recipe_id`, `mode`, `primary_output`,
             `target_quantity`, `produced_quantity`, `enabled`, `status`,
             `priority`, `until_threshold`, `created_by_type`, `created_by_id`)
        VALUES (?, ?, ?, ?, ?, ?, 0, 1, 'PENDING', ?, ?, ?, ?)
    ]], {
        params.bill_id,
        params.machine_uuid,
        params.recipe_id,
        params.mode,
        params.primary_output,
        params.target_quantity,
        params.priority or 'NORMAL',
        params.until_threshold,
        params.created_by_type,
        params.created_by_id,
    })
    if err then
        return false, tostring(err)
    end
    return affected > 0, nil
end

-- Pauses a bill (current cycle finishes, no new cycle starts).
-- @param billId string
-- @param expectedVersion number
-- @return boolean ok
-- @return string|nil error
function BillsRepo.pause(billId, expectedVersion)
    local affected = MySQL.update.await([[
        UPDATE `czcraft_bills`
        SET `status` = 'PAUSED', `version` = `version` + 1
        WHERE `bill_id` = ? AND `version` = ? AND `status` IN ('PENDING', 'ACTIVE')
    ]], { billId, expectedVersion })
    if affected == 0 then
        return false, 'optimistic version mismatch or not pausable'
    end
    return true, nil
end

-- Resumes a paused bill.
-- @param billId string
-- @param expectedVersion number
-- @return boolean ok
-- @return string|nil error
function BillsRepo.resume(billId, expectedVersion)
    local affected = MySQL.update.await([[
        UPDATE `czcraft_bills`
        SET `status` = 'ACTIVE', `version` = `version` + 1
        WHERE `bill_id` = ? AND `version` = ? AND `status` = 'PAUSED'
    ]], { billId, expectedVersion })
    if affected == 0 then
        return false, 'optimistic version mismatch or not paused'
    end
    return true, nil
end

-- Removes a bill (marks as REMOVED; stock/reservations unaffected).
-- @param billId string
-- @param expectedVersion number
-- @return boolean ok
-- @return string|nil error
function BillsRepo.remove(billId, expectedVersion)
    local affected = MySQL.update.await([[
        UPDATE `czcraft_bills`
        SET `status` = 'REMOVED', `enabled` = 0, `version` = `version` + 1
        WHERE `bill_id` = ? AND `version` = ? AND `status` != 'REMOVED'
    ]], { billId, expectedVersion })
    if affected == 0 then
        return false, 'optimistic version mismatch or already removed'
    end
    return true, nil
end

-- Increments produced_quantity by batchOutputAmount (on cycle completion).
-- Uses optimistic version. If produced >= target for PRODUCE_X, marks COMPLETED.
-- @param billId string
-- @param expectedVersion number
-- @param batchOutputAmount number
-- @param mode string 'PRODUCE_X'|'MAINTAIN_X'
-- @param targetQuantity number
-- @return boolean ok
-- @return string|nil error
function BillsRepo.incrementProduced(billId, expectedVersion, batchOutputAmount, mode, targetQuantity)
    if mode == 'PRODUCE_X' then
        -- Mark COMPLETED if produced + batch >= target.
        -- NOTE: MySQL evaluates SET assignments left-to-right, so if
        -- produced_quantity is updated before the CASE, the CASE would see
        -- the new value and double-count the batch. Evaluate the CASE first
        -- (against the old produced_quantity) so the comparison is correct.
        local affected = MySQL.update.await([[
            UPDATE `czcraft_bills`
            SET `status` = CASE WHEN `produced_quantity` + ? >= ? THEN 'COMPLETED' ELSE `status` END,
                `produced_quantity` = `produced_quantity` + ?,
                `version` = `version` + 1
            WHERE `bill_id` = ? AND `version` = ?
        ]], { batchOutputAmount, targetQuantity, batchOutputAmount, billId, expectedVersion })
        if affected == 0 then
            return false, 'optimistic version mismatch'
        end
        return true, nil
    else
        -- MAINTAIN_X / UNTIL_X: stock-based modes never auto-complete (they
        -- restart while stock + reserved is below the target/threshold). Just
        -- increment produced for accounting.
        local affected = MySQL.update.await([[
            UPDATE `czcraft_bills`
            SET `produced_quantity` = `produced_quantity` + ?,
                `version` = `version` + 1
            WHERE `bill_id` = ? AND `version` = ?
        ]], { batchOutputAmount, billId, expectedVersion })
        if affected == 0 then
            return false, 'optimistic version mismatch'
        end
        return true, nil
    end
end

-- Counts active/pending/paused bills for a machine (used by pickup preconditions).
-- @param machineUuid string
-- @return number count
function BillsRepo.countActiveForMachine(machineUuid)
    local row = MySQL.single.await([[
        SELECT COUNT(*) AS cnt
        FROM `czcraft_bills`
        WHERE `machine_uuid` = ? AND `status` IN ('PENDING', 'PAUSED')
    ]], { machineUuid })
    return row and tonumber(row.cnt) or 0
end

CZCraft.BillsRepo = BillsRepo
return BillsRepo
