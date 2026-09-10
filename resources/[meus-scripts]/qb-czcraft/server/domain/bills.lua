-- qb-czcraft bills domain (pure)
-- Bill creation, pause/remove semantics, and stable selection logic for
-- PRODUCE_X and MAINTAIN_X modes. Pure so it runs under stock Lua 5.4 in tests.
--
-- Bill semantics (from decisions.md):
--   PRODUCE_X: target in primary-output units, must be a multiple of the batch
--     size; counts COMPLETED primary-output units, not current stock.
--     Withdrawing stock never reopens a finished bill.
--   MAINTAIN_X: compares stock + reserved output; may exceed target by at
--     most one batch.
--   Pause: current cycle finishes; no new cycle starts.
--   Remove: pause + mark removed (stock/reservations unaffected).
--   Selection: stable order by (enabled, priority, created_sequence).

CZCraft = CZCraft or {}

local BillMode = {
    PRODUCE_X = 'PRODUCE_X',
    MAINTAIN_X = 'MAINTAIN_X',
    UNTIL_X = 'UNTIL_X',
}

local BillStatus = {
    PENDING = 'PENDING',
    ACTIVE = 'ACTIVE',
    PAUSED = 'PAUSED',
    COMPLETED = 'COMPLETED',
    REMOVED = 'REMOVED',
}

-- v0.2 bill priorities. Lower sortValue = higher priority. The sort values
-- match config/balance.lua; a built-in default keeps the domain correct even
-- when no injected sort map is supplied (e.g. pure unit tests).
local BillPriority = {
    HIGH = 'HIGH',
    NORMAL = 'NORMAL',
    LOW = 'LOW',
}

local DEFAULT_PRIORITY_SORT = {
    HIGH = 1,
    NORMAL = 2,
    LOW = 3,
}

-- Resolves a priority name to a numeric sort value. Unknown priorities sort
-- last (999) so a misconfigured bill cannot preempt valid ones.
-- @param priority string
-- @param sortValues table|nil injected { [priority] = number } (from config)
-- @return number
local function prioritySortValue(priority, sortValues)
    if sortValues and sortValues[priority] then
        return sortValues[priority]
    end
    return DEFAULT_PRIORITY_SORT[priority] or 999
end

-- Validates a bill creation request.
-- @param params table {
--   mode, recipeId, primaryOutput, targetQuantity, batchOutputAmount,
--   priority? = 'HIGH'|'NORMAL'|'LOW', untilThreshold? (required for UNTIL_X),
--   createdBy = { type, id },
-- }
-- @return boolean ok
-- @return string|nil reason
local function validateBillCreation(params)
    if type(params) ~= 'table' then
        return false, 'params must be a table'
    end
    if params.mode ~= BillMode.PRODUCE_X
       and params.mode ~= BillMode.MAINTAIN_X
       and params.mode ~= BillMode.UNTIL_X then
        return false, 'mode must be PRODUCE_X, MAINTAIN_X, or UNTIL_X'
    end
    if type(params.recipeId) ~= 'string' or params.recipeId == '' then
        return false, 'recipeId must be a nonempty string'
    end
    if type(params.primaryOutput) ~= 'string' or params.primaryOutput == '' then
        return false, 'primaryOutput must be a nonempty string'
    end
    if type(params.targetQuantity) ~= 'number'
        or params.targetQuantity ~= math.floor(params.targetQuantity)
        or params.targetQuantity <= 0 then
        return false, 'targetQuantity must be a positive integer'
    end
    if type(params.batchOutputAmount) ~= 'number'
        or params.batchOutputAmount ~= math.floor(params.batchOutputAmount)
        or params.batchOutputAmount <= 0 then
        return false, 'batchOutputAmount must be a positive integer'
    end

    -- Priority (defaults to NORMAL when omitted).
    local priority = params.priority or BillPriority.NORMAL
    if priority ~= BillPriority.HIGH
       and priority ~= BillPriority.NORMAL
       and priority ~= BillPriority.LOW then
        return false, 'priority must be HIGH, NORMAL, or LOW'
    end

    -- PRODUCE_X: target must be a multiple of the batch output amount.
    if params.mode == BillMode.PRODUCE_X then
        if params.targetQuantity % params.batchOutputAmount ~= 0 then
            return false, ('PRODUCE_X target (%d) must be a multiple of batch output (%d)'):format(
                params.targetQuantity, params.batchOutputAmount)
        end
    end

    -- UNTIL_X: until_threshold is the stock target. It must be a positive
    -- integer, a multiple of the batch output (validated against batch size at
    -- creation time so production lands exactly on the threshold without
    -- overshoot), and at least the configured minimum. target_quantity is
    -- required > 0 by the schema for all modes; for UNTIL_X the caller sets it
    -- equal to until_threshold (the domain reads until_threshold).
    if params.mode == BillMode.UNTIL_X then
        local untilThreshold = params.untilThreshold
        if type(untilThreshold) ~= 'number'
           or untilThreshold ~= math.floor(untilThreshold)
           or untilThreshold <= 0 then
            return false, 'UNTIL_X untilThreshold must be a positive integer'
        end
        if untilThreshold % params.batchOutputAmount ~= 0 then
            return false, ('UNTIL_X untilThreshold (%d) must be a multiple of batch output (%d)'):format(
                untilThreshold, params.batchOutputAmount)
        end
    else
        if params.untilThreshold ~= nil then
            return false, 'untilThreshold must only be set for UNTIL_X mode'
        end
    end

    return true
