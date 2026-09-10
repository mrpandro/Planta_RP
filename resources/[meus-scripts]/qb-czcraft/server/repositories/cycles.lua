-- qb-czcraft cycles repository
-- Persists czcraft_active_cycles (one per machine) and czcraft_production_events
-- (one aggregated event per chunk). Cycle start inserts the active cycle row +
-- applies stock deltas in a transaction. Cycle completion is idempotent: the
-- PK is machine_uuid so only one active cycle exists, and the cycle_id unique
-- key prevents duplicate completion.
--
-- The recipe_hash is computed via SQL SHA2(?, 256) at insert time so the
-- canonical string (built by shared/recipe_snapshot.lua) is hashed server-side.

CZCraft = CZCraft or {}

local CyclesRepo = {}

-- Loads the active cycle for a machine (or nil if none).
-- @param machineUuid string
-- @return table|nil cycle row
function CyclesRepo.loadActive(machineUuid)
    return MySQL.single.await([[
        SELECT `cycle_id`, `cycle_sequence`, `machine_uuid`, `bill_id`,
               `recipe_id`, `recipe_hash`, `recipe_snapshot`, `started_at`,
               `due_at`, `duration_seconds`, `reserved_output_weight`,
               `standard_cost`, `power_level_before`, `power_level_after`,
               `power_to_consume`, `condition_before`, `condition_after`,
               `wear_to_apply`, `version`
        FROM `czcraft_active_cycles`
        WHERE `machine_uuid` = ?
    ]], { machineUuid })
end

