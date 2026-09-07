-- qb-czcraft production domain (pure cycle state machine)
-- Cycle start: consume inputs + reserve output weight atomically.
-- Cycle complete: idempotent — same cycle_id/sequence never double-produces.
-- The repository layer persists the actual SQL rows; this module computes the
-- state transitions and validates preconditions.
--
-- Invariants (from overview.md):
--   - Input is consumed at cycle start; output weight is reserved in the same
--     commit.
--   - Cycle completion is idempotent: completing the same cycle_id/sequence
--     twice does not create additional outputs.
--   - Recipe hash/snapshot is persisted per cycle so later edits don't change
--     an in-flight cycle.

CZCraft = CZCraft or {}

local CycleStatus = {
    PENDING = 'PENDING',
    RUNNING = 'RUNNING',
    COMPLETED = 'COMPLETED',
    FAILED = 'FAILED',
}

-- Validates that a cycle can start: inputs must be available, output capacity
-- must accommodate the reserved output weight.
-- @param params table {
--   recipe = { inputs, outputs, duration, primaryOutput },
--   stockRows = { { item_name, quantity, reserved_quantity } },
--   machineUsedWeight, machineReservedWeight, machineCapacity,
--   itemWeights = { [item_name] = weight },
-- }
-- @return boolean ok
-- @return string|nil reason
-- @return table|nil computed = { inputsToConsume, outputsToReserve, reservedWeightDelta }
local function validateCycleStart(params)
    if type(params) ~= 'table' then
        return false, 'params must be a table'
    end
    local recipe = params.recipe
    if type(recipe) ~= 'table' then
        return false, 'recipe required'
    end
    if type(recipe.inputs) ~= 'table' or #recipe.inputs == 0 then
        return false, 'recipe.inputs must be a nonempty list'
    end
    if type(recipe.outputs) ~= 'table' or #recipe.outputs == 0 then
        return false, 'recipe.outputs must be a nonempty list'
    end

    -- Build a stock lookup by item_name.
    local stockByItem = {}
    if type(params.stockRows) == 'table' then
        for _, row in ipairs(params.stockRows) do
            if row and row.item_name then
                stockByItem[row.item_name] = {
                    quantity = row.quantity or 0,
                    reserved_quantity = row.reserved_quantity or 0,
                }
            end
        end
    end

    -- Check input availability: quantity (not reserved) must be >= input amount.
    local inputsToConsume = {}
    for _, line in ipairs(recipe.inputs) do
        local stock = stockByItem[line.item]
        local available = stock and (stock.quantity - stock.reserved_quantity) or 0
        if available < line.amount then
            return false, ('insufficient input %s: have %d available, need %d'):format(
                line.item, available, line.amount)
        end
        inputsToConsume[#inputsToConsume + 1] = {
            item_name = line.item,
            amount = line.amount,
        }
    end

    -- Compute output weight to reserve.
    local itemWeights = params.itemWeights or {}
    local outputsToReserve = {}
    local reservedWeightDelta = 0
    for _, line in ipairs(recipe.outputs) do
        local weight = itemWeights[line.item] or 0
        local lineWeight = weight * line.amount
        reservedWeightDelta = reservedWeightDelta + lineWeight
        outputsToReserve[#outputsToReserve + 1] = {
            item_name = line.item,
            amount = line.amount,
            weight = lineWeight,
        }
    end

    -- Check output capacity: used + reserved + new reserved <= capacity.
    local usedWeight = params.machineUsedWeight or 0
    local currentReserved = params.machineReservedWeight or 0
    local capacity = params.machineCapacity or 0
    if usedWeight + currentReserved + reservedWeightDelta > capacity then
        return false, ('output cap: %d + %d + %d > %d'):format(
            usedWeight, currentReserved, reservedWeightDelta, capacity)
    end

    return true, nil, {
        inputsToConsume = inputsToConsume,
        outputsToReserve = outputsToReserve,
        reservedWeightDelta = reservedWeightDelta,
    }
end

-- Computes the stock deltas for a cycle start (inputs consumed, outputs
-- reserved). Returns the row-level mutations the repository should apply.
-- @param computed table from validateCycleStart
-- @return table { stockDeltas = { { item_name, quantity_delta, reserved_delta } } }
local function computeStartDeltas(computed)
    local deltas = {}

    -- Inputs: quantity decreases, reserved unchanged.
    for _, input in ipairs(computed.inputsToConsume) do
        deltas[#deltas + 1] = {
            item_name = input.item_name,
            quantity_delta = -input.amount,
            reserved_delta = 0,
        }
    end

    -- Outputs: quantity unchanged (not yet produced), reserved increases.
    for _, output in ipairs(computed.outputsToReserve) do
        deltas[#deltas + 1] = {
            item_name = output.item_name,
            quantity_delta = 0,
            reserved_delta = output.amount,
        }
    end

    return { stockDeltas = deltas }
end

-- Computes the stock deltas for a cycle completion (reserved -> actual).
-- Idempotent: the repository checks that the cycle is in RUNNING state and
-- the cycle_id/sequence hasn't already been completed.
-- @param computed table from validateCycleStart
-- @return table { stockDeltas = { { item_name, quantity_delta, reserved_delta } } }
local function computeCompletionDeltas(computed)
    local deltas = {}

    -- Outputs: reserved decreases, quantity increases (reserved -> actual).
    for _, output in ipairs(computed.outputsToReserve) do
        deltas[#deltas + 1] = {
            item_name = output.item_name,
            quantity_delta = output.amount,
            reserved_delta = -output.amount,
        }
    end

    return { stockDeltas = deltas }
end

-- Checks whether a cycle completion is idempotent (not already completed).
-- @param cycle table { status, cycle_id, cycle_sequence }
-- @return boolean canComplete
-- @return string|nil reason
local function canCompleteCycle(cycle)
    if type(cycle) ~= 'table' then
        return false, 'cycle must be a table'
    end
    if cycle.status == CycleStatus.COMPLETED then
        return false, 'cycle already completed (idempotent no-op)'
    end
    if cycle.status ~= CycleStatus.RUNNING then
        return false, 'cycle must be RUNNING to complete (was ' .. tostring(cycle.status) .. ')'
    end
    return true
end

-- Computes the next due time for a machine after completing a cycle.
-- @param completedAt number unix timestamp (seconds, UTC)
-- @param durationSeconds number recipe duration
-- @return number nextDueAt
local function computeNextDue(completedAt, durationSeconds)
    return (completedAt or 0) + (durationSeconds or 0)
end

CZCraft.Production = {
    CycleStatus = CycleStatus,
    validateCycleStart = validateCycleStart,
    computeStartDeltas = computeStartDeltas,
    computeCompletionDeltas = computeCompletionDeltas,
    canCompleteCycle = canCompleteCycle,
    computeNextDue = computeNextDue,
}

return CZCraft.Production
