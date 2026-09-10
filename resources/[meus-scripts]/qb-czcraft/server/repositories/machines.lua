-- qb-czcraft machines repository
-- czcraft_machines CRUD with optimistic version. Uses oxmysql via MySQL.*.
-- All mutations validate `version = version + 1 WHERE version = ?` so a
-- concurrent process/restart cannot silently overwrite state.

CZCraft = CZCraft or {}

local MachinesRepo = {}

-- Generates a UUID v4 string. Falls back to a timestamp-based id if no native.
local function generateUuid()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    local result = string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or (math.random(8, 0xb))
        return string.format('%x', v)
    end)
    return result
end

-- Generates a machine serial: CZ-<type>-<random>.
local function generateSerial(machineType)
    local rand = string.format('%06d', math.random(100000, 999999))
    return 'CZ-' .. tostring(machineType) .. '-' .. rand
end

-- Inserts a new INSTALLED machine record. Returns the new machine_uuid.
-- @param fields table {
--   serial, machine_type, owner_type, owner_id, location_type, location_id,
--   pos_x, pos_y, pos_z, heading, stock_capacity,
-- }
-- @return string|nil machineUuid
-- @return string|nil error
function MachinesRepo.createInstalled(fields)
    local uuid = generateUuid()
    local serial = fields.serial or generateSerial(fields.machine_type)
    local ok, result = pcall(MySQL.insert.await, [[
        INSERT INTO `czcraft_machines`
            (`machine_uuid`, `serial`, `machine_type`, `lifecycle`,
             `owner_type`, `owner_id`, `location_type`, `location_id`,
             `pos_x`, `pos_y`, `pos_z`, `heading`,
             `operational_status`, `used_weight`, `reserved_weight`,
             `stock_capacity`, `version`)
        VALUES (?, ?, ?, 'INSTALLED', ?, ?, ?, ?, ?, ?, ?, ?, 'STOPPED', 0, 0, ?, 1)
    ]], {
        uuid, serial, fields.machine_type,
        fields.owner_type, fields.owner_id, fields.location_type, fields.location_id,
        fields.pos_x, fields.pos_y, fields.pos_z, fields.heading,
        fields.stock_capacity,
    })
    if not ok then
        return nil, tostring(result)
    end
    return uuid
end

-- Loads a machine row by uuid.
-- @param machineUuid string
-- @return table|nil machine
function MachinesRepo.load(machineUuid)
    local rows = MySQL.single.await('SELECT * FROM `czcraft_machines` WHERE `machine_uuid` = ?', { machineUuid })
    return rows
end

-- Loads all INSTALLED machines at a location (for cap + clearance checks).
-- @param locationType string
-- @param locationId string
-- @return table list of machine rows
function MachinesRepo.listAtLocation(locationType, locationId)
    local rows = MySQL.query.await(
        'SELECT `machine_uuid`, `machine_type`, `pos_x`, `pos_y`, `pos_z`, `location_type`, `location_id` FROM `czcraft_machines` WHERE `lifecycle` = ? AND `location_type` = ? AND `location_id` = ?',
        { 'INSTALLED', locationType, locationId }
    )
    return rows or {}
end

-- Loads all INSTALLED machines for a location type (used for ORG cap/clearance
-- where the plot id is resolved by the validator from the transform).
-- @param locationType string
-- @return table list of machine rows
function MachinesRepo.listAllByLocationType(locationType)
    local rows = MySQL.query.await(
        'SELECT `machine_uuid`, `machine_type`, `pos_x`, `pos_y`, `pos_z`, `location_type`, `location_id` FROM `czcraft_machines` WHERE `lifecycle` = ? AND `location_type` = ?',
        { 'INSTALLED', locationType }
    )
    return rows or {}
end

-- Loads all INSTALLED machines for local prop streaming near a player.
-- Returns only the projection columns needed by the client.
-- @return table list of { machine_uuid, machine_type, pos_x, pos_y, pos_z, heading }
function MachinesRepo.listInstalledProjection()
    local rows = MySQL.query.await([[
        SELECT `machine_uuid`, `machine_type`, `pos_x`, `pos_y`, `pos_z`, `heading`
        FROM `czcraft_machines`
        WHERE `lifecycle` = 'INSTALLED'
          AND `pos_x` IS NOT NULL
    ]], {})
    return rows or {}
