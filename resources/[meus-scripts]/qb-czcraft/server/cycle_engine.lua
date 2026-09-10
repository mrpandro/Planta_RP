-- qb-czcraft cycle engine
-- The per-machine orchestrator that the scheduler tick fires via
-- 'qb-czcraft:internal:processMachine'. Connects the pure domain (bills,
-- production, catch-up) to the repositories (cycles, stock, machines, bills).
--
-- Two execution modes:
--   1. Real-time: the machine has an active cycle whose due_at <= now.
--      Complete it (CyclesRepo.complete), increment the bill, then start the
--      next cycle (CyclesRepo.start) or go idle/blocked.
--   2. Catch-up: the machine is STOPPED with next_due_at in the past (downtime
--      recovery). Run the analytic multi-cycle catch-up in chunked batches
--      (CyclesRepo.applyCatchUpChunk — one transaction per chunk), yielding
--      between chunks, until caught up or blocked. Then start a real-time
--      cycle or go idle/blocked.
--
-- The handler spawns a thread per machine so the scheduler tick loop never
-- blocks on per-machine MySQL work (meets the "no Lua stall > 50ms" SLO).
-- Each machine operates on its own rows; per-machine transactions are isolated.

CZCraft = CZCraft or {}

local CycleEngine = {}

-- Chunk size for catch-up: bounds the work per transaction. Matches the
-- scheduler's MAX_MACHINES_PER_TICK and the catch-up domain test default.
local MAX_CYCLES_PER_CHUNK = 100

-- Maximum catch-up chunks before yielding back to the scheduler (safety bound
-- so a single processMachine call cannot run unbounded work).
local MAX_CATCHUP_CHUNKS = 1000

-- ===========================================================================
-- Helpers
-- ===========================================================================

