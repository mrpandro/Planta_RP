-- qb-czcraft stock repository
-- Persists czcraft_machine_stock rows: per-machine, per-item, per-metadata-key
-- stock ledger with quantity, reserved_quantity, and standard_unit_cost.
-- All mutations use optimistic version checks.

CZCraft = CZCraft or {}

local StockRepo = {}

-- Loads all stock rows for a machine.
-- @param machineUuid string
-- @return table list of { item_name, metadata_key, quantity, reserved_quantity, standard_unit_cost, version }
function StockRepo.loadAll(machineUuid)
    return MySQL.query.await([[
        SELECT `item_name`, `metadata_key`, `quantity`, `reserved_quantity`,
               `standard_unit_cost`, `version`
        FROM `czcraft_machine_stock`
        WHERE `machine_uuid` = ?
    ]], { machineUuid }) or {}
end

-- Loads a single stock row.
-- @param machineUuid string
-- @param itemName string
-- @param metadataKey string (defaults to '')
-- @return table|nil row
function StockRepo.load(machineUuid, itemName, metadataKey)
    return MySQL.single.await([[
        SELECT `item_name`, `metadata_key`, `quantity`, `reserved_quantity`,
               `standard_unit_cost`, `version`
        FROM `czcraft_machine_stock`
        WHERE `machine_uuid` = ? AND `item_name` = ? AND `metadata_key` = ?
    ]], { machineUuid, itemName, metadataKey or '' })
end

-- Inserts a new stock row. Fails if the row already exists (PK violation).
-- @param params table { machine_uuid, item_name, metadata_key?, quantity, reserved_quantity?, standard_unit_cost? }
-- @return boolean ok
-- @return string|nil error
function StockRepo.insert(params)
    local affected, err = MySQL.update.await([[
        INSERT INTO `czcraft_machine_stock`
            (`machine_uuid`, `item_name`, `metadata_key`, `quantity`,
             `reserved_quantity`, `standard_unit_cost`)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], {
        params.machine_uuid,
        params.item_name,
        params.metadata_key or '',
        params.quantity or 0,
        params.reserved_quantity or 0,
        params.standard_unit_cost or 0,
    })
    if err then
        return false, tostring(err)
    end
    return affected > 0, nil
end

-- Applies a stock delta (quantity and/or reserved change) with optimistic version.
-- Fails if the version doesn't match (concurrent modification).
-- @param machineUuid string
-- @param itemName string
-- @param metadataKey string
-- @param expectedVersion number
-- @param quantityDelta number (can be negative)
-- @param reservedDelta number (can be negative)
-- @return boolean ok
-- @return string|nil error
function StockRepo.applyDelta(machineUuid, itemName, metadataKey, expectedVersion, quantityDelta, reservedDelta)
    -- Guards use CAST(... AS SIGNED) to avoid BIGINT UNSIGNED underflow.
    -- The quantity/reserved_quantity columns are INT(10) UNSIGNED, so
    -- `quantity + (-5) >= 0` underflows and throws "INTEGER UNSIGNED value
    -- is out of range" before the >= 0 comparison can protect it. Casting
    -- to SIGNED makes the arithmetic safe; the comparison result is the
    -- same. The SET clause is safe because the WHERE clause ensures the
    -- post-delta values are valid before the UPDATE executes.
    local affected = MySQL.update.await([[
        UPDATE `czcraft_machine_stock`
        SET `quantity`          = `quantity` + ?,
            `reserved_quantity` = `reserved_quantity` + ?,
            `version`           = `version` + 1
        WHERE `machine_uuid` = ?
          AND `item_name` = ?
          AND `metadata_key` = ?
          AND `version` = ?
          AND CAST(`quantity` AS SIGNED) + ? >= 0
          AND CAST(`reserved_quantity` AS SIGNED) + ? >= 0
          AND CAST(`reserved_quantity` AS SIGNED) + ? <= CAST(`quantity` AS SIGNED) + ?
    ]], {
        quantityDelta, reservedDelta,
        machineUuid, itemName, metadataKey or '', expectedVersion,
        quantityDelta, reservedDelta, reservedDelta, quantityDelta,
    })
    if affected == 0 then
        return false, 'optimistic version mismatch or constraint violation'
    end
    return true, nil
end

-- Upserts a stock row (insert or update quantity/reserved).
-- @param params table { machine_uuid, item_name, metadata_key?, quantity, reserved_quantity?, standard_unit_cost? }
-- @return boolean ok
function StockRepo.upsert(params)
    MySQL.update.await([[
        INSERT INTO `czcraft_machine_stock`
            (`machine_uuid`, `item_name`, `metadata_key`, `quantity`,
             `reserved_quantity`, `standard_unit_cost`)
        VALUES (?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            `quantity`           = VALUES(`quantity`),
            `reserved_quantity`  = VALUES(`reserved_quantity`),
            `standard_unit_cost` = VALUES(`standard_unit_cost`),
            `version`            = `version` + 1
    ]], {
        params.machine_uuid,
        params.item_name,
        params.metadata_key or '',
        params.quantity or 0,
        params.reserved_quantity or 0,
        params.standard_unit_cost or 0,
    })
    return true
end

-- Deletes all stock rows for a machine (used on pickup when stock is zero).
-- @param machineUuid string
-- @return number rowsDeleted
function StockRepo.deleteAll(machineUuid)
    local affected = MySQL.update.await([[
        DELETE FROM `czcraft_machine_stock` WHERE `machine_uuid` = ?
    ]], { machineUuid })
    return affected or 0
end

-- Returns aggregate stock sums for a machine.
-- @param machineUuid string
-- @return table { total_quantity, total_reserved }
function StockRepo.getSums(machineUuid)
    local row = MySQL.single.await([[
        SELECT COALESCE(SUM(`quantity`), 0) AS total_quantity,
               COALESCE(SUM(`reserved_quantity`), 0) AS total_reserved
        FROM `czcraft_machine_stock`
        WHERE `machine_uuid` = ?
    ]], { machineUuid })
    return {
        total_quantity = row and tonumber(row.total_quantity) or 0,
        total_reserved = row and tonumber(row.total_reserved) or 0,
    }
end

CZCraft.StockRepo = StockRepo
return StockRepo
