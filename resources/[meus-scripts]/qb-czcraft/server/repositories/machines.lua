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

CZCraft.MachinesRepo = MachinesRepo
return MachinesRepo