-- Starts a cycle: inserts the active cycle row + applies stock deltas in a
-- single transaction. The recipe_hash is computed via SQL SHA2(canonical, 256).
-- @param params table {
--   cycle_id, cycle_sequence, machine_uuid, bill_id?, recipe_id,
--   recipe_canonical (string — hash pre-image), recipe_snapshot (table — will be JSON-encoded),
--   started_at (unix seconds), duration_seconds, reserved_output_weight,
--   standard_cost, stock_deltas = { { item_name, quantity_delta, reserved_delta } },
-- }
-- @return boolean ok
-- @return string|nil error
function CyclesRepo.start(params)
    local snapshotJson = json.encode(params.recipe_snapshot)
    local startedAtIso = os.date('!%Y-%m-%d %H:%M:%S.000', params.started_at)
    local dueAtIso = os.date('!%Y-%m-%d %H:%M:%S.000', params.started_at + params.duration_seconds)

    -- Build the stock delta statements.
    local deltaStatements = {}
    local deltaArgs = {}
    for _, delta in ipairs(params.stock_deltas or {}) do
        if delta.quantity_delta ~= 0 then
            deltaStatements[#deltaStatements + 1] = [[
                UPDATE `czcraft_machine_stock`
                SET `quantity` = `quantity` + ?,
                    `version` = `version` + 1
                WHERE `machine_uuid` = ? AND `item_name` = ? AND `metadata_key` = ''
                  AND CAST(`quantity` AS SIGNED) + ? >= 0
            ]]
            deltaArgs[#deltaArgs + 1] = {
                delta.quantity_delta,
                params.machine_uuid,
                delta.item_name,
                delta.quantity_delta,
            }
        end
        if delta.reserved_delta ~= 0 then
            deltaStatements[#deltaStatements + 1] = [[
                UPDATE `czcraft_machine_stock`
                SET `reserved_quantity` = `reserved_quantity` + ?,
                    `version` = `version` + 1
                WHERE `machine_uuid` = ? AND `item_name` = ? AND `metadata_key` = ''
                  AND CAST(`reserved_quantity` AS SIGNED) + ? >= 0
                  AND CAST(`reserved_quantity` AS SIGNED) + ? <= CAST(`quantity` AS SIGNED)
            ]]
            deltaArgs[#deltaArgs + 1] = {
                delta.reserved_delta,
                params.machine_uuid,
                delta.item_name,
                delta.reserved_delta,
                delta.reserved_delta,
            }
        end
    end

    -- Insert the active cycle row with SHA2(canonical, 256).
    -- Power/condition snapshot columns (v0.2) are nullable: NULL when the
    -- feature is off or the machine row lacked the value (schema v1 / tests).
    local insertStatement = [[
        INSERT INTO `czcraft_active_cycles`
            (`cycle_id`, `cycle_sequence`, `machine_uuid`, `bill_id`, `recipe_id`,
             `recipe_hash`, `recipe_snapshot`, `started_at`, `due_at`,
             `duration_seconds`, `reserved_output_weight`, `standard_cost`,
             `power_level_before`, `power_level_after`, `power_to_consume`,
             `condition_before`, `condition_after`, `wear_to_apply`)
        VALUES (?, ?, ?, ?, ?, SHA2(?, 256), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]]
    local insertArgs = {
        params.cycle_id,
        params.cycle_sequence,
        params.machine_uuid,
        params.bill_id,
        params.recipe_id,
        params.recipe_canonical,
        snapshotJson,
        startedAtIso,
        dueAtIso,
        params.duration_seconds,
        params.reserved_output_weight or 0,
        params.standard_cost or 0,
        params.power_level_before,
        params.power_level_after,
        params.power_to_consume or 0,
        params.condition_before,
        params.condition_after,
        params.wear_to_apply or 0,
    }

    -- Update the machine's active_cycle_id and operational_status.
    -- When power/condition are consumed (v0.2), decrement them in the SAME
    -- transaction as input consumption — the invariant is "input and energy
    -- are consumed at cycle start" (overview.md line 80). The snapshot columns
    -- on the active_cycles row record the result for audit; the machine row
    -- is updated here, not on completion.
    local hasPower = params.power_to_consume and params.power_to_consume > 0
    local hasWear = params.wear_to_apply and params.wear_to_apply > 0
    local updateMachineStatement
    local updateMachineArgs
    if hasPower and hasWear then
        updateMachineStatement = [[
            UPDATE `czcraft_machines`
            SET `active_cycle_id` = ?,
                `operational_status` = 'RUNNING',
                `next_due_at` = ?,
                `power_level` = GREATEST(0, CAST(`power_level` AS SIGNED) - ?),
                `condition` = GREATEST(0, CAST(`condition` AS DECIMAL(5,2)) - ?),
                `version` = `version` + 1
            WHERE `machine_uuid` = ?
        ]]
        updateMachineArgs = {
            params.cycle_id, dueAtIso,
            params.power_to_consume, params.wear_to_apply,
            params.machine_uuid,
        }
    elseif hasPower then
        updateMachineStatement = [[
            UPDATE `czcraft_machines`
            SET `active_cycle_id` = ?,
                `operational_status` = 'RUNNING',
                `next_due_at` = ?,
                `power_level` = GREATEST(0, CAST(`power_level` AS SIGNED) - ?),
                `version` = `version` + 1
            WHERE `machine_uuid` = ?
        ]]
        updateMachineArgs = {
            params.cycle_id, dueAtIso,
            params.power_to_consume, params.machine_uuid,
        }
    elseif hasWear then
        updateMachineStatement = [[
            UPDATE `czcraft_machines`
            SET `active_cycle_id` = ?,
                `operational_status` = 'RUNNING',
                `next_due_at` = ?,
                `condition` = GREATEST(0, CAST(`condition` AS DECIMAL(5,2)) - ?),
                `version` = `version` + 1
            WHERE `machine_uuid` = ?
        ]]
        updateMachineArgs = {
            params.cycle_id, dueAtIso,
            params.wear_to_apply, params.machine_uuid,
        }
    else
        updateMachineStatement = [[
            UPDATE `czcraft_machines`
            SET `active_cycle_id` = ?,
                `operational_status` = 'RUNNING',
                `next_due_at` = ?,
                `version` = `version` + 1
            WHERE `machine_uuid` = ?
        ]]
        updateMachineArgs = {
            params.cycle_id, dueAtIso, params.machine_uuid,
        }
    end

    -- Execute everything in a transaction.
    -- oxmysql 2.14.1 expects a table of { query, values } entries, not a
    -- function callback. Build the query list and submit atomically.
    local queries = {
        { query = insertStatement, values = insertArgs },
    }
    for i = 1, #deltaStatements do
        queries[#queries + 1] = { query = deltaStatements[i], values = deltaArgs[i] }
    end
    queries[#queries + 1] = { query = updateMachineStatement, values = updateMachineArgs }

    local ok, err = pcall(MySQL.transaction.await, queries)
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

-- Completes a cycle: moves reserved output to actual stock, deletes the active
-- cycle row, and inserts a production event. Idempotent: the production-event
-- INSERT IGNORE is the FIRST statement inside a MySQL.startTransaction
-- callback. If the event already exists (replay or concurrent race),
-- affectedRows = 0 and ALL side effects (stock deltas, cycle delete, machine
-- update) are skipped — the transaction commits as a no-op.
--
-- This replaces the prior check-then-transaction pattern (preflight SELECT
-- + MySQL.transaction.await) which had a replay race: two callers could
-- both pass the preflight SELECT, then both execute the transaction and
-- both apply stock deltas. The startTransaction callback gates side effects
-- on the dedup-key write's affected count INSIDE the transaction, so the
-- race window is closed at the database level.
--
-- @param params table {
--   cycle_id, machine_uuid, bill_id?, completion_deltas = { { item_name, quantity_delta, reserved_delta } },
--   idempotency_key, cycles_completed = 1, inputs_json, outputs_json, cost, started_at, ended_at,
-- }
-- @return boolean ok
-- @return string|nil error
-- @return boolean replayed (true if the event already existed — caller skips bill increment + next cycle)
function CyclesRepo.complete(params)
    local endedAtIso = os.date('!%Y-%m-%d %H:%M:%S.000', params.ended_at)
    local startedAtIso = os.date('!%Y-%m-%d %H:%M:%S.000', params.started_at)

    -- Build completion delta statements (reserved -> actual).
    local deltaStatements = {}
    local deltaArgs = {}
    for _, delta in ipairs(params.completion_deltas or {}) do
        if delta.quantity_delta ~= 0 then
            deltaStatements[#deltaStatements + 1] = [[
                UPDATE `czcraft_machine_stock`
                SET `quantity` = `quantity` + ?,
                    `version` = `version` + 1
                WHERE `machine_uuid` = ? AND `item_name` = ? AND `metadata_key` = ''
            ]]
            deltaArgs[#deltaArgs + 1] = {
                delta.quantity_delta,
                params.machine_uuid,
                delta.item_name,
            }
        end
        if delta.reserved_delta ~= 0 then
            deltaStatements[#deltaStatements + 1] = [[
                UPDATE `czcraft_machine_stock`
                SET `reserved_quantity` = `reserved_quantity` + ?,
                    `version` = `version` + 1
                WHERE `machine_uuid` = ? AND `item_name` = ? AND `metadata_key` = ''
                  AND CAST(`reserved_quantity` AS SIGNED) + ? >= 0
            ]]
            deltaArgs[#deltaArgs + 1] = {
                delta.reserved_delta,
                params.machine_uuid,
                delta.item_name,
                delta.reserved_delta,
            }
        end
    end

    -- Idempotent production-event INSERT. INSERT IGNORE gives affectedRows = 0
    -- when the unique idempotency_key already exists (replay or concurrent race).
    local insertEventStatement = [[
        INSERT IGNORE INTO `czcraft_production_events`
            (`event_id`, `machine_uuid`, `bill_id`, `cycles_completed`,
             `inputs`, `outputs`, `cost`, `started_at`, `ended_at`,
             `idempotency_key`, `status`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'COMMITTED')
    ]]
    local eventUuid = params.event_id or params.idempotency_key
    local insertEventArgs = {
        eventUuid,
        params.machine_uuid,
        params.bill_id,
        params.cycles_completed or 1,
        params.inputs_json or '[]',
        params.outputs_json or '[]',
        params.cost or 0,
        startedAtIso,
        endedAtIso,
        params.idempotency_key,
    }

    -- Delete the active cycle row.
    local deleteCycleStatement = [[
        DELETE FROM `czcraft_active_cycles` WHERE `machine_uuid` = ? AND `cycle_id` = ?
    ]]

    -- Update the machine: clear active_cycle_id, set STOPPED.
    -- Power was consumed at cycle START (in the start transaction), not here —
    -- the invariant is "input and energy are consumed at cycle start."
    local updateMachineStatement = [[
        UPDATE `czcraft_machines`
        SET `active_cycle_id` = NULL,
            `operational_status` = 'STOPPED',
            `version` = `version` + 1
        WHERE `machine_uuid` = ?
    ]]
    local updateMachineArgs = { params.machine_uuid }

    local replayed = false

    local ok = MySQL.startTransaction(function(tx)
        -- Idempotency guard: INSERT IGNORE as the first statement.
        -- affectedRows = 1 → new event, proceed with side effects.
        -- affectedRows = 0 → replay or race, commit as no-op.
        local result = tx(insertEventStatement, insertEventArgs)
        local affectedRows = result and result.affectedRows or 0
        if affectedRows == 0 then
            replayed = true
            return true
        end

        -- New event inserted: apply all side effects inside the same
        -- transaction. If any tx() call throws, the transaction rolls back
        -- and the event INSERT is also rolled back (atomic).
        for i = 1, #deltaStatements do
            tx(deltaStatements[i], deltaArgs[i])
        end
        tx(deleteCycleStatement, { params.machine_uuid, params.cycle_id })
        tx(updateMachineStatement, { params.machine_uuid })
        return true
    end)

    if not ok then
        return false, 'complete transaction failed'
    end
    return true, nil, replayed
end

-- Deletes the active cycle row without producing output (used on cycle failure/cancel).
-- @param machineUuid string
-- @param cycleId string
-- @return boolean ok
function CyclesRepo.deleteActive(machineUuid, cycleId)
    local affected = MySQL.update.await([[
        DELETE FROM `czcraft_active_cycles` WHERE `machine_uuid` = ? AND `cycle_id` = ?
    ]], { machineUuid, cycleId })
    return affected > 0
end

-- Returns the next cycle sequence number (monotonic across all machines).
-- @return number nextSequence
function CyclesRepo.nextSequence()
    local row = MySQL.single.await([[
        SELECT COALESCE(MAX(`cycle_sequence`), 0) + 1 AS next_seq
        FROM `czcraft_active_cycles`
    ]])
    return row and tonumber(row.next_seq) or 1
end

-- Loads all machines with next_due_at <= now for scheduler recovery polling.
-- @param nowIso string ISO datetime
-- @param limit number
-- @return table list of { machine_uuid, next_due_at }
function CyclesRepo.listDueMachines(nowIso, limit)
    return MySQL.query.await([[
        SELECT `machine_uuid`, `next_due_at`
        FROM `czcraft_machines`
        WHERE `lifecycle` = 'INSTALLED'
          AND `operational_status` IN ('STOPPED', 'RUNNING')
          AND `next_due_at` IS NOT NULL
          AND `next_due_at` <= ?
        ORDER BY `next_due_at` ASC
        LIMIT ?
    ]], { nowIso, limit or 100 }) or {}
end

-- Applies a catch-up chunk: N cycles' net stock deltas + one aggregated
-- production event + machine next_due_at advance, all in ONE transaction.
-- Catch-up cycles are instantly complete (no active-cycle row, no reservation
-- dance): inputs are consumed and outputs produced directly. Idempotent via
-- INSERT IGNORE on the idempotency_key as the first statement inside a
-- MySQL.startTransaction callback — a replay (same chunk sequence) gives
-- affectedRows = 0 and all side effects are skipped (same pattern as
-- complete()).
--
-- @param params table {
--   machine_uuid, bill_id?, recipe = { inputs, outputs },
--   cycles_to_run number (N), chunk_sequence number,
--   chunk_started_at number (unix seconds), chunk_ended_at number (unix seconds),
--   next_due_at number (unix seconds — lastCompletedAt + N * duration),
--   standard_cost number, idempotency_key string,
-- }
-- @return boolean ok
-- @return string|nil error
-- @return boolean replayed (true if the chunk event already existed)
function CyclesRepo.applyCatchUpChunk(params)
    local n = params.cycles_to_run
    if not n or n <= 0 then
        return true, nil, false
    end

    local startedAtIso = os.date('!%Y-%m-%d %H:%M:%S.000', params.chunk_started_at)
    local endedAtIso = os.date('!%Y-%m-%d %H:%M:%S.000', params.chunk_ended_at)
    local nextDueIso = os.date('!%Y-%m-%d %H:%M:%S.000', params.next_due_at)

    local recipe = params.recipe

    -- Build net stock delta statements.
    -- Inputs: quantity -= amount * N (guarded so quantity stays >= 0).
    -- Outputs: upsert — quantity += amount * N (inserts the row if absent).
    local deltaStatements = {}
    local deltaArgs = {}

    if type(recipe.inputs) == 'table' then
        for _, line in ipairs(recipe.inputs) do
            local total = line.amount * n
            deltaStatements[#deltaStatements + 1] = [[
                UPDATE `czcraft_machine_stock`
                SET `quantity` = `quantity` - ?,
                    `version` = `version` + 1
                WHERE `machine_uuid` = ? AND `item_name` = ? AND `metadata_key` = ''
                  AND `quantity` >= ?
            ]]
            deltaArgs[#deltaArgs + 1] = { total, params.machine_uuid, line.item, total }
        end
    end

    if type(recipe.outputs) == 'table' then
        for _, line in ipairs(recipe.outputs) do
            local total = line.amount * n
            deltaStatements[#deltaStatements + 1] = [[
                INSERT INTO `czcraft_machine_stock`
                    (`machine_uuid`, `item_name`, `metadata_key`, `quantity`,
                     `reserved_quantity`, `standard_unit_cost`)
                VALUES (?, ?, '', ?, 0, 0)
                ON DUPLICATE KEY UPDATE
                    `quantity` = `quantity` + VALUES(`quantity`),
                    `version` = `version` + 1
            ]]
            deltaArgs[#deltaArgs + 1] = { params.machine_uuid, line.item, total }
        end
    end

    -- Idempotent production-event INSERT. INSERT IGNORE gives affectedRows = 0
    -- when the unique idempotency_key already exists (replay or concurrent race).
    local inputsJson = json.encode(recipe.inputs or {})
    local outputsJson = json.encode(recipe.outputs or {})
    local eventUuid = params.event_id or params.idempotency_key
    local insertEventStatement = [[
        INSERT IGNORE INTO `czcraft_production_events`
            (`event_id`, `machine_uuid`, `bill_id`, `cycles_completed`,
             `inputs`, `outputs`, `cost`, `started_at`, `ended_at`,
             `idempotency_key`, `status`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'COMMITTED')
    ]]
    local insertEventArgs = {
        eventUuid, params.machine_uuid, params.bill_id, n,
        inputsJson, outputsJson, params.standard_cost or 0,
        startedAtIso, endedAtIso, params.idempotency_key,
    }

    -- Advance the machine's next_due_at (the catch-up cursor). When power
    -- consumption and/or wear amounts are provided (v0.2), decrement them.
    -- Guarded so neither goes below 0.
    local hasPower = params.power_to_consume and params.power_to_consume > 0
    local hasWear = params.wear_to_apply and params.wear_to_apply > 0
    local updateMachineStatement
    local updateMachineArgs
    if hasPower and hasWear then
        updateMachineStatement = [[
            UPDATE `czcraft_machines`
            SET `next_due_at` = ?,
                `operational_status` = 'STOPPED',
                `active_cycle_id` = NULL,
                `power_level` = GREATEST(0, CAST(`power_level` AS SIGNED) - ?),
                `condition` = GREATEST(0, CAST(`condition` AS DECIMAL(5,2)) - ?),
                `version` = `version` + 1
            WHERE `machine_uuid` = ?
        ]]
        updateMachineArgs = { nextDueIso, params.power_to_consume, params.wear_to_apply, params.machine_uuid }
    elseif hasPower then
        updateMachineStatement = [[
            UPDATE `czcraft_machines`
            SET `next_due_at` = ?,
                `operational_status` = 'STOPPED',
                `active_cycle_id` = NULL,
                `power_level` = GREATEST(0, CAST(`power_level` AS SIGNED) - ?),
                `version` = `version` + 1
            WHERE `machine_uuid` = ?
        ]]
        updateMachineArgs = { nextDueIso, params.power_to_consume, params.machine_uuid }
    elseif hasWear then
        updateMachineStatement = [[
            UPDATE `czcraft_machines`
            SET `next_due_at` = ?,
                `operational_status` = 'STOPPED',
                `active_cycle_id` = NULL,
                `condition` = GREATEST(0, CAST(`condition` AS DECIMAL(5,2)) - ?),
                `version` = `version` + 1
            WHERE `machine_uuid` = ?
        ]]
        updateMachineArgs = { nextDueIso, params.wear_to_apply, params.machine_uuid }
    else
        updateMachineStatement = [[
            UPDATE `czcraft_machines`
            SET `next_due_at` = ?,
                `operational_status` = 'STOPPED',
                `active_cycle_id` = NULL,
                `version` = `version` + 1
            WHERE `machine_uuid` = ?
        ]]
        updateMachineArgs = { nextDueIso, params.machine_uuid }
    end

    local replayed = false

    local ok = MySQL.startTransaction(function(tx)
        -- Idempotency guard: INSERT IGNORE as the first statement.
        local result = tx(insertEventStatement, insertEventArgs)
        local affectedRows = result and result.affectedRows or 0
        if affectedRows == 0 then
            replayed = true
            return true
        end

        -- New event inserted: apply stock deltas + advance the cursor.
        for i = 1, #deltaStatements do
            tx(deltaStatements[i], deltaArgs[i])
        end
        tx(updateMachineStatement, updateMachineArgs)
        return true
    end)

    if not ok then
        return false, 'catch-up chunk transaction failed'
    end
    return true, nil, replayed
end

CZCraft.CyclesRepo = CyclesRepo
return CyclesRepo
