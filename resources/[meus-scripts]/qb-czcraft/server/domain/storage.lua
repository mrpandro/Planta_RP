-- qb-czcraft storage domain (pure)
-- Stock weight math and capacity checks for per-machine SQL stock. Pure so it
-- runs under stock Lua 5.4 in tests; the repository layer persists the actual
-- czcraft_machine_stock rows.

CZCraft = CZCraft or {}

-- Computes the used weight of a stock row set given an item weight registry.
-- @param stockRows table list of { item_name, quantity }
-- @param itemWeights table { [item_name] = weight_in_grams }
-- @return number usedWeight
local function computeUsedWeight(stockRows, itemWeights)
    if type(stockRows) ~= 'table' then return 0 end
    local total = 0
    for _, row in ipairs(stockRows) do
        if row and type(row.item_name) == 'string' and type(row.quantity) == 'number' then
            local weight = itemWeights and itemWeights[row.item_name] or 0
            if type(weight) == 'number' then
                total = total + (weight * row.quantity)
            end
        end
    end
    return total
end

-- Computes the reserved output weight for a set of reserved output lines.
-- @param reservedLines table list of { item_name, reserved_quantity }
-- @param itemWeights table { [item_name] = weight_in_grams }
-- @return number reservedWeight
local function computeReservedWeight(reservedLines, itemWeights)
    if type(reservedLines) ~= 'table' then return 0 end
    local total = 0
    for _, line in ipairs(reservedLines) do
        if line and type(line.item_name) == 'string' and type(line.reserved_quantity) == 'number' then
            local weight = itemWeights and itemWeights[line.item_name] or 0
            if type(weight) == 'number' then
                total = total + (weight * line.reserved_quantity)
            end
        end
    end
    return total
end

-- Checks whether a deposit of `deltaWeight` grams fits within the remaining
-- capacity after accounting for used + reserved weight.
-- @param usedWeight number
-- @param reservedWeight number
-- @param capacity number
-- @param deltaWeight number grams to add
-- @return boolean ok
-- @return string|nil reason
local function canDepositWeight(usedWeight, reservedWeight, capacity, deltaWeight)
    if type(capacity) ~= 'number' or capacity < 0 then
        return false, 'capacity must be a non-negative number'
    end
    if type(deltaWeight) ~= 'number' or deltaWeight < 0 then
        return false, 'deltaWeight must be a non-negative number'
    end
    local projected = (usedWeight or 0) + (reservedWeight or 0) + deltaWeight
    if projected > capacity then
        return false, ('deposit exceeds capacity (%d > %d)'):format(projected, capacity)
    end
    return true
end

-- Sums quantity across stock rows.
-- @param stockRows table list of { quantity }
-- @return number total
local function sumQuantity(stockRows)
    if type(stockRows) ~= 'table' then return 0 end
    local total = 0
    for _, row in ipairs(stockRows) do
        if row and type(row.quantity) == 'number' then
            total = total + row.quantity
        end
    end
    return total
end

-- Sums reserved_quantity across stock rows.
-- @param stockRows table list of { reserved_quantity }
-- @return number total
local function sumReserved(stockRows)
    if type(stockRows) ~= 'table' then return 0 end
    local total = 0
    for _, row in ipairs(stockRows) do
        if row and type(row.reserved_quantity) == 'number' then
            total = total + row.reserved_quantity
        end
    end
    return total
end

CZCraft.Storage = {
    computeUsedWeight = computeUsedWeight,
    computeReservedWeight = computeReservedWeight,
    canDepositWeight = canDepositWeight,
    sumQuantity = sumQuantity,
    sumReserved = sumReserved,
}

return CZCraft.Storage
