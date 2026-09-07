-- qb-czcraft catch-up domain (pure)
-- Analytic multi-cycle catch-up computation for offline/downtime recovery.
-- No time limit; chunked to bound lock duration; continues until now or a
-- genuine block (missing input, disabled recipe, output cap).
--
-- The catch-up uses the SAME formula as real-time production — no separate
-- offline-only formula that could drift from the live one.

CZCraft = CZCraft or {}

-- Computes the catch-up plan for a single machine: how many cycles to run
-- in the current chunk, and whether to continue or stop.
-- @param params table {
--   lastCompletedAt number, now number,
--   recipe = { id, duration, inputs, outputs, enabled },
--   bill = { mode, target_quantity, produced_quantity } | nil,
--   stockRows = { { item_name, quantity, reserved_quantity } },
--   machineUsedWeight, machineReservedWeight, machineCapacity,
--   itemWeights = { [item_name] = weight },
--   batchOutputAmount number,
--   maxCyclesPerChunk number,
--   stockPlusReservedByItem = { [item_name] = number } (for MAINTAIN_X bill selection),
-- }
-- @return table {
--   cyclesToRun number,
--   blockReason string|nil,
--   shouldContinue boolean,
--   nextChunkElapsed number (elapsed time consumed by this chunk),
-- }
local function computeCatchUpChunk(params)
    if type(params) ~= 'table' then
        return { cyclesToRun = 0, blockReason = 'params must be a table', shouldContinue = false, nextChunkElapsed = 0 }
    end

    local recipe = params.recipe
    if type(recipe) ~= 'table' then
        return { cyclesToRun = 0, blockReason = 'no recipe', shouldContinue = false, nextChunkElapsed = 0 }
    end

    -- A disabled recipe blocks catch-up: the current in-flight cycle (if any)
    -- completes, but no new cycles start.
    if recipe.enabled == false then
        return { cyclesToRun = 0, blockReason = 'recipe disabled', shouldContinue = false, nextChunkElapsed = 0 }
    end

    local lastCompletedAt = params.lastCompletedAt or 0
    local now = params.now or 0
    local elapsed = now - lastCompletedAt

    -- Zero or negative elapsed: no catch-up needed.
    if elapsed <= 0 then
        return { cyclesToRun = 0, blockReason = nil, shouldContinue = false, nextChunkElapsed = 0 }
    end

    -- Build input availability from stock rows.
    local inputAvailability = {}
    if type(params.stockRows) == 'table' then
        for _, row in ipairs(params.stockRows) do
            if row and row.item_name then
                inputAvailability[row.item_name] = (row.quantity or 0) - (row.reserved_quantity or 0)
            end
        end
    end

    -- Compute output capacity remaining.
    local usedWeight = params.machineUsedWeight or 0
    local currentReserved = params.machineReservedWeight or 0
    local capacity = params.machineCapacity or 0
    local outputCapacityRemaining = capacity - usedWeight - currentReserved

    -- Compute output weight per cycle.
    local outputWeightPerCycle = 0
    if type(recipe.outputs) == 'table' and type(params.itemWeights) == 'table' then
        for _, line in ipairs(recipe.outputs) do
            local weight = params.itemWeights[line.item] or 0
            outputWeightPerCycle = outputWeightPerCycle + (weight * line.amount)
        end
    end

    -- Use the bills domain to compute cycles for this chunk.
    local cycles, blockReason = CZCraft.Bills.computeCyclesForChunk({
        recipeDurationSeconds = recipe.duration,
        elapsedSeconds = elapsed,
        maxCyclesPerChunk = params.maxCyclesPerChunk,
        inputAvailability = inputAvailability,
        recipeInputs = recipe.inputs,
        outputCapacityRemaining = outputCapacityRemaining,
        outputWeightPerCycle = outputWeightPerCycle,
        bill = params.bill,
        batchOutputAmount = params.batchOutputAmount,
        stockPlusReserved = params.stockPlusReservedByItem and params.stockPlusReservedByItem[recipe.primaryOutput] or 0,
    })

    if cycles <= 0 then
        -- If there's a block reason, stop. If cycles is 0 with no reason
        -- (e.g. zero elapsed after rounding), we may still need to continue
        -- if elapsed was positive but less than one duration.
        if blockReason then
            return { cyclesToRun = 0, blockReason = blockReason, shouldContinue = false, nextChunkElapsed = 0 }
        end
        -- Elapsed was positive but less than one cycle duration: no cycles
        -- this chunk, but there's still time remaining — stop (the next
        -- scheduler tick will handle it).
        return { cyclesToRun = 0, blockReason = nil, shouldContinue = false, nextChunkElapsed = elapsed }
    end

    -- Time consumed by this chunk.
    local chunkElapsed = cycles * recipe.duration
    local remainingElapsed = elapsed - chunkElapsed

    -- Should continue if there's still time remaining and no block.
    local shouldContinue = remainingElapsed >= recipe.duration

    return {
        cyclesToRun = cycles,
        blockReason = nil,
        shouldContinue = shouldContinue,
        nextChunkElapsed = chunkElapsed,
    }