-- Generates a UUID v4 string (same pattern as the machines/bills repos).
local function generateUuid()
    return string.gsub('xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx', '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

-- Finds a recipe config by ID from the loaded config.
-- @param recipeId string
-- @return table|nil recipe
local function findRecipe(recipeId)
    for _, recipe in ipairs(CZCraft.Config.Recipes) do
        if recipe.id == recipeId then
            return recipe
        end
    end
    return nil
end

-- Finds the machine config entry by machine type.
-- @param machineType string
-- @return table|nil config
local function findMachineConfig(machineType)
    for _, machine in ipairs(CZCraft.Config.Machines) do
        if machine.type == machineType then
            return machine
        end
    end
    return nil
end

-- Reads upgrade levels from a machine row and returns the effective values
-- after applying upgrade bonuses. Returns nil for each effect when the
-- upgrades feature is off or the machine row lacks upgrade columns.
-- @param machine table machine row (may have upgrade_*_level columns)
-- @param baseCapacity number (from machine config)
-- @param baseDuration number (from recipe)
-- @param basePowerPerCycle number (from config)
-- @param baseWearPerCycle number (from config)
-- @return table { capacity, duration, powerPerCycle, wearPerCycle }
local function applyUpgradeEffects(machine, baseCapacity, baseDuration, basePowerPerCycle, baseWearPerCycle)
    local upgradesEnabled = CZCraft.Config and CZCraft.Config.General
        and CZCraft.Config.General.features and CZCraft.Config.General.features.upgrades
    if not upgradesEnabled or not machine then
        return {
            capacity = baseCapacity,
            duration = baseDuration,
            powerPerCycle = basePowerPerCycle,
            wearPerCycle = baseWearPerCycle,
        }
    end

    local speedLevel = tonumber(machine.upgrade_speed_level) or 0
    local capacityLevel = tonumber(machine.upgrade_capacity_level) or 0
    local efficiencyLevel = tonumber(machine.upgrade_efficiency_level) or 0
    local durabilityLevel = tonumber(machine.upgrade_durability_level) or 0

    return {
        capacity = CZCraft.Upgrades.effectiveCapacity(baseCapacity, capacityLevel),
        duration = CZCraft.Upgrades.effectiveDuration(baseDuration, speedLevel),
        powerPerCycle = CZCraft.Upgrades.effectivePowerConsumption(basePowerPerCycle, efficiencyLevel),
        wearPerCycle = CZCraft.Upgrades.effectiveWear(baseWearPerCycle, durabilityLevel),
    }
end

-- Builds an item-weight map { [item_name] = weight_in_grams } for the items
-- referenced by a recipe, from the QBCore shared item registry.
-- @param recipe table
-- @return table itemWeights
local function buildItemWeights(recipe)
    local items = CZCraft.QBCoreAdapter.getItems()
    local weights = {}
    local function add(itemName)
        if itemName and items and items[itemName] and type(items[itemName].weight) == 'number' then
            weights[itemName] = items[itemName].weight
        end
    end
    if type(recipe.inputs) == 'table' then
        for _, line in ipairs(recipe.inputs) do add(line.item) end
    end
    if type(recipe.outputs) == 'table' then
        for _, line in ipairs(recipe.outputs) do add(line.item) end
    end
    return weights
end

-- Returns the batch output amount for a recipe's primaryOutput.
-- @param recipe table
-- @return number batchOutput (>= 1)
local function batchOutputAmount(recipe)
    for _, out in ipairs(recipe.outputs or {}) do
        if out.item == recipe.primaryOutput then
            return out.amount or 1
        end
    end
    return 1
end

-- Parses a UTC datetime string ("YYYY-MM-DD HH:MM:SS" or with fractional
-- seconds) to a unix timestamp. Uses a timezone-independent civil-calendar
-- algorithm (Howard Hinnant's days_from_civil) so the result is correct
-- regardless of the server's local timezone — the DB stores UTC.
--
-- oxmysql returns DATETIME(3) columns as millisecond timestamps (ms since
-- epoch), not strings. A numeric value >= 1e11 is treated as ms and divided
-- by 1000 to normalize to seconds (a seconds timestamp for years 2001..2286
-- is 10 digits, < 1e11).
-- @param iso string|number
-- @return number|nil unix seconds
local function parseIsoToUnix(iso)
    if not iso then return nil end
    if type(iso) == 'number' then
        if iso >= 1e11 then
            return math.floor(iso / 1000)
        end
        return iso
    end
    local y, mo, d, h, mi, s = tostring(iso):match('^(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):(%d+)')
    if not y then return nil end
    local year, month, day = tonumber(y), tonumber(mo), tonumber(d)
    -- days_from_civil: days since 1970-01-01 (UTC).
    y = year - (month <= 2 and 1 or 0)
    local era = math.floor(y / 400)
    if y < 0 and (y % 400 ~= 0) then era = era - 1 end
    local yoe = y - era * 400
    local mp = month > 2 and month - 3 or month + 9
    local doy = math.floor((153 * mp + 2) / 5) + day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

-- Sums quantity + reserved_quantity for an item across stock rows (for
-- MAINTAIN_X bill selection).
-- @param stockRows table
-- @param itemName string
-- @return number stockPlusReserved
local function stockPlusReservedForItem(stockRows, itemName)
    local total = 0
    for _, row in ipairs(stockRows or {}) do
        if row.item_name == itemName then
            total = total + (tonumber(row.quantity) or 0) + (tonumber(row.reserved_quantity) or 0)
        end
    end
    return total
end

-- Builds the priority sort-value map from config/balance.lua for bill
-- selection. Returns { [priority_name] = sortValue }. Cached after first call.
-- @return table
local prioritySortValuesCache
local function buildPrioritySortValues()
    if prioritySortValuesCache then return prioritySortValuesCache end
    prioritySortValuesCache = {}
    local cfg = CZCraft.Config and CZCraft.Config.Balance and CZCraft.Config.Balance.priority
    if type(cfg) == 'table' then
        for name, entry in pairs(cfg) do
            if type(entry) == 'table' and type(entry.sortValue) == 'number' then
                prioritySortValuesCache[name] = entry.sortValue
            end
        end
    end
    return prioritySortValuesCache
end

-- ===========================================================================
-- Start next real-time cycle (shared by both modes)
-- ===========================================================================

-- Selects the next runnable bill, validates a cycle start, and starts a
-- real-time cycle. Returns the outcome so the caller can decide re-heap/idle.
-- @param machineUuid string
-- @param machineVersion number
-- @param machineType string
-- @param now number unix seconds
-- @param machine table|nil loaded machine row (for power_level/condition; nil skips gates)
-- @return string outcome ('started'|'idle'|'blocked')
-- @return string|nil reason
local function startNextCycle(machineUuid, machineVersion, machineType, now, machine)
    local bills = CZCraft.BillsRepo.listActiveForMachine(machineUuid)
    local stockRows = CZCraft.StockRepo.loadAll(machineUuid)
    local machineConfig = findMachineConfig(machineType)
    local baseCapacity = machineConfig and machineConfig.stockCapacity or 0

    -- Compute upgrade-adjusted base values. When upgrades are off or the
    -- machine row lacks upgrade columns, these fall back to the base values.
    local basePowerPerCycle = CZCraft.Power.computePowerConsumption()
    local baseWearPerCycle = CZCraft.Condition.computeWear()
    local upgradeEffects = applyUpgradeEffects(machine, baseCapacity, nil, basePowerPerCycle, baseWearPerCycle)
    local capacity = upgradeEffects.capacity

    -- v0.2 power gate: block new cycles when power is below the threshold.
    -- Skipped when the power feature is off, or when the machine row lacks
    -- power_level (schema v1 / test mocks that don't set it).
    local powerFeatureEnabled = CZCraft.Config and CZCraft.Config.General
        and CZCraft.Config.General.features and CZCraft.Config.General.features.power
    local powerLevel = machine and tonumber(machine.power_level)
    local powerSnapshot
    if powerFeatureEnabled and powerLevel ~= nil then
        if CZCraft.Power.isBlocked(powerLevel) then
            CZCraft.MachinesRepo.setBlocked(machineUuid, 'power low', nil, machineVersion)
            return 'blocked', 'power low'
        end
        local powerToConsume = upgradeEffects.powerPerCycle
        powerSnapshot = CZCraft.Power.computeCycleSnapshot(powerLevel, powerToConsume)
    end

    -- v0.2 condition gate: block new cycles when condition is at or below the
    -- block threshold. Skipped when the condition feature is off, or when the
    -- machine row lacks condition (schema v1 / test mocks that don't set it).
    -- An active cycle always finishes; the block only prevents NEW starts.
    local conditionFeatureEnabled = CZCraft.Config and CZCraft.Config.General
        and CZCraft.Config.General.features and CZCraft.Config.General.features.condition
    local conditionLevel = machine and tonumber(machine.condition)
    local conditionSnapshot
    if conditionFeatureEnabled and conditionLevel ~= nil then
        if CZCraft.Condition.isBlocked(conditionLevel) then
            CZCraft.MachinesRepo.setBlocked(machineUuid, 'condition low', nil, machineVersion)
            return 'blocked', 'condition low'
        end
        local wearToApply = upgradeEffects.wearPerCycle
        conditionSnapshot = CZCraft.Condition.computeCycleSnapshot(conditionLevel, wearToApply)
    end

    -- Build stockPlusReservedByItem and batchOutputByBill for bill selection.
    local stockPlusReservedByItem = {}
    for _, bill in ipairs(bills) do
        stockPlusReservedByItem[bill.primary_output] = stockPlusReservedForItem(stockRows, bill.primary_output)
    end
    local batchOutputByBill = {}
    for _, bill in ipairs(bills) do
        local recipe = findRecipe(bill.recipe_id)
        batchOutputByBill[bill.bill_id] = recipe and batchOutputAmount(recipe) or 1
    end

    local bill = CZCraft.Bills.selectNextBill(bills, stockPlusReservedByItem, batchOutputByBill, buildPrioritySortValues())
    if not bill then
        -- No runnable bill: machine is idle. Clear next_due_at so the scheduler
        -- stops popping it; a wake event (stock deposit, bill create) re-heaps.
        CZCraft.MachinesRepo.clearNextDue(machineUuid, machineVersion)
        return 'idle', nil
    end

    local recipe = findRecipe(bill.recipe_id)
    if not recipe then
        CZCraft.MachinesRepo.setBlocked(machineUuid, 'recipe not found: ' .. tostring(bill.recipe_id), nil, machineVersion)
        return 'blocked', 'recipe not found'
    end
    if recipe.enabled == false then
        CZCraft.MachinesRepo.setBlocked(machineUuid, 'recipe disabled', recipe.id, machineVersion)
        return 'blocked', 'recipe disabled'
    end

    local itemWeights = buildItemWeights(recipe)
    local usedWeight = CZCraft.Storage.computeUsedWeight(stockRows, itemWeights)
    local reservedWeight = CZCraft.Storage.sumReserved(stockRows)

    local ok, reason, computed = CZCraft.Production.validateCycleStart({
        recipe = recipe,
        stockRows = stockRows,
        machineUsedWeight = usedWeight,
        machineReservedWeight = reservedWeight,
        machineCapacity = capacity,
        itemWeights = itemWeights,
    })
    if not ok then
        -- Distinguish a genuine block (inputs/cap) from a transient state.
        -- Both stop the machine; a wake event re-heaps when stock changes.
        CZCraft.MachinesRepo.setBlocked(machineUuid, reason, nil, machineVersion)
        return 'blocked', reason
    end

    local startDeltas = CZCraft.Production.computeStartDeltas(computed)
    local canonical = CZCraft.RecipeSnapshot.canonicalRecipe(recipe)
    local snapshot = CZCraft.RecipeSnapshot.recipeSnapshot(recipe)
    local cycleId = generateUuid()
    local cycleSequence = CZCraft.CyclesRepo.nextSequence()
    local reservedOutputWeight = computed.reservedWeightDelta or 0
    local standardCost = CZCraft.RecipeSnapshot.standardCost(recipe, {}) or 0

    local startOk, startErr = CZCraft.CyclesRepo.start({
        cycle_id = cycleId,
        cycle_sequence = cycleSequence,
        machine_uuid = machineUuid,
        bill_id = bill.bill_id,
        recipe_id = recipe.id,
        recipe_canonical = canonical,
        recipe_snapshot = snapshot,
        started_at = now,
        duration_seconds = upgradeEffects.duration or recipe.duration,
        reserved_output_weight = reservedOutputWeight,
        standard_cost = standardCost,
        stock_deltas = startDeltas.stockDeltas,
        power_level_before = powerSnapshot and powerSnapshot.before or nil,
        power_level_after = powerSnapshot and powerSnapshot.after or nil,
        power_to_consume = powerSnapshot and powerSnapshot.powerToConsume or nil,
        condition_before = conditionSnapshot and conditionSnapshot.before or nil,
        condition_after = conditionSnapshot and conditionSnapshot.after or nil,
        wear_to_apply = conditionSnapshot and conditionSnapshot.wearToApply or nil,
    })
    if not startOk then
        CZCraft.MachinesRepo.setBlocked(machineUuid, 'cycle start failed: ' .. tostring(startErr), nil, machineVersion)
        return 'blocked', tostring(startErr)
    end

    -- Re-heap with the new due time (CyclesRepo.start already set next_due_at,
    -- but the in-memory heap needs the wake).
    local effectiveDuration = upgradeEffects.duration or recipe.duration
    CZCraft.SchedulerTick.wake(machineUuid, now + effectiveDuration)
    return 'started', nil
end

-- ===========================================================================
-- Mode 1: complete a due active cycle
-- ===========================================================================

-- Completes the machine's active cycle if it is due, increments the bill, and
-- starts the next cycle or goes idle/blocked.
-- @param machineUuid string
-- @param machineVersion number
-- @param machineType string
-- @param now number unix seconds
local function completeActiveCycle(machineUuid, machineVersion, machineType, now)
    local cycle = CZCraft.CyclesRepo.loadActive(machineUuid)
    if not cycle then return end

    local dueAt = parseIsoToUnix(cycle.due_at)
    if not dueAt then
        -- Unparseable due_at: treat as not due to avoid premature completion.
        return
    end
    if dueAt > now then
        -- Not yet due: re-heap with the real due time (premature wake).
        CZCraft.SchedulerTick.wake(machineUuid, dueAt)
        return
    end

    local recipe = findRecipe(cycle.recipe_id)
    if not recipe then
        -- Recipe disappeared: complete the cycle without producing (cancel).
        CZCraft.CyclesRepo.deleteActive(machineUuid, cycle.cycle_id)
        CZCraft.MachinesRepo.setBlocked(machineUuid, 'recipe not found: ' .. tostring(cycle.recipe_id), nil, machineVersion)
        return
    end

    -- Completion deltas: reserved output -> actual stock.
    local computed = { outputsToReserve = {} }
    for _, line in ipairs(recipe.outputs) do
        computed.outputsToReserve[#computed.outputsToReserve + 1] = {
            item_name = line.item,
            amount = line.amount,
        }
    end
    local completionDeltas = CZCraft.Production.computeCompletionDeltas(computed)

    local startedAt = parseIsoToUnix(cycle.started_at) or now
    local idempotencyKey = machineUuid .. ':' .. cycle.cycle_id .. ':complete'

    local ok, err, replayed = CZCraft.CyclesRepo.complete({
        cycle_id = cycle.cycle_id,
        machine_uuid = machineUuid,
        bill_id = cycle.bill_id,
        completion_deltas = completionDeltas.stockDeltas,
        idempotency_key = idempotencyKey,
        cycles_completed = 1,
        inputs_json = json.encode(recipe.inputs or {}),
        outputs_json = json.encode(recipe.outputs or {}),
        cost = tonumber(cycle.standard_cost) or 0,
        started_at = startedAt,
        ended_at = now,
    })
    if not ok then
        -- Completion failed (tx error). Re-heap so the next tick retries.
        CZCraft.SchedulerTick.wake(machineUuid, now)
        return
    end

    -- Replay: the prior completion already incremented the bill and started
    -- the next cycle. Skip both to avoid double-increment / duplicate cycle.
    if replayed then
        return
    end

    -- Increment the bill's produced_quantity (if the cycle had a bill).
    if cycle.bill_id then
        local bill = CZCraft.BillsRepo.load(cycle.bill_id)
        if bill then
            local batch = batchOutputAmount(recipe)
            CZCraft.BillsRepo.incrementProduced(
                cycle.bill_id,
                tonumber(bill.version) or 0,
                batch,
                bill.mode,
                tonumber(bill.target_quantity) or 0
            )
        end
    end

    -- Reload the machine to get the fresh version (complete() bumped it) and
    -- the updated power_level (complete() applied power_level_after).
    local machine = CZCraft.MachinesRepo.load(machineUuid)
    local freshVersion = machine and tonumber(machine.version) or machineVersion + 1

    -- Start the next cycle or go idle/blocked.
    startNextCycle(machineUuid, freshVersion, machineType, now, machine)
end

-- ===========================================================================
-- Mode 2: chunked catch-up
-- ===========================================================================

-- Runs the analytic catch-up for a STOPPED machine whose next_due_at is in the
-- past. Applies chunks via CyclesRepo.applyCatchUpChunk (one tx per chunk),
-- yielding between chunks. On completion, starts a real-time cycle or goes
-- idle/blocked.
-- @param machineUuid string
-- @param machineVersion number
-- @param machineType string
-- @param lastCompletedAt number unix seconds (the machine's next_due_at)
-- @param now number unix seconds
local function runCatchUp(machineUuid, machineVersion, machineType, lastCompletedAt, now)
    local cursor = lastCompletedAt
    local chunkSequence = 0

    for _ = 1, MAX_CATCHUP_CHUNKS do
        local machine = CZCraft.MachinesRepo.load(machineUuid)
        if not machine then return end
        local machineVersionFresh = tonumber(machine.version) or machineVersion

        local bills = CZCraft.BillsRepo.listActiveForMachine(machineUuid)
        local stockRows = CZCraft.StockRepo.loadAll(machineUuid)
        local machineConfig = findMachineConfig(machineType)
        local baseCapacity = machineConfig and machineConfig.stockCapacity or 0

        local stockPlusReservedByItem = {}
        for _, bill in ipairs(bills) do
            stockPlusReservedByItem[bill.primary_output] = stockPlusReservedForItem(stockRows, bill.primary_output)
        end
        local batchOutputByBill = {}
        for _, bill in ipairs(bills) do
            local recipe = findRecipe(bill.recipe_id)
            batchOutputByBill[bill.bill_id] = recipe and batchOutputAmount(recipe) or 1
        end

        local bill = CZCraft.Bills.selectNextBill(bills, stockPlusReservedByItem, batchOutputByBill, buildPrioritySortValues())
        if not bill then
            CZCraft.MachinesRepo.clearNextDue(machineUuid, machineVersionFresh)
            return
        end

        local recipe = findRecipe(bill.recipe_id)
        if not recipe then
            CZCraft.MachinesRepo.setBlocked(machineUuid, 'recipe not found: ' .. tostring(bill.recipe_id), nil, machineVersionFresh)
            return
        end
        if recipe.enabled == false then
            CZCraft.MachinesRepo.setBlocked(machineUuid, 'recipe disabled', recipe.id, machineVersionFresh)
            return
        end

        -- Compute upgrade-adjusted values for this machine.
        local basePowerPerCycle = CZCraft.Power.computePowerConsumption()
        local baseWearPerCycle = CZCraft.Condition.computeWear()
        local upgradeEffects = applyUpgradeEffects(
            machine, baseCapacity, recipe.duration, basePowerPerCycle, baseWearPerCycle
        )
        local capacity = upgradeEffects.capacity

        -- v0.2 power gate for catch-up: if the machine is power-blocked, no
        -- catch-up cycles run. The machine stays stopped with a block reason.
        local powerFeatureEnabled = CZCraft.Config and CZCraft.Config.General
            and CZCraft.Config.General.features and CZCraft.Config.General.features.power
        local powerLevel = tonumber(machine.power_level)
        local powerPerCycle = 0
        if powerFeatureEnabled and powerLevel ~= nil then
            if CZCraft.Power.isBlocked(powerLevel) then
                CZCraft.MachinesRepo.setBlocked(machineUuid, 'power low', nil, machineVersionFresh)
                return
            end
            powerPerCycle = upgradeEffects.powerPerCycle
        end

        -- v0.2 condition gate for catch-up: if the machine is condition-blocked,
        -- no catch-up cycles run. Skipped when the condition feature is off or
        -- the machine row lacks condition (schema v1 / test mocks).
        local conditionFeatureEnabled = CZCraft.Config and CZCraft.Config.General
            and CZCraft.Config.General.features and CZCraft.Config.General.features.condition
        local conditionLevel = tonumber(machine.condition)
        local wearPerCycle = 0
        if conditionFeatureEnabled and conditionLevel ~= nil then
            if CZCraft.Condition.isBlocked(conditionLevel) then
                CZCraft.MachinesRepo.setBlocked(machineUuid, 'condition low', nil, machineVersionFresh)
                return
            end
            wearPerCycle = upgradeEffects.wearPerCycle
        end

        local itemWeights = buildItemWeights(recipe)
        local usedWeight = CZCraft.Storage.computeUsedWeight(stockRows, itemWeights)
        local reservedWeight = CZCraft.Storage.sumReserved(stockRows)
        local batch = batchOutputAmount(recipe)

        -- Create a recipe copy with the upgrade-adjusted duration so the
        -- catch-up domain computes cycles using the effective cycle time.
        local effectiveRecipe = recipe
        local effectiveDuration = upgradeEffects.duration or recipe.duration
        if effectiveDuration ~= recipe.duration then
            effectiveRecipe = {}
            for k, v in pairs(recipe) do effectiveRecipe[k] = v end
            effectiveRecipe.duration = effectiveDuration
        end

        local result = CZCraft.CatchUp.computeCatchUpChunk({
            lastCompletedAt = cursor,
            now = now,
            recipe = effectiveRecipe,
            bill = {
                mode = bill.mode,
                target_quantity = tonumber(bill.target_quantity) or 0,
                produced_quantity = tonumber(bill.produced_quantity) or 0,
                until_threshold = tonumber(bill.until_threshold) or nil,
            },
            stockRows = stockRows,
            machineUsedWeight = usedWeight,
            machineReservedWeight = reservedWeight,
            machineCapacity = capacity,
            itemWeights = itemWeights,
            batchOutputAmount = batch,
            maxCyclesPerChunk = MAX_CYCLES_PER_CHUNK,
            stockPlusReservedByItem = stockPlusReservedByItem,
        })

        -- Bound the chunk by available power: can't consume more than the
        -- machine has. This prevents catch-up from driving power negative.
        if powerPerCycle > 0 and result.cyclesToRun > 0 then
            local maxCyclesByPower = math.floor(powerLevel / powerPerCycle)
            if maxCyclesByPower < result.cyclesToRun then
                result.cyclesToRun = maxCyclesByPower
                -- Recompute chunk elapsed for the reduced cycle count.
                result.nextChunkElapsed = result.cyclesToRun * effectiveDuration
                result.shouldContinue = false
                if result.cyclesToRun <= 0 then
                    -- Not enough power for even one cycle: block.
                    CZCraft.MachinesRepo.setBlocked(machineUuid, 'power low', nil, machineVersionFresh)
                    return
                end
            end
        end

        -- Bound the chunk by available condition: can't wear the machine
        -- below the block threshold. This prevents catch-up from driving
        -- condition to 0 and leaving the machine stuck.
        if wearPerCycle > 0 and result.cyclesToRun > 0 then
            local cfg = CZCraft.Config.Balance.condition
            local blockThreshold = cfg and cfg.blockThreshold or 20
            -- Cycles until condition hits the block threshold.
            local maxCyclesByCondition = math.floor(
                (conditionLevel - blockThreshold) / wearPerCycle
            )
            if maxCyclesByCondition < result.cyclesToRun then
                result.cyclesToRun = math.max(0, maxCyclesByCondition)
                result.nextChunkElapsed = result.cyclesToRun * effectiveDuration
                result.shouldContinue = false
                if result.cyclesToRun <= 0 then
                    -- Not enough condition for even one cycle: block.
                    CZCraft.MachinesRepo.setBlocked(machineUuid, 'condition low', nil, machineVersionFresh)
                    return
                end
            end
        end

        if result.cyclesToRun <= 0 then
            if result.blockReason then
                local m = CZCraft.MachinesRepo.load(machineUuid)
                CZCraft.MachinesRepo.setBlocked(machineUuid, result.blockReason, nil, m and tonumber(m.version) or machineVersionFresh)
                return
            end
            -- Zero cycles, no block: caught up to the sub-duration boundary.
            -- Fall through to start a real-time cycle for the remaining time.
            break
        end

        chunkSequence = chunkSequence + 1
        local chunkStart = cursor
        local chunkEnd = cursor + result.nextChunkElapsed
        local nextDue = chunkEnd
        local idempotencyKey = machineUuid .. ':catchup:' .. tostring(chunkSequence)

        local ok, err, replayed = CZCraft.CyclesRepo.applyCatchUpChunk({
            machine_uuid = machineUuid,
            bill_id = bill.bill_id,
            recipe = recipe,
            cycles_to_run = result.cyclesToRun,
            chunk_sequence = chunkSequence,
            chunk_started_at = chunkStart,
            chunk_ended_at = chunkEnd,
            next_due_at = nextDue,
            standard_cost = CZCraft.RecipeSnapshot.standardCost(recipe, {}) or 0,
            idempotency_key = idempotencyKey,
            event_id = generateUuid(),
            power_to_consume = powerPerCycle * result.cyclesToRun,
            wear_to_apply = wearPerCycle * result.cyclesToRun,
        })
        if not ok then
            -- Chunk failed: re-heap so the next tick retries from the cursor.
            CZCraft.SchedulerTick.wake(machineUuid, now)
            return
        end

        -- Replay: the prior chunk already incremented the bill and advanced
        -- the cursor. Skip the bill increment but still advance the local
        -- cursor so the loop continues from the right point.
        if not replayed then
            -- Increment the bill's produced_quantity by batch * cycles.
            local freshBill = CZCraft.BillsRepo.load(bill.bill_id)
            if freshBill then
                CZCraft.BillsRepo.incrementProduced(
                    bill.bill_id,
                    tonumber(freshBill.version) or 0,
                    batch * result.cyclesToRun,
                    freshBill.mode,
                    tonumber(freshBill.target_quantity) or 0
                )
            end
        end

        cursor = nextDue

        if not result.shouldContinue then
            break
        end

        -- Yield between chunks so the scheduler thread is not monopolized.
        Wait(0)
    end

    -- Catch-up complete: start a real-time cycle for the remaining time, or
    -- go idle/blocked if no bill is runnable.
    local machine = CZCraft.MachinesRepo.load(machineUuid)
    if not machine then return end
    startNextCycle(machineUuid, tonumber(machine.version) or machineVersion, machineType, now, machine)
end

-- ===========================================================================
-- Entry point
-- ===========================================================================

-- Processes a single due machine. Spawned in its own thread so the scheduler
-- tick loop never blocks on per-machine MySQL work.
-- @param machineUuid string
local function processMachine(machineUuid)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then return end
    if not CZCraft.Config.General.features.scheduler then return end
    if not CZCraft.Config.General.features.production then return end

    local machine = CZCraft.MachinesRepo.load(machineUuid)
    if not machine then return end
    -- Only INSTALLED machines are processed.
    if machine.lifecycle ~= 'INSTALLED' then return end

    local machineUuid_ = machine.machine_uuid
    local machineVersion = tonumber(machine.version) or 0
    local machineType = machine.machine_type
    local now = os.time()

    local activeCycle = CZCraft.CyclesRepo.loadActive(machineUuid_)
    if activeCycle then
        -- Mode 1: real-time cycle completion.
        completeActiveCycle(machineUuid_, machineVersion, machineType, now)
        return
    end

    -- Mode 2: catch-up (only if next_due_at is in the past).
    local nextDueAt = parseIsoToUnix(machine.next_due_at)
    if not nextDueAt then
        -- No next_due_at: machine is idle, nothing to do.
        return
    end
    if nextDueAt > now then
        -- Not yet due: re-heap with the real due time (premature wake).
        CZCraft.SchedulerTick.wake(machineUuid_, nextDueAt)
        return
    end

    runCatchUp(machineUuid_, machineVersion, machineType, nextDueAt, now)
end

RegisterNetEvent('qb-czcraft:internal:processMachine')
AddEventHandler('qb-czcraft:internal:processMachine', function(machineUuid)
    if type(machineUuid) ~= 'string' then return end
    -- Spawn a thread so the scheduler tick loop (which fires this event in a
    -- tight loop over due machines) never blocks on MySQL awaits or chunk
    -- yields. Each machine processes independently on its own rows.
    CreateThread(function()
        processMachine(machineUuid)
    end)
end)

CycleEngine.processMachine = processMachine
CZCraft.CycleEngine = CycleEngine
return CycleEngine