end

-- Checks whether a PRODUCE_X bill is complete (produced >= target).
-- @param bill table { mode, target_quantity, produced_quantity }
-- @return boolean complete
local function isProduceXComplete(bill)
    return (bill.produced_quantity or 0) >= bill.target_quantity
end

-- Checks whether a MAINTAIN_X bill is satisfied.
-- MAINTAIN_X compares stock + reserved output against the target. It may
-- exceed the target by at most one batch.
-- @param bill table { mode, target_quantity }
-- @param stockPlusReserved number current stock of primaryOutput + reserved output
-- @param batchOutputAmount number output per batch
-- @return boolean satisfied
local function isMaintainXSatisfied(bill, stockPlusReserved, batchOutputAmount)
    local available = stockPlusReserved or 0
    local target = bill.target_quantity
    -- Satisfied when available >= target. Overshoot by at most one batch is
    -- allowed: the cycle engine must not start a new cycle if
    -- available >= target (even if available < target + batchOutputAmount).
    return available >= target
end

-- Checks whether a UNTIL_X bill is satisfied.
-- UNTIL_X is satisfied when stock + reserved >= until_threshold. Unlike
-- MAINTAIN_X, UNTIL_X never overshoots: the threshold is a multiple of the
-- batch size (validated at creation), so production lands exactly on it.
-- @param bill table { until_threshold }
-- @param stockPlusReserved number
-- @return boolean satisfied
local function isUntilXSatisfied(bill, stockPlusReserved)
    local threshold = bill.until_threshold
    if not threshold then return true end
    return (stockPlusReserved or 0) >= threshold
end

-- Determines whether a new cycle should start for a bill.
-- PRODUCE_X: start if not complete (produced < target).
-- MAINTAIN_X: start if stock + reserved < target (may overshoot by one batch).
-- UNTIL_X: start only if a full batch fits without exceeding the threshold
--   (stock + reserved + batch <= until_threshold). This guarantees no
--   overshoot; a misaligned stock level (e.g. from a player deposit that is not
--   a multiple of the batch) leaves the machine idle just below the threshold
--   rather than overshooting — the player can withdraw to re-align.
-- @param bill table
-- @param stockPlusReserved number (for MAINTAIN_X / UNTIL_X)
-- @param batchOutputAmount number
-- @return boolean shouldStart
local function shouldStartCycle(bill, stockPlusReserved, batchOutputAmount)
    if not bill.enabled then
        return false
    end
    if bill.status == BillStatus.PAUSED or bill.status == BillStatus.REMOVED then
        return false
    end
    if bill.mode == BillMode.PRODUCE_X then
        return not isProduceXComplete(bill)
    end
    if bill.mode == BillMode.MAINTAIN_X then
        return not isMaintainXSatisfied(bill, stockPlusReserved, batchOutputAmount)
    end
    if bill.mode == BillMode.UNTIL_X then
        local threshold = bill.until_threshold
        if not threshold then return false end
        local available = stockPlusReserved or 0
        if available >= threshold then
            return false
        end
        -- Only start when a full batch fits without exceeding the threshold.
        return (available + batchOutputAmount) <= threshold
    end
    return false