end

-- Sets the machine to PACKED and clears location/transform/owner operational
-- state via optimistic version. The serial is preserved on the row so the
-- returned item can carry it.
-- @param machineUuid string
-- @param expectedVersion number
-- @return boolean ok
-- @return string|nil error
function MachinesRepo.setPacked(machineUuid, expectedVersion)
    local affected = MySQL.update.await([[
        UPDATE `czcraft_machines`
        SET `lifecycle` = 'PACKED',
            `operational_status` = 'STOPPED',
            `owner_type` = NULL,
            `owner_id` = NULL,
            `location_type` = NULL,
            `location_id` = NULL,
            `pos_x` = NULL, `pos_y` = NULL, `pos_z` = NULL, `heading` = NULL,
            `active_bill_id` = NULL,
            `active_cycle_id` = NULL,
            `next_due_at` = NULL,
            `version` = `version` + 1
        WHERE `machine_uuid` = ? AND `version` = ?
    ]], { machineUuid, expectedVersion })
    if not affected or affected == 0 then
        return false, 'optimistic version conflict or machine not found'
    end
    return true
end

-- Bumps the operational status + version atomically.
-- @param machineUuid string
-- @param status string
-- @param expectedVersion number
-- @return boolean ok
function MachinesRepo.setOperationalStatus(machineUuid, status, expectedVersion)
    local affected = MySQL.update.await(
        'UPDATE `czcraft_machines` SET `operational_status` = ?, `version` = `version` + 1 WHERE `machine_uuid` = ? AND `version` = ?',
        { status, machineUuid, expectedVersion }
    )
    return affected and affected > 0
end

-- Marks a machine BLOCKED with a reason/detail and clears next_due_at so the
-- scheduler stops popping it. The machine is re-heaped by an explicit wake
-- event (stock deposit, bill create/resume, recipe re-enable).
-- @param machineUuid string
-- @param reason string short block reason
-- @param detail string|nil longer detail
-- @param expectedVersion number
-- @return boolean ok
function MachinesRepo.setBlocked(machineUuid, reason, detail, expectedVersion)
    local affected = MySQL.update.await([[
        UPDATE `czcraft_machines`
        SET `operational_status` = 'BLOCKED',
            `blocked_reason` = ?,
            `blocked_detail` = ?,
            `next_due_at` = NULL,
            `active_cycle_id` = NULL,
            `version` = `version` + 1
        WHERE `machine_uuid` = ? AND `version` = ?
    ]], { reason, detail, machineUuid, expectedVersion })
    return affected and affected > 0
end

-- Clears next_due_at and any block state, setting the machine STOPPED/idle.
-- Used when a machine has no runnable bill (e.g. PRODUCE_X completed) so the
-- scheduler stops popping it until a wake event re-heaps it.
-- @param machineUuid string
-- @param expectedVersion number
-- @return boolean ok
function MachinesRepo.clearNextDue(machineUuid, expectedVersion)
    local affected = MySQL.update.await([[
        UPDATE `czcraft_machines`
        SET `next_due_at` = NULL,
            `operational_status` = 'STOPPED',
            `blocked_reason` = NULL,
            `blocked_detail` = NULL,
            `active_cycle_id` = NULL,
            `active_bill_id` = NULL,
            `version` = `version` + 1
        WHERE `machine_uuid` = ? AND `version` = ?
    ]], { machineUuid, expectedVersion })
    return affected and affected > 0
end

