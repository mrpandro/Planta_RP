-- qb-czcraft-e2e scenario: concurrent actions on same/different machines
--
-- Verifies the server-authoritative concurrency safety properties:
--   1. Same machine: multiple concurrent processMachine calls do NOT duplicate
--      cycles or double-consume stock. The active-cycle PK (one per machine)
--      and idempotency keys prevent duplication.
--   2. Different machines: concurrent processMachine calls do not interfere.
--   3. Optimistic version conflicts are detected (a stale bill version is
--      rejected, not silently applied).
--
-- Command: /cze2e concurrent

CZE2E = CZE2E or {}

local function runConcurrent()
    print('[E2E] === concurrent: start ===')
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        print('[E2E][concurrent] FAIL: qb-czcraft not ready'); return false
    end

    local players = GetPlayers()
    if not players or #players == 0 then
        print('[E2E][concurrent] FAIL: no players online'); return false
    end
    local src = tonumber(players[1])
    local Player = QBCore.Functions.GetPlayer(src)
    local cid = Player and Player.PlayerData.citizenid or 'e2e-test'

    local allPass = true

    -- -----------------------------------------------------------------------
    -- Test 1: same-machine concurrent processMachine (no duplication)
    -- -----------------------------------------------------------------------
    print('[E2E][concurrent] --- same-machine concurrency ---')
    local uuid1 = CZCraft.MachinesRepo.createInstalled({
        machine_type = 'refinery', owner_type = 'PLAYER', owner_id = cid,
        location_type = 'HOUSE', location_id = 'e2e-concurrent',
        pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, stock_capacity = 250000,
    })
    if not uuid1 then print('[E2E][concurrent] FAIL: machine create'); return false end

    -- Stock: enough for 1 cycle (5 iron + 2 metalscrap -> 2 steel).
    CZCraft.StockRepo.upsert({ machine_uuid = uuid1, item_name = 'iron', quantity = 5, reserved_quantity = 0, standard_unit_cost = 0 })
    CZCraft.StockRepo.upsert({ machine_uuid = uuid1, item_name = 'metalscrap', quantity = 2, reserved_quantity = 0, standard_unit_cost = 0 })

    local billId1 = 'e2e-conc-1-' .. tostring(math.random(100000, 999999))
    CZCraft.BillsRepo.create({
        bill_id = billId1, machine_uuid = uuid1, recipe_id = 'smelt_steel',
        mode = 'PRODUCE_X', primary_output = 'steel', target_quantity = 2,
        priority = 'NORMAL', created_by_type = 'PLAYER', created_by_id = cid,
    })

    -- Set next_due_at to past.
    local pastIso = os.date('!%Y-%m-%d %H:%M:%S.000', os.time() - 3600)
    MySQL.update.await('UPDATE `czcraft_machines` SET `next_due_at` = ? WHERE `machine_uuid` = ?', { pastIso, uuid1 })

    -- Fire processMachine 5 times concurrently. Each spawns a thread.
    -- Only one should start a cycle; the rest should see the active cycle
    -- (or get a start failure from the PK constraint).
    local tStart = GetGameTimer()
    for _ = 1, 5 do
        TriggerEvent('qb-czcraft:internal:processMachine', uuid1)
    end

    -- Wait for the machine to settle.
    local waited = 0
    while waited < 15000 do
        local m = CZCraft.MachinesRepo.load(uuid1)
        if m and m.operational_status ~= 'RUNNING' then break end
        Wait(100); waited = waited + 100
    end
    Wait(500)  -- extra settle time for the losing threads

    local steelQty = 0
    local row = CZCraft.StockRepo.load(uuid1, 'steel', '')
    if row then steelQty = tonumber(row.quantity) or 0 end
    local ironQty = 0
    local row2 = CZCraft.StockRepo.load(uuid1, 'iron', '')
    if row2 then ironQty = tonumber(row2.quantity) or 0 end

    print(('[E2E][concurrent] same-machine: steel=%d iron=%d (expected steel=2, iron=0)'):format(steelQty, ironQty))
    -- Only 1 cycle should have run (only 5 iron = 1 cycle). No duplication.
    if steelQty == 2 and ironQty == 0 then
        print('[E2E][concurrent] same-machine: PASS (no duplication)')
    else
        print(('[E2E][concurrent] same-machine: FAIL (duplication detected: steel=%d iron=%d)'):format(steelQty, ironQty))
        allPass = false
    end

    -- Check production events: only 1 event for this machine.
    local events = MySQL.query.await(
        'SELECT COUNT(*) AS cnt FROM `czcraft_production_events` WHERE `machine_uuid` = ?',
        { uuid1 })
    local eventCount = events and tonumber(events[1].cnt) or 0
    print(('[E2E][concurrent] same-machine: production_events=%d (expected 1)'):format(eventCount))
    if eventCount ~= 1 then
        print('[E2E][concurrent] same-machine: FAIL (event count != 1)')
        allPass = false
    end

    -- -----------------------------------------------------------------------
    -- Test 2: different-machine concurrent processMachine (no interference)
    -- -----------------------------------------------------------------------
    print('[E2E][concurrent] --- different-machine concurrency ---')
    local uuid2 = CZCraft.MachinesRepo.createInstalled({
        machine_type = 'refinery', owner_type = 'PLAYER', owner_id = cid,
        location_type = 'HOUSE', location_id = 'e2e-concurrent',
        pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, stock_capacity = 250000,
    })
    local uuid3 = CZCraft.MachinesRepo.createInstalled({
        machine_type = 'refinery', owner_type = 'PLAYER', owner_id = cid,
        location_type = 'HOUSE', location_id = 'e2e-concurrent',
        pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, stock_capacity = 250000,
    })

    -- Machine 2: smelt_steel (iron+metalscrap -> steel)
    CZCraft.StockRepo.upsert({ machine_uuid = uuid2, item_name = 'iron', quantity = 5, reserved_quantity = 0, standard_unit_cost = 0 })
    CZCraft.StockRepo.upsert({ machine_uuid = uuid2, item_name = 'metalscrap', quantity = 2, reserved_quantity = 0, standard_unit_cost = 0 })
    local billId2 = 'e2e-conc-2-' .. tostring(math.random(100000, 999999))
    CZCraft.BillsRepo.create({
        bill_id = billId2, machine_uuid = uuid2, recipe_id = 'smelt_steel',
        mode = 'PRODUCE_X', primary_output = 'steel', target_quantity = 2,
        priority = 'NORMAL', created_by_type = 'PLAYER', created_by_id = cid,
    })

    -- Machine 3: make_metal_parts (steel -> cz_metal_parts)
    CZCraft.StockRepo.upsert({ machine_uuid = uuid3, item_name = 'steel', quantity = 4, reserved_quantity = 0, standard_unit_cost = 0 })
    local billId3 = 'e2e-conc-3-' .. tostring(math.random(100000, 999999))
    CZCraft.BillsRepo.create({
        bill_id = billId3, machine_uuid = uuid3, recipe_id = 'make_metal_parts',
        mode = 'PRODUCE_X', primary_output = 'cz_metal_parts', target_quantity = 4,
        priority = 'NORMAL', created_by_type = 'PLAYER', created_by_id = cid,
    })

    -- Set both to past and fire concurrently.
    MySQL.update.await('UPDATE `czcraft_machines` SET `next_due_at` = ? WHERE `machine_uuid` = ?', { pastIso, uuid2 })
    MySQL.update.await('UPDATE `czcraft_machines` SET `next_due_at` = ? WHERE `machine_uuid` = ?', { pastIso, uuid3 })

    TriggerEvent('qb-czcraft:internal:processMachine', uuid2)
    TriggerEvent('qb-czcraft:internal:processMachine', uuid3)

    -- Wait for both to settle.
    waited = 0
    while waited < 15000 do
        local m2 = CZCraft.MachinesRepo.load(uuid2)
        local m3 = CZCraft.MachinesRepo.load(uuid3)
        local settled2 = m2 and m2.operational_status ~= 'RUNNING'
        local settled3 = m3 and m3.operational_status ~= 'RUNNING'
        if settled2 and settled3 then break end
        Wait(100); waited = waited + 100
    end
    Wait(500)

    local steel2 = (CZCraft.StockRepo.load(uuid2, 'steel', '') or {}).quantity or 0
    local parts3 = (CZCraft.StockRepo.load(uuid3, 'cz_metal_parts', '') or {}).quantity or 0
    print(('[E2E][concurrent] diff-machine: m2 steel=%d (expected 2), m3 cz_metal_parts=%d (expected 4)'):format(
        tonumber(steel2) or 0, tonumber(parts3) or 0))
    if tonumber(steel2) == 2 and tonumber(parts3) == 4 then
        print('[E2E][concurrent] diff-machine: PASS (no interference)')
    else
        print('[E2E][concurrent] diff-machine: FAIL (interference detected)')
        allPass = false
    end

    -- -----------------------------------------------------------------------
    -- Test 3: optimistic version conflict on bill
    -- -----------------------------------------------------------------------
    print('[E2E][concurrent] --- optimistic version conflict ---')
    local bill = CZCraft.BillsRepo.load(billId1)
    if bill then
        -- First increment with correct version.
        local ok1 = CZCraft.BillsRepo.incrementProduced(billId1, tonumber(bill.version), 1, bill.mode, tonumber(bill.target_quantity))
        -- Second increment with STALE version (should fail).
        local ok2, err2 = CZCraft.BillsRepo.incrementProduced(billId1, tonumber(bill.version), 1, bill.mode, tonumber(bill.target_quantity))
        print(('[E2E][concurrent] version conflict: first=%s second=%s err=%s'):format(
            tostring(ok1), tostring(ok2), tostring(err2)))
        if ok1 and not ok2 then
            print('[E2E][concurrent] version conflict: PASS (stale version rejected)')
        else
            print('[E2E][concurrent] version conflict: FAIL (stale version accepted)')
            allPass = false
        end
    end

    print(('[E2E] === concurrent: %s ==='):format(allPass and 'PASS' or 'FAIL'))
    return allPass
end

CZE2E.runConcurrent = runConcurrent
return runConcurrent