end

-- Computes the total catch-up plan across multiple chunks for a machine.
-- This is a pure simulation used by tests; the real catch-up runs one chunk
-- per transaction and yields between chunks.
-- @param params table (same as computeCatchUpChunk, plus maxChunks)
-- @return table { totalCycles, chunks = { { cycles, elapsed } }, finalBlockReason }
local function simulateFullCatchUp(params)
    local totalCycles = 0
    local chunks = {}
    local finalBlockReason
    local maxChunks = params.maxChunks or 1000

    -- Mutable state for the simulation.
    local state = {
        lastCompletedAt = params.lastCompletedAt or 0,
        stockRows = params.stockRows and {} or nil,
        machineUsedWeight = params.machineUsedWeight,
        machineReservedWeight = params.machineReservedWeight,
        bill = params.bill and {} or nil,
    }

    -- Deep copy mutable state.
    if params.stockRows then
        for _, row in ipairs(params.stockRows) do
            state.stockRows[#state.stockRows + 1] = {
                item_name = row.item_name,
                quantity = row.quantity,
                reserved_quantity = row.reserved_quantity,
            }
        end
    end
    if params.bill then
        for k, v in pairs(params.bill) do
            state.bill[k] = v
        end
    end

    for _ = 1, maxChunks do
        -- Build params for this chunk.
        local chunkParams = {}
        for k, v in pairs(params) do
            chunkParams[k] = v
        end
        chunkParams.lastCompletedAt = state.lastCompletedAt
        chunkParams.stockRows = state.stockRows
        chunkParams.machineUsedWeight = state.machineUsedWeight
        chunkParams.machineReservedWeight = state.machineReservedWeight
        chunkParams.bill = state.bill
        chunkParams.now = params.now

        local result = computeCatchUpChunk(chunkParams)

        if result.cyclesToRun <= 0 then
            finalBlockReason = result.blockReason
            break
        end

        chunks[#chunks + 1] = { cycles = result.cyclesToRun, elapsed = result.nextChunkElapsed }
        totalCycles = totalCycles + result.cyclesToRun

        -- Update state: advance time, consume inputs, add outputs.
        state.lastCompletedAt = state.lastCompletedAt + result.nextChunkElapsed

        -- Consume inputs and add outputs in the stock simulation.
        local recipe = params.recipe
        if state.stockRows and type(recipe.inputs) == 'table' then
            for _, line in ipairs(recipe.inputs) do
                for _, row in ipairs(state.stockRows) do
                    if row.item_name == line.item then
                        row.quantity = row.quantity - (line.amount * result.cyclesToRun)
                        break
                    end
                end
            end
        end
        if state.stockRows and type(recipe.outputs) == 'table' then
            for _, line in ipairs(recipe.outputs) do
                local found = false
                for _, row in ipairs(state.stockRows) do
                    if row.item_name == line.item then
                        row.quantity = row.quantity + (line.amount * result.cyclesToRun)
                        found = true
                        break
                    end
                end
                if not found then
                    state.stockRows[#state.stockRows + 1] = {
                        item_name = line.item,
                        quantity = line.amount * result.cyclesToRun,
                        reserved_quantity = 0,
                    }
                end
            end
        end

        -- Update bill produced_quantity for PRODUCE_X.
        if state.bill and state.bill.mode == CZCraft.Bills.Mode.PRODUCE_X then
            state.bill.produced_quantity = (state.bill.produced_quantity or 0)
                + (params.batchOutputAmount * result.cyclesToRun)
        end

        -- Update MAINTAIN_X stockPlusReserved.
        if state.bill and state.bill.mode == CZCraft.Bills.Mode.MAINTAIN_X then
            -- Recompute stockPlusReserved for the primary output.
            if not params.stockPlusReservedByItem then
                params.stockPlusReservedByItem = {}
            end
            local total = 0
            for _, row in ipairs(state.stockRows) do
                if row.item_name == recipe.primaryOutput then
                    total = total + row.quantity
                end
            end
            params.stockPlusReservedByItem[recipe.primaryOutput] = total
        end

        if not result.shouldContinue then
            break
        end
    end

    return {
        totalCycles = totalCycles,
        chunks = chunks,
        finalBlockReason = finalBlockReason,
    }
end

CZCraft.CatchUp = {
    computeCatchUpChunk = computeCatchUpChunk,
    simulateFullCatchUp = simulateFullCatchUp,
}

return CZCraft.CatchUp