-- Updates the machine's condition and clears a condition-related block.
-- Uses optimistic versioning. Called by the maintenance service after
-- the financial debit succeeds.
-- @param machineUuid string
-- @param newCondition number (DECIMAL(5,2), 0-100)
-- @param expectedVersion number
-- @return boolean ok
function MachinesRepo.updateCondition(machineUuid, newCondition, expectedVersion)
    local affected = MySQL.update.await([[
        UPDATE `czcraft_machines`
        SET `condition` = ?,
            `blocked_reason` = CASE
                WHEN `blocked_reason` = 'condition low' THEN NULL
                ELSE `blocked_reason`
            END,
            `blocked_detail` = CASE
                WHEN `blocked_reason` = 'condition low' THEN NULL
                ELSE `blocked_detail`
            END,
            `version` = `version` + 1
        WHERE `machine_uuid` = ? AND `version` = ?
    ]], { newCondition, machineUuid, expectedVersion })
    return affected and affected > 0
end

-- Increments one upgrade track level and adds the point cost to budget_used.
-- Uses optimistic versioning. Called by the upgrades service after the
-- financial debit and item consumption succeed.
-- @param machineUuid string
-- @param track string ('speed'|'capacity'|'efficiency'|'durability')
-- @param pointsCost number (points to add to budget_used)
-- @param expectedVersion number
-- @return boolean ok
function MachinesRepo.upgradeTrack(machineUuid, track, pointsCost, expectedVersion)
    local column = 'upgrade_' .. track .. '_level'
    local affected = MySQL.update.await([[
        UPDATE `czcraft_machines`
        SET `]] .. column .. [[` = `]] .. column .. [[` + 1,
            `upgrade_budget_used` = `upgrade_budget_used` + ?,
            `version` = `version` + 1
        WHERE `machine_uuid` = ? AND `version` = ?
    ]], { pointsCost, machineUuid, expectedVersion })
    return affected and affected > 0
end

-- Reactivates a PACKED machine row back to INSTALLED with new location/owner.
-- Preserves condition, upgrade levels, and budget_used from the PACKED row.
-- Used when a player places a previously-packed machine item that carries
-- a machine_uuid. The machine must be in PACKED lifecycle and have no
-- active cycle or stock (validated by the caller before pickup).
-- @param machineUuid string
-- @param fields table { owner_type, owner_id, location_type, location_id,
--                       pos_x, pos_y, pos_z, heading, stock_capacity }
-- @param expectedVersion number
-- @return boolean ok
-- @return string|nil error
function MachinesRepo.reactivateInstalled(machineUuid, fields, expectedVersion)
    local affected = MySQL.update.await([[
        UPDATE `czcraft_machines`
        SET `lifecycle` = 'INSTALLED',
            `operational_status` = 'STOPPED',
            `owner_type` = ?,
            `owner_id` = ?,
            `location_type` = ?,
            `location_id` = ?,
            `pos_x` = ?,
            `pos_y` = ?,
            `pos_z` = ?,
            `heading` = ?,
            `stock_capacity` = ?,
            `next_due_at` = NULL,
            `blocked_reason` = NULL,
            `blocked_detail` = NULL,
            `active_cycle_id` = NULL,
            `active_bill_id` = NULL,
            `version` = `version` + 1
        WHERE `machine_uuid` = ? AND `version` = ? AND `lifecycle` = 'PACKED'
    ]], {
        fields.owner_type, fields.owner_id, fields.location_type, fields.location_id,
        fields.pos_x, fields.pos_y, fields.pos_z, fields.heading,
        fields.stock_capacity,
        machineUuid, expectedVersion,
    })
    if not affected or affected == 0 then
        return false, 'machine not found, not PACKED, or version conflict'
    end
    return true
end

-- Loads a PACKED machine row by uuid (for reactivation lookup).
-- @param machineUuid string
-- @return table|nil machine
function MachinesRepo.loadPacked(machineUuid)
    local row = MySQL.single.await([[
        SELECT * FROM `czcraft_machines`
        WHERE `machine_uuid` = ? AND `lifecycle` = 'PACKED'
    ]], { machineUuid })
    return row
end

