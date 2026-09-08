-- qb-czcraft-e2e scenario: full production chain + MAINTAIN_X
--
-- Verifies the production chain end-to-end:
--   iron + metalscrap ->(smelt_steel)-> steel
--   steel ->(make_metal_parts)-> cz_metal_parts
--   cz_metal_parts + cz_electronics ->(make_components)-> cz_components
--   cz_metal_parts + rubber ->(make_mechanical_parts)-> cz_mechanical_parts
--   cz_components + cz_mechanical_parts ->(assemble_repairkit)-> repairkit
--
-- Each stage: create a machine, deposit inputs, create a PRODUCE_X bill, set
-- next_due_at to the past to trigger catch-up, fire processMachine, verify the
-- output stock. Also runs a MAINTAIN_X bill on one stage.
--
-- Command: /cze2e production_chain
-- Requires: qb-czcraft loaded + ready, schema migrated, a player online (for
-- owner context — machines are created with a PLAYER owner using the first
-- online player's citizenid).

CZE2E = CZE2E or {}

local Slo = CZE2E.Slo

-- Waits for a spawned processMachine thread to finish by polling the machine's
-- operational_status until it settles (STOPPED/BLOCKED/idle) or timeout.
local function waitForSettle(machineUuid, timeoutMs)
    local start = GetGameTimer()
    -- First, wait for the processMachine handler to start running.
    -- The machine starts STOPPED; the handler will either:
    --   - start a real-time cycle (status -> RUNNING), or
    --   - run catch-up (status stays STOPPED but next_due_at moves to the future),
    --   - go idle (next_due_at cleared),
    --   - go BLOCKED.
    -- We wait until the machine has settled: next_due_at is NULL or in the
    -- future, OR status is BLOCKED, OR (for real-time cycles) status is RUNNING
    -- and then back to STOPPED.
    -- Simplest correct approach: wait for next_due_at to no longer be in the
    -- past (or be NULL), or status to be BLOCKED.
    local sawRunning = false
    while GetGameTimer() - start < (timeoutMs or 15000) do
        local m = CZCraft.MachinesRepo.load(machineUuid)
        if not m then return false, 'machine disappeared' end
        local status = m.operational_status
        if status == 'BLOCKED' then
            return true, status
        end
        if status == 'RUNNING' then
            sawRunning = true
            Wait(100)
        else
            -- STOPPED: check if next_due_at is still in the past.
            -- If NULL or future, catch-up has completed.
            local nextDue = m.next_due_at
            if not nextDue or nextDue == '' then
                return true, status
            end
            -- Parse the ISO timestamp and compare to now.
            local y, mo, d, h, mi, s = tostring(nextDue):match('(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)')
            if y then
                local nextDueUnix = os.time({year=tonumber(y), month=tonumber(mo), day=tonumber(d),
                    hour=tonumber(h), min=tonumber(mi), sec=tonumber(s), isdst=false})
                if nextDueUnix and nextDueUnix > os.time() then
                    return true, status
                end
            else
                -- Can't parse: treat as settled.
                return true, status
            end
            -- next_due_at is still in the past: catch-up still running, keep waiting.
            Wait(100)
        end
    end
    return false, 'timeout'
end

-- Creates a test machine directly in the DB (bypasses placement API).
local function createTestMachine(machineType, ownerCid)
    local config = nil
    for _, mc in ipairs(CZCraft.Config.Machines) do
        if mc.type == machineType then config = mc break end
    end
    if not config then return nil, 'unknown machine type' end
    return CZCraft.MachinesRepo.createInstalled({
        machine_type = machineType,
        owner_type = 'PLAYER',
        owner_id = ownerCid,
        location_type = 'HOUSE',
        location_id = 'e2e-test-house',
        pos_x = 0.0, pos_y = 0.0, pos_z = 0.0, heading = 0.0,
        stock_capacity = config.stockCapacity,
    })
end

-- Deposits input stock into a machine.
local function depositStock(machineUuid, items)
    for _, entry in ipairs(items) do
        CZCraft.StockRepo.upsert({
            machine_uuid = machineUuid,
            item_name = entry.item,
            quantity = entry.amount,
            reserved_quantity = 0,
            standard_unit_cost = 0,
        })
    end
end

-- Reads back the quantity of an item in a machine's stock.
local function readStock(machineUuid, itemName)
    local row = CZCraft.StockRepo.load(machineUuid, itemName, '')
    return row and tonumber(row.quantity) or 0
end

-- Runs one chain stage: deposit inputs, create bill, trigger catch-up, verify.
local function runStage(label, machineType, recipeId, inputs, expectedOutput, expectedAmount, mode, target)
    print(('[E2E][chain] --- %s (%s) ---'):format(label, recipeId))

    -- Use the first online player's citizenid as owner.
    local players = GetPlayers()
    if not players or #players == 0 then
        print('[E2E][chain] FAIL: no players online'); return false
    end
    local src = tonumber(players[1])
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then print('[E2E][chain] FAIL: no player object'); return false end
    local cid = Player.PlayerData.citizenid

    local uuid = createTestMachine(machineType, cid)
    if not uuid then print(('[E2E][chain] FAIL: could not create %s machine'):format(machineType)); return false end
    print(('[E2E][chain] machine %s = %s'):format(machineType, uuid))

    -- Deposit inputs.
    depositStock(uuid, inputs)
    print(('[E2E][chain] deposited inputs: %s'):format(
        (function()
            local parts = {}
            for _, e in ipairs(inputs) do parts[#parts + 1] = e.item .. '=' .. e.amount end
            return table.concat(parts, ', ')
        end)()))

    -- Create the bill.
    local billId = 'e2e-' .. recipeId .. '-' .. tostring(math.random(100000, 999999))
    local ok, err = CZCraft.BillsRepo.create({
        bill_id = billId,
        machine_uuid = uuid,
        recipe_id = recipeId,
        mode = mode or 'PRODUCE_X',
        primary_output = expectedOutput,
        target_quantity = target or expectedAmount,
        priority = 'NORMAL',
        created_by_type = 'PLAYER',
        created_by_id = cid,
    })
    if not ok then print(('[E2E][chain] FAIL: bill create: %s'):format(tostring(err))); return false end

    -- Set next_due_at to the past to trigger catch-up (24h ago = 86400s).
    local pastIso = os.date('!%Y-%m-%d %H:%M:%S.000', os.time() - 86400)
    MySQL.update.await('UPDATE `czcraft_machines` SET `next_due_at` = ? WHERE `machine_uuid` = ?', { pastIso, uuid })

    -- Fire processMachine and wait for it to settle.
    local tStart = GetGameTimer()
    -- Call processMachine directly instead of via TriggerEvent, because
    -- the scenario runs in a loaded chunk with _ENV = _G and TriggerEvent
    -- may not reach handlers registered in the resource's main state.
    print(('[E2E][chain] firing processMachine for %s'):format(uuid))
    if CZCraft.CycleEngine and CZCraft.CycleEngine.processMachine then
        CZCraft.CycleEngine.processMachine(uuid)
    else
        print('[E2E][chain] WARNING: CZCraft.CycleEngine.processMachine not found, falling back to TriggerEvent')
        TriggerEvent('qb-czcraft:internal:processMachine', uuid)
    end
    local settled, status = waitForSettle(uuid, 30000)
    local elapsed = GetGameTimer() - tStart
    print(('[E2E][chain] settled=%s status=%s elapsed=%dms'):format(tostring(settled), tostring(status), elapsed))
    if not settled then
        print(('[E2E][chain] FAIL: %s did not settle'):format(recipeId)); return false
    end

    -- Verify output.
    local outputQty = readStock(uuid, expectedOutput)
    print(('[E2E][chain] output %s: %d (expected %d)'):format(expectedOutput, outputQty, expectedAmount))
    if outputQty < expectedAmount then
        print(('[E2E][chain] FAIL: %s produced %d, expected >= %d'):format(expectedOutput, outputQty, expectedAmount))
        return false
    end

    -- Verify the bill status.
    local bill = CZCraft.BillsRepo.load(billId)
    if bill then
        print(('[E2E][chain] bill %s status=%s produced=%d/%d'):format(
            billId, bill.status, tonumber(bill.produced_quantity) or 0, tonumber(bill.target_quantity) or 0))
    end

    print(('[E2E][chain] %s: PASS'):format(label))
    return true, uuid
end

local function runProductionChain()
    print('[E2E] === production_chain: start ===')
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        print('[E2E][chain] FAIL: qb-czcraft not ready'); return false
    end

    local allPass = true
    local stageTimings = Slo.recorder()

    -- Stage 1: smelt_steel (refinery): 5 iron + 2 metalscrap -> 2 steel.
    -- Target 20 steel = 10 cycles.
    local t0 = GetGameTimer()
    local ok1 = runStage('iron->steel', 'refinery', 'smelt_steel',
        { { item = 'iron', amount = 100 }, { item = 'metalscrap', amount = 50 } },
        'steel', 20, 'PRODUCE_X', 20)
    stageTimings.add(GetGameTimer() - t0)
    allPass = allPass and ok1

    -- Stage 2: make_metal_parts (fabricator): 4 steel -> 4 cz_metal_parts.
    -- Target 40 cz_metal_parts = 10 cycles.
    local t1 = GetGameTimer()
    local ok2 = runStage('steel->cz_metal_parts', 'fabricator', 'make_metal_parts',
        { { item = 'steel', amount = 100 } },
        'cz_metal_parts', 40, 'PRODUCE_X', 40)
    stageTimings.add(GetGameTimer() - t1)
    allPass = allPass and ok2

    -- Stage 3: make_components (fabricator): 2 cz_metal_parts + 1 cz_electronics + 2 plastic -> 2 cz_components.
    -- Target 20 cz_components = 10 cycles.
    local t2 = GetGameTimer()
    local ok3 = runStage('cz_metal_parts->cz_components', 'fabricator', 'make_components',
        { { item = 'cz_metal_parts', amount = 100 }, { item = 'cz_electronics', amount = 50 }, { item = 'plastic', amount = 100 } },
        'cz_components', 20, 'PRODUCE_X', 20)
    stageTimings.add(GetGameTimer() - t2)
    allPass = allPass and ok3

    -- Stage 4: make_mechanical_parts (fabricator): 3 cz_metal_parts + 2 rubber -> 1 cz_mechanical_parts.
    -- Target 10 cz_mechanical_parts = 10 cycles.
    local t3 = GetGameTimer()
    local ok4 = runStage('cz_metal_parts->cz_mechanical_parts', 'fabricator', 'make_mechanical_parts',
        { { item = 'cz_metal_parts', amount = 100 }, { item = 'rubber', amount = 50 } },
        'cz_mechanical_parts', 10, 'PRODUCE_X', 10)
    stageTimings.add(GetGameTimer() - t3)
    allPass = allPass and ok4

    -- Stage 5: assemble_repairkit (assembly): 3 cz_components + 2 cz_mechanical_parts + 1 cz_casing -> 1 repairkit.
    -- Target 5 repairkits = 5 cycles.
    local t4 = GetGameTimer()
    local ok5 = runStage('cz_components+cz_mechanical_parts->repairkit', 'assembly', 'assemble_repairkit',
        { { item = 'cz_components', amount = 50 }, { item = 'cz_mechanical_parts', amount = 50 }, { item = 'cz_casing', amount = 50 } },
        'repairkit', 5, 'PRODUCE_X', 5)
    stageTimings.add(GetGameTimer() - t4)
    allPass = allPass and ok5

    -- MAINTAIN_X test: maintain 10 steel on a refinery.
    local t5 = GetGameTimer()
    local ok6 = runStage('MAINTAIN_X steel', 'refinery', 'smelt_steel',
        { { item = 'iron', amount = 200 }, { item = 'metalscrap', amount = 100 } },
        'steel', 10, 'MAINTAIN_X', 10)
    stageTimings.add(GetGameTimer() - t5)
    allPass = allPass and ok6

    Slo.printStats('chain stage timings', stageTimings.stats())

    print(('[E2E] === production_chain: %s ==='):format(allPass and 'PASS' or 'FAIL'))
    return allPass
end

CZE2E.runProductionChain = runProductionChain
return runProductionChain
