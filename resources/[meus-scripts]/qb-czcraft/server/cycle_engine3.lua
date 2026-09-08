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
-- @param iso string|number
-- @return number|nil unix seconds
local function parseIsoToUnix(iso)
    if not iso then return nil end
    if type(iso) == 'number' then return iso end
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

-- ===========================================================================
-- Start next real-time cycle (shared by both modes)
-- ===========================================================================

-- Selects the next runnable bill, validates a cycle start, and starts a
-- real-time cycle. Returns the outcome so the caller can decide re-heap/idle.
-- @param machineUuid string
-- @param machineVersion number
-- @param machineType string
-- @param now number unix seconds
-- @return string outcome ('started'|'idle'|'blocked')
-- @return string|nil reason
local function startNextCycle(machineUuid, machineVersion, machineType, now)
    local bills = CZCraft.BillsRepo.listActiveForMachine(machineUuid)
    local stockRows = CZCraft.StockRepo.loadAll(machineUuid)
    local machineConfig = findMachineConfig(machineType)
    local capacity = machineConfig and machineConfig.stockCapacity or 0

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

    local bill = CZCraft.Bills.selectNextBill(bills, stockPlusReservedByItem, batchOutputByBill)
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
        duration_seconds = recipe.duration,
        reserved_output_weight = reservedOutputWeight,
        standard_cost = standardCost,
        stock_deltas = startDeltas.stockDeltas,
    })
    if not startOk then
        CZCraft.MachinesRepo.setBlocked(machineUuid, 'cycle start failed: ' .. tostring(startErr), nil, machineVersion)
        return 'blocked', tostring(startErr)
    end

    -- Re-heap with the new due time (CyclesRepo.start already set next_due_at,
    -- but the in-memory heap needs the wake).
    CZCraft.SchedulerTick.wake(machineUuid, now + recipe.duration)
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

    local ok, err = CZCraft.CyclesRepo.complete({
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

    -- Reload the machine to get the fresh version (complete() bumped it).
    local machine = CZCraft.MachinesRepo.load(machineUuid)
    local freshVersion = machine and tonumber(machine.version) or machineVersion + 1

    -- Start the next cycle or go idle/blocked.
    startNextCycle(machineUuid, freshVersion, machineType, now)
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
    print(('[diag][catchup] enter machine=%s type=%s cursor=%d now=%d'):format(machineUuid, machineType, cursor, now))

    for _ = 1, MAX_CATCHUP_CHUNKS do
        local machine = CZCraft.MachinesRepo.load(machineUuid)
        if not machine then print('[diag][catchup] no machine'); return end
        local machineVersionFresh = tonumber(machine.version) or machineVersion

        local bills = CZCraft.BillsRepo.listActiveForMachine(machineUuid)
        local stockRows = CZCraft.StockRepo.loadAll(machineUuid)
        local machineConfig = findMachineConfig(machineType)
        local capacity = machineConfig and machineConfig.stockCapacity or 0
        print(('[diag][catchup] bills=%d stockRows=%d capacity=%d type=%s'):format(#bills, #stockRows, capacity, machineType))

        local stockPlusReservedByItem = {}
        for _, bill in ipairs(bills) do
            stockPlusReservedByItem[bill.primary_output] = stockPlusReservedForItem(stockRows, bill.primary_output)
        end
        local batchOutputByBill = {}
        for _, bill in ipairs(bills) do
            local recipe = findRecipe(bill.recipe_id)
            batchOutputByBill[bill.bill_id] = recipe and batchOutputAmount(recipe) or 1
        end

        local bill = CZCraft.Bills.selectNextBill(bills, stockPlusReservedByItem, batchOutputByBill)
        if not bill then
            print('[diag][catchup] no bill selected -> idle')
            CZCraft.MachinesRepo.clearNextDue(machineUuid, machineVersionFresh)
            return
        end
        print(('[diag][catchup] bill=%s recipe=%s mode=%s target=%s produced=%s'):format(
            bill.bill_id, bill.recipe_id, bill.mode, tostring(bill.target_quantity), tostring(bill.produced_quantity)))

        local recipe = findRecipe(bill.recipe_id)
        if not recipe then
            print('[diag][catchup] recipe not found')
            CZCraft.MachinesRepo.setBlocked(machineUuid, 'recipe not found: ' .. tostring(bill.recipe_id), nil, machineVersionFresh)
            return
        end
        if recipe.enabled == false then
            print('[diag][catchup] recipe disabled')
            CZCraft.MachinesRepo.setBlocked(machineUuid, 'recipe disabled', recipe.id, machineVersionFresh)
            return
        end

        local itemWeights = buildItemWeights(recipe)
        local usedWeight = CZCraft.Storage.computeUsedWeight(stockRows, itemWeights)
        local reservedWeight = CZCraft.Storage.sumReserved(stockRows)
        local batch = batchOutputAmount(recipe)
        print(('[diag][catchup] usedWeight=%s reservedWeight=%s batch=%s'):format(
            tostring(usedWeight), tostring(reservedWeight), tostring(batch)))

        local result = CZCraft.CatchUp.computeCatchUpChunk({
            lastCompletedAt = cursor,
            now = now,
            recipe = recipe,
            bill = {
                mode = bill.mode,
                target_quantity = tonumber(bill.target_quantity) or 0,
                produced_quantity = tonumber(bill.produced_quantity) or 0,
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

        if result.cyclesToRun <= 0 then
            print(('[diag][catchup] cyclesToRun=0 blockReason=%s shouldContinue=%s'):format(
                tostring(result.blockReason), tostring(result.shouldContinue)))
            if result.blockReason then
                local m = CZCraft.MachinesRepo.load(machineUuid)
                CZCraft.MachinesRepo.setBlocked(machineUuid, result.blockReason, nil, m and tonumber(m.version) or machineVersionFresh)
                return
            end
            -- Zero cycles, no block: caught up to the sub-duration boundary.
            -- Fall through to start a real-time cycle for the remaining time.
            break
        end
        print(('[diag][catchup] cyclesToRun=%d nextChunkElapsed=%s shouldContinue=%s'):format(
            result.cyclesToRun, tostring(result.nextChunkElapsed), tostring(result.shouldContinue)))

        chunkSequence = chunkSequence + 1
        local chunkStart = cursor
        local chunkEnd = cursor + result.nextChunkElapsed
        local nextDue = chunkEnd
        local idempotencyKey = machineUuid .. ':catchup:' .. tostring(chunkSequence)

        local ok, err = CZCraft.CyclesRepo.applyCatchUpChunk({
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
        })
        if not ok then
            -- Chunk failed: re-heap so the next tick retries from the cursor.
            CZCraft.SchedulerTick.wake(machineUuid, now)
            return
        end

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
    startNextCycle(machineUuid, tonumber(machine.version) or machineVersion, machineType, now)
end

-- ===========================================================================
-- Entry point
-- ===========================================================================

-- Processes a single due machine. Spawned in its own thread so the scheduler
-- tick loop never blocks on per-machine MySQL work.
-- @param machineUuid string
local function processMachine(machineUuid)
    print('[diag][process] ENTER processMachine for ' .. tostring(machineUuid))
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then print('[diag][process] runtime not ready'); return end
    if not CZCraft.Config.General.features.scheduler then print('[diag][process] scheduler disabled'); return end
    if not CZCraft.Config.General.features.production then print('[diag][process] production disabled'); return end

    local machine = CZCraft.MachinesRepo.load(machineUuid)
    if not machine then print('[diag][process] no machine ' .. tostring(machineUuid)); return end
    -- Only INSTALLED machines are processed.
    if machine.lifecycle ~= 'INSTALLED' then print('[diag][process] lifecycle=' .. tostring(machine.lifecycle)); return end

    local machineUuid_ = machine.machine_uuid
    local machineVersion = tonumber(machine.version) or 0
    local machineType = machine.machine_type
    local now = os.time()

    local activeCycle = CZCraft.CyclesRepo.loadActive(machineUuid_)
    if activeCycle then
        print('[diag][process] active cycle found -> completeActiveCycle')
        -- Mode 1: real-time cycle completion.
        completeActiveCycle(machineUuid_, machineVersion, machineType, now)
        return
    end

    -- Mode 2: catch-up (only if next_due_at is in the past).
    local nextDueAt = parseIsoToUnix(machine.next_due_at)
    if not nextDueAt then
        print('[diag][process] no next_due_at -> idle')
        -- No next_due_at: machine is idle, nothing to do.
        return
    end
    if nextDueAt > now then
        print(('[diag][process] next_due_at in future (%d > %d) -> re-heap'):format(nextDueAt, now))
        -- Not yet due: re-heap with the real due time (premature wake).
        CZCraft.SchedulerTick.wake(machineUuid_, nextDueAt)
        return
    end

    print(('[diag][process] next_due_at in past (%d <= %d) -> runCatchUp'):format(nextDueAt, now))
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