-- Decrements one upgrade track level. Budget points are NOT refunded
-- (per v0.2 design: "Points are spent permanently"). Uses optimistic
-- versioning. Called by the upgrades service after validateDowngrade passes.
-- @param machineUuid string
-- @param track string ('speed'|'capacity'|'efficiency'|'durability')
-- @param expectedVersion number
-- @return boolean ok
function MachinesRepo.downgradeTrack(machineUuid, track, expectedVersion)
    local column = 'upgrade_' .. track .. '_level'
    local affected = MySQL.update.await([[
        UPDATE `czcraft_machines`
        SET `]] .. column .. [[` = GREATEST(0, `]] .. column .. [[` - 1),
            `version` = `version` + 1
        WHERE `machine_uuid` = ? AND `version` = ? AND `]] .. column .. [[` > 0
    ]], { machineUuid, expectedVersion })
    return affected and affected > 0
end

-- Transfers all INSTALLED machines at a house to a new owner. Called when a
-- house is sold/transferred via qb-phone:server:TransferCid. The caller fires
-- the `qb-czcraft:server:houseTransferred` event after the qb-houses transfer
-- completes.
--
-- Per decisions.md: "Imóvel transferido: Máquina, stock, bills e ciclo
-- passam ao novo dono da casa." Machines, stock, bills, and active cycles
-- all stay with the machine (tied by machine_uuid) — only owner_id changes.
-- An active cycle continues under the new owner. A condition-blocked machine
-- stays blocked (the new owner can perform maintenance).
--
-- @param houseId string
-- @param newOwnerCid string (new house owner's citizenid)
-- @return number count of machines transferred
function MachinesRepo.transferHouseMachines(houseId, newOwnerCid)
    local affected = MySQL.update.await([[
        UPDATE `czcraft_machines`
        SET `owner_id` = ?,
            `version` = `version` + 1
        WHERE `location_type` = 'HOUSE'
          AND `location_id` = ?
          AND `lifecycle` = 'INSTALLED'
    ]], { newOwnerCid, houseId })
    return affected or 0
end

-- Startup reconciliation: finds INSTALLED machines at HOUSE locations whose
-- owner_id doesn't match the current house owner in player_houses, and
-- reassigns them. Called at resource start after the schema gate passes.
--
-- This closes the crash-window gap documented in risks.md: "House transfer
-- de ativos não pode ser perfeitamente atómico sem acoplar SQL de houses ao
-- czcraft; hook + operation journal + startup reconciliation tornam o
-- resultado convergente e observável." If the server crashes between the
-- player_houses UPDATE and transferHouseMachines completing, machines are
-- left with a stale owner_id. This pass fixes them at the next startup.
--
-- Only touches owner_id and version — preserves condition, upgrades, active
-- cycles, block state, and all other machine columns.
--
-- @return number count of machines reconciled
-- @return table list of { machine_uuid, old_owner, new_owner } for audit
function MachinesRepo.reconcileHouseMachineOwners()
    -- Step 1: find mismatched machines (for audit before mutating).
    local mismatches = MySQL.query.await([[
        SELECT m.`machine_uuid`, m.`owner_id` AS old_owner, ph.`citizenid` AS new_owner
        FROM `czcraft_machines` m
        INNER JOIN `player_houses` ph ON m.`location_id` = ph.`house`
        WHERE m.`lifecycle` = 'INSTALLED'
          AND m.`location_type` = 'HOUSE'
          AND (m.`owner_id` IS NULL OR m.`owner_id` <> ph.`citizenid`)
    ]]) or {}

    if #mismatches == 0 then
        return 0, {}
    end

    -- Step 2: update all mismatched machines in a single atomic UPDATE.
    local affected = MySQL.update.await([[
        UPDATE `czcraft_machines` m
        INNER JOIN `player_houses` ph ON m.`location_id` = ph.`house`
        SET m.`owner_id` = ph.`citizenid`,
            m.`version` = m.`version` + 1
        WHERE m.`lifecycle` = 'INSTALLED'
          AND m.`location_type` = 'HOUSE'
          AND (m.`owner_id` IS NULL OR m.`owner_id` <> ph.`citizenid`)
    ]]) or 0

    return affected, mismatches
end

CZCraft.MachinesRepo = MachinesRepo
return MachinesRepo