end

-- Computes how many cycles of a recipe can run in a catch-up chunk given the
-- elapsed time, input availability, output capacity, and bill target.
-- This is the analytic multi-cycle computation: no per-cycle loops.
-- @param params table {
--   recipeDurationSeconds, elapsedSeconds, maxCyclesPerChunk,
--   inputAvailability = { [item_name] = available_count },
--   recipeInputs = { { item, amount } },
--   outputCapacityRemaining = number (grams or units),
--   outputWeightPerCycle = number,
--   bill = { mode, target_quantity, produced_quantity } | nil,
--   batchOutputAmount = number,
--   stockPlusReserved = number (for MAINTAIN_X),
-- }
-- @return number cyclesToRun (0 if blocked)
-- @return string|nil blockReason
local function computeCyclesForChunk(params)
    if type(params) ~= 'table' then
        return 0, 'params must be a table'
    end

    local duration = params.recipeDurationSeconds
    local elapsed = params.elapsedSeconds or 0
    if type(duration) ~= 'number' or duration <= 0 then
        return 0, 'invalid recipe duration'
    end
    if elapsed <= 0 then
        return 0, nil  -- zero/negative elapsed: no cycles to run
    end

    -- Time-bound: how many full cycles fit in the elapsed time.
    local timeBoundedCycles = math.floor(elapsed / duration)
    if timeBoundedCycles <= 0 then
        return 0, nil
    end

    -- Cap by max cycles per chunk.
    local maxCycles = params.maxCyclesPerChunk or timeBoundedCycles
    if maxCycles < timeBoundedCycles then
        timeBoundedCycles = maxCycles
    end

    -- Input-bound: how many cycles can the available inputs support.
    local inputBoundedCycles = timeBoundedCycles
    if type(params.recipeInputs) == 'table' and type(params.inputAvailability) == 'table' then
        for _, line in ipairs(params.recipeInputs) do
            local available = params.inputAvailability[line.item] or 0
            local cyclesFromThisInput = math.floor(available / line.amount)
            if cyclesFromThisInput < inputBoundedCycles then
                inputBoundedCycles = cyclesFromThisInput
            end
        end
    end
    if inputBoundedCycles <= 0 then
        return 0, 'insufficient inputs'
    end

    -- Output-capacity-bound: how many cycles fit in the remaining output capacity.
    local cycles = inputBoundedCycles
    if params.outputWeightPerCycle and params.outputCapacityRemaining then
        local outputBoundedCycles = math.floor(params.outputCapacityRemaining / params.outputWeightPerCycle)
        if outputBoundedCycles < cycles then
            cycles = outputBoundedCycles
        end
    end
    if cycles <= 0 then
        return 0, 'output cap reached'
    end

    -- Bill-target-bound: don't overshoot the bill target.
    local bill = params.bill
    if bill then
        if bill.mode == BillMode.PRODUCE_X then
            local remaining = bill.target_quantity - (bill.produced_quantity or 0)
            local batchOutput = params.batchOutputAmount or 1
            local billBoundedCycles = math.floor(remaining / batchOutput)
            if billBoundedCycles < cycles then
                cycles = billBoundedCycles
            end
        elseif bill.mode == BillMode.MAINTAIN_X then
            -- MAINTAIN_X: may exceed target by at most one batch.
            local target = bill.target_quantity
            local stockPlusReserved = params.stockPlusReserved or 0
            local batchOutput = params.batchOutputAmount or 1
            local remainingToTarget = target - stockPlusReserved
            if remainingToTarget <= 0 then
                return 0, 'maintain target already met'
            end
            -- Allow up to ceil(remainingToTarget / batchOutput) cycles, which
            -- permits overshoot by at most one batch.
            local billBoundedCycles = math.ceil(remainingToTarget / batchOutput)
            if billBoundedCycles < cycles then
                cycles = billBoundedCycles
            end
        elseif bill.mode == BillMode.UNTIL_X then
            -- UNTIL_X: never overshoot the threshold. Use floor so production
            -- stays at or below until_threshold. The threshold is a multiple
            -- of the batch size (validated at creation), so starting from an
            -- aligned stock level lands exactly on the threshold.
            local threshold = bill.until_threshold
            if not threshold then
                return 0, 'until_x threshold missing'
            end
            local stockPlusReserved = params.stockPlusReserved or 0
            local batchOutput = params.batchOutputAmount or 1
            local remainingToThreshold = threshold - stockPlusReserved
            if remainingToThreshold <= 0 then
                return 0, 'until_x threshold already met'
            end
            local billBoundedCycles = math.floor(remainingToThreshold / batchOutput)
            if billBoundedCycles < cycles then
                cycles = billBoundedCycles
            end
        end
    end

    if cycles <= 0 then
        return 0, 'bill target reached'
    end

    return cycles, nil
