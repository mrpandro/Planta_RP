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
               `standard_cost`, `version`
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
                  AND `quantity` + ? >= 0
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
                  AND `reserved_quantity` + ? >= 0
                  AND `reserved_quantity` + ? <= `quantity`
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
    local insertStatement = [[
        INSERT INTO `czcraft_active_cycles`
            (`cycle_id`, `cycle_sequence`, `machine_uuid`, `bill_id`, `recipe_id`,
             `recipe_hash`, `recipe_snapshot`, `started_at`, `due_at`,
             `duration_seconds`, `reserved_output_weight`, `standard_cost`)
        VALUES (?, ?, ?, ?, ?, SHA2(?, 256), ?, ?, ?, ?, ?, ?)
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
    }

    -- Update the machine's active_cycle_id and operational_status.
    local updateMachineStatement = [[
        UPDATE `czcraft_machines`
        SET `active_cycle_id` = ?,
            `operational_status` = 'RUNNING',
            `next_due_at` = ?,
            `version` = `version` + 1
        WHERE `machine_uuid` = ?
    ]]
    local updateMachineArgs = {
        params.cycle_id,
        dueAtIso,
        params.machine_uuid,
    }

    -- Execute everything in a transaction.
    local ok, err = pcall(function()
        MySQL.transaction.await(function()
            -- 1. Insert the active cycle.
            MySQL.update(insertStatement, insertArgs)
            -- 2. Apply stock deltas.
            for i = 1, #deltaStatements do
                MySQL.update(deltaStatements[i], deltaArgs[i])
            end
            -- 3. Update the machine.
            MySQL.update(updateMachineStatement, updateMachineArgs)
        end)
    end)

    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

-- Completes a cycle: moves reserved output to actual stock, deletes the active
-- cycle row, and inserts a production event. Idempotent: if the cycle_id
-- already has a production event (unique idempotency_key), the transaction
-- is a no-op.
-- @param params table {
--   cycle_id, machine_uuid, bill_id?, completion_deltas = { { item_name, quantity_delta, reserved_delta } },
--   idempotency_key, cycles_completed = 1, inputs_json, outputs_json, cost, started_at, ended_at,
-- }
-- @return boolean ok
-- @return string|nil error
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
                  AND `reserved_quantity` + ? >= 0
            ]]
            deltaArgs[#deltaArgs + 1] = {
                delta.reserved_delta,
                params.machine_uuid,
                delta.item_name,
                delta.reserved_delta,
            }
        end
    end

    -- Insert the production event (idempotent via unique idempotency_key).
    local insertEventStatement = [[
        INSERT INTO `czcraft_production_events`
            (`event_id`, `machine_uuid`, `bill_id`, `cycles_completed`,
             `inputs`, `outputs`, `cost`, `started_at`, `ended_at`,
             `idempotency_key`, `status`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'COMMITTED')
        ON DUPLICATE KEY UPDATE `event_id` = `event_id`
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
    local updateMachineStatement = [[
        UPDATE `czcraft_machines`
        SET `active_cycle_id` = NULL,
            `operational_status` = 'STOPPED',
            `version` = `version` + 1
        WHERE `machine_uuid` = ?
    ]]

    local ok, err = pcall(function()
        MySQL.transaction.await(function()
            -- 1. Insert the production event (idempotent).
            MySQL.update(insertEventStatement, insertEventArgs)
            -- 2. Apply completion stock deltas.
            for i = 1, #deltaStatements do
                MySQL.update(deltaStatements[i], deltaArgs[i])
            end
            -- 3. Delete the active cycle.
            MySQL.update(deleteCycleStatement, { params.machine_uuid, params.cycle_id })
            -- 4. Update the machine.
            MySQL.update(updateMachineStatement, { params.machine_uuid })
        end)
    end)

    if not ok then
        return false, tostring(err)
    end
    return true, nil
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

CZCraft.CyclesRepo = CyclesRepo
return CyclesRepo