end

-- Selects the next bill to run for a machine from a list of candidate bills.
-- Stable order: enabled first, then by priority (lower sortValue = higher
-- priority), then by created_sequence (ascending). The prioritySortValues
-- map is injected from config/balance.lua; a built-in default keeps the order
-- correct when none is supplied.
-- @param bills table list of bill rows
-- @param stockPlusReservedByItem table { [primary_output] = number } (for MAINTAIN_X / UNTIL_X)
-- @param batchOutputByBill table { [bill_id] = number }
-- @param prioritySortValues table|nil { [priority_name] = number }
-- @return table|nil selectedBill
local function selectNextBill(bills, stockPlusReservedByItem, batchOutputByBill, prioritySortValues)
    if type(bills) ~= 'table' then return nil end

    local candidates = {}
    for _, bill in ipairs(bills) do
        if bill.enabled and bill.status ~= BillStatus.PAUSED and bill.status ~= BillStatus.REMOVED then
            local batchOutput = batchOutputByBill and batchOutputByBill[bill.bill_id] or 1
            local stockPlusReserved = stockPlusReservedByItem and stockPlusReservedByItem[bill.primary_output] or 0
            if shouldStartCycle(bill, stockPlusReserved, batchOutput) then
                candidates[#candidates + 1] = bill
            end
        end
    end

    if #candidates == 0 then
        return nil
    end

    -- Sort by priority sort value (ascending), then created_sequence ascending.
    table.sort(candidates, function(a, b)
        local sa = prioritySortValue(a.priority, prioritySortValues)
        local sb = prioritySortValue(b.priority, prioritySortValues)
        if sa ~= sb then
            return sa < sb
        end
        return (a.created_sequence or 0) < (b.created_sequence or 0)
    end)

    return candidates[1]
end

-- Computes the new produced_quantity after completing a cycle for a bill.
-- @param bill table { mode, produced_quantity }
-- @param batchOutputAmount number
-- @return number newProducedQuantity
local function applyCycleCompletion(bill, batchOutputAmount)
    return (bill.produced_quantity or 0) + batchOutputAmount
end

CZCraft.Bills = {
    Mode = BillMode,
    Status = BillStatus,
    Priority = BillPriority,
    validateBillCreation = validateBillCreation,
    isProduceXComplete = isProduceXComplete,
    isMaintainXSatisfied = isMaintainXSatisfied,
    isUntilXSatisfied = isUntilXSatisfied,
    shouldStartCycle = shouldStartCycle,
    computeCyclesForChunk = computeCyclesForChunk,
    selectNextBill = selectNextBill,
    applyCycleCompletion = applyCycleCompletion,
}

return CZCraft.Bills
